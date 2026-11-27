// Host-side tests for the launcher's installation validation and the separation
// of the two installations.
//
// No iOS, SDL or engine code is needed: the launcher core is plain C++ and CI
// compiles it with the system compiler. These cover what a build cannot: that the
// two games' layouts are validated differently, that settings go to the right
// files, and that savegames are never touched.

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include <archive.h>
#include <archive_entry.h>

#include "launcher/launcher.h"
#include "launcher/launcher_archive.h"

namespace fs = std::filesystem;

static int g_failures = 0;

#define CHECK(condition)                                                      \
    do {                                                                      \
        if (!(condition)) {                                                   \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,      \
                #condition);                                                  \
            g_failures++;                                                     \
        }                                                                     \
    } while (0)

static void write_file(const fs::path& path, const std::string& contents = "test")
{
    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);

    std::ofstream stream(path.string(), std::ios::binary);
    stream.write(contents.data(), static_cast<std::streamsize>(contents.size()));
}

static bool file_contains(const fs::path& path, const std::string& needle)
{
    std::ifstream stream(path.string(), std::ios::binary);
    std::string contents((std::istreambuf_iterator<char>(stream)),
        std::istreambuf_iterator<char>());
    return contents.find(needle) != std::string::npos;
}

static void check_translation_tables()
{
    std::ifstream stream("os/ios/launcher/LauncherText.swift");
    if (!stream) {
        return;
    }

    std::string contents((std::istreambuf_iterator<char>(stream)),
        std::istreambuf_iterator<char>());

    const char* markers[] = { ".french: [", ".german: [", ".italian: [", ".spanish: [" };
    for (const char* marker : markers) {
        const size_t start = contents.find(marker);
        if (start == std::string::npos) {
            continue;
        }

        const size_t end = contents.find("\n        ],", start);
        if (end == std::string::npos) {
            continue;
        }

        std::vector<std::string> keys;
        size_t position = start;
        while ((position = contents.find("\n            \"", position)) != std::string::npos
            && position < end) {
            position += 14;
            const size_t close = contents.find('"', position);
            if (close == std::string::npos) {
                break;
            }
            keys.push_back(contents.substr(position, close - position));
            position = close;
        }

        std::sort(keys.begin(), keys.end());
        for (size_t index = 1; index < keys.size(); index++) {
            if (keys[index] == keys[index - 1]) {
                std::fprintf(stderr, "FAIL %s: duplicate key \"%s\"\n", marker, keys[index].c_str());
                g_failures++;
            }
        }
    }
}

// The note the engines leave beside the game is capped, and what is left of it is
// the newest whole lines: without the cap a repeating failure writes the file on
// every attempt.
static void check_log_trim(const fs::path& root)
{
    const fs::path log = root / "vaultos-saves.log";

    const int lines = 20000;
    std::string contents;
    for (int index = 0; index < lines; index++) {
        contents += "line " + std::to_string(index) + "\n";
    }

    write_file(log, contents);
    CHECK(fs::file_size(log) > static_cast<std::uintmax_t>(LAUNCHER_LOG_LIMIT_BYTES));

    launcher_trim_log(log.string().c_str(), LAUNCHER_LOG_LIMIT_BYTES, LAUNCHER_LOG_KEEP_BYTES);
    CHECK(fs::file_size(log) <= static_cast<std::uintmax_t>(LAUNCHER_LOG_KEEP_BYTES));
    // The newest entry is kept, the oldest is gone, and the cut fell on a line
    // boundary rather than in the middle of one.
    CHECK(file_contains(log, "line " + std::to_string(lines - 1) + "\n"));
    CHECK(!file_contains(log, "line 0\n"));

    std::ifstream stream(log.string(), std::ios::binary);
    std::string first;
    std::getline(stream, first);
    CHECK(first.rfind("line ", 0) == 0);
    stream.close();

    // A note that is already short enough, and one that was never written, are
    // both left alone.
    write_file(log, "short\n");
    launcher_trim_log(log.string().c_str(), LAUNCHER_LOG_LIMIT_BYTES, LAUNCHER_LOG_KEEP_BYTES);
    CHECK(file_contains(log, "short"));

    const fs::path missing = root / "never-written.log";
    launcher_trim_log(missing.string().c_str(), LAUNCHER_LOG_LIMIT_BYTES, LAUNCHER_LOG_KEEP_BYTES);
    CHECK(!fs::exists(missing));
}

static void scan(const fs::path& directory, int game, LauncherInstallInfo* info)
{
    launcher_scan(directory.string().c_str(), game, info);
}

static LauncherOptions options_for(int game)
{
    LauncherOptions options;
    launcher_default_options(&options);
    options.game = game;
    options.width = 1280;
    options.height = 720;
    return options;
}

// A minimal stored (uncompressed) ZIP, so the tests can hand the installer real
// archives without a compression library or a fixture file.
struct ZipItem {
    std::string name;
    std::string contents;
};

static void put_u16(std::string& out, uint16_t value)
{
    out.push_back(static_cast<char>(value & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
}

static void put_u32(std::string& out, uint32_t value)
{
    out.push_back(static_cast<char>(value & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>((value >> 16) & 0xff));
    out.push_back(static_cast<char>((value >> 24) & 0xff));
}

static uint32_t crc32_of(const std::string& contents)
{
    uint32_t crc = 0xffffffffu;
    for (char character : contents) {
        crc ^= static_cast<unsigned char>(character);
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
        }
    }
    return crc ^ 0xffffffffu;
}

static void write_zip(const fs::path& path, const std::vector<ZipItem>& items)
{
    struct Placed {
        uint32_t offset;
        const ZipItem* item;
    };

    std::string archive;
    std::vector<Placed> placed;

    for (const ZipItem& item : items) {
        placed.push_back({ static_cast<uint32_t>(archive.size()), &item });

        const uint32_t crc = crc32_of(item.contents);
        const uint32_t size = static_cast<uint32_t>(item.contents.size());

        put_u32(archive, 0x04034b50); // local file header
        put_u16(archive, 20);         // version needed
        put_u16(archive, 0);          // flags
        put_u16(archive, 0);          // method: stored
        put_u16(archive, 0);          // time
        put_u16(archive, 0);          // date
        put_u32(archive, crc);
        put_u32(archive, size);       // compressed size
        put_u32(archive, size);       // uncompressed size
        put_u16(archive, static_cast<uint16_t>(item.name.size()));
        put_u16(archive, 0);          // extra field length
        archive += item.name;
        archive += item.contents;
    }

    const uint32_t directory_offset = static_cast<uint32_t>(archive.size());

    for (const Placed& entry : placed) {
        const ZipItem& item = *entry.item;
        const uint32_t crc = crc32_of(item.contents);
        const uint32_t size = static_cast<uint32_t>(item.contents.size());

        put_u32(archive, 0x02014b50); // central directory entry
        put_u16(archive, 20);         // version made by
        put_u16(archive, 20);         // version needed
        put_u16(archive, 0);          // flags
        put_u16(archive, 0);          // method: stored
        put_u16(archive, 0);          // time
        put_u16(archive, 0);          // date
        put_u32(archive, crc);
        put_u32(archive, size);
        put_u32(archive, size);
        put_u16(archive, static_cast<uint16_t>(item.name.size()));
        put_u16(archive, 0);          // extra field length
        put_u16(archive, 0);          // comment length
        put_u16(archive, 0);          // disk number
        put_u16(archive, 0);          // internal attributes
        put_u32(archive, 0);          // external attributes
        put_u32(archive, entry.offset);
        archive += item.name;
    }

    const uint32_t directory_size = static_cast<uint32_t>(archive.size()) - directory_offset;
    const uint16_t count = static_cast<uint16_t>(placed.size());

    put_u32(archive, 0x06054b50); // end of central directory
    put_u16(archive, 0);          // disk number
    put_u16(archive, 0);          // disk with the directory
    put_u16(archive, count);      // entries on this disk
    put_u16(archive, count);      // entries in total
    put_u32(archive, directory_size);
    put_u32(archive, directory_offset);
    put_u16(archive, 0);          // comment length

    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);

    std::ofstream stream(path.string(), std::ios::binary);
    stream.write(archive.data(), static_cast<std::streamsize>(archive.size()));
}

// A game CD, built here so no copyrighted game data has to be shipped: a primary
// volume descriptor with its root, an optional Joliet tree with long names, and
// the file data behind them.
struct IsoItem {
    std::string name;
    std::string contents;
};

struct IsoNode {
    std::string name;
    std::string contents;
    bool directory = false;
    size_t parent = 0;
    uint32_t lba = 0;
    uint32_t size = 0;
    std::vector<size_t> children;
};

static void put_be16(std::string& out, uint16_t value)
{
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>(value & 0xff));
}

static void put_be32(std::string& out, uint32_t value)
{
    out.push_back(static_cast<char>((value >> 24) & 0xff));
    out.push_back(static_cast<char>((value >> 16) & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>(value & 0xff));
}

// Joliet stores every character in two bytes, most significant first.
static std::string ucs2be(const std::string& value)
{
    std::string out;
    for (char character : value) {
        out.push_back('\0');
        out.push_back(character);
    }
    return out;
}

static size_t iso_find_child(const std::vector<IsoNode>& nodes, size_t parent,
    const std::string& name)
{
    for (size_t child : nodes[parent].children) {
        if (nodes[child].name == name) {
            return child;
        }
    }
    return static_cast<size_t>(-1);
}

static void iso_add_item(std::vector<IsoNode>& nodes, const IsoItem& item)
{
    size_t parent = 0;
    size_t start = 0;

    while (start < item.name.size()) {
        const size_t slash = item.name.find('/', start);
        const bool last = slash == std::string::npos;
        const std::string name = item.name.substr(start,
            last ? std::string::npos : slash - start);

        size_t node = iso_find_child(nodes, parent, name);
        if (node == static_cast<size_t>(-1)) {
            IsoNode created;
            created.name = name;
            created.directory = !last;
            created.contents = last ? item.contents : std::string();
            created.parent = parent;
            node = nodes.size();
            nodes.push_back(created);
            nodes[parent].children.push_back(node);
        }

        if (last) {
            return;
        }
        parent = node;
        start = slash + 1;
    }
}

static std::vector<IsoNode> iso_tree(const std::vector<IsoItem>& items)
{
    std::vector<IsoNode> nodes(1);
    nodes[0].directory = true;

    for (const IsoItem& item : items) {
        iso_add_item(nodes, item);
    }

    return nodes;
}

// A file carries its ISO 9660 version, and a Joliet tree stores the name in two
// bytes per character.
static std::string iso_stored_name(const IsoNode& node, bool joliet)
{
    const std::string name = node.directory ? node.name : node.name + ";1";
    return joliet ? ucs2be(name) : name;
}

static uint32_t iso_record_size(size_t name_length)
{
    return static_cast<uint32_t>(33 + name_length + (name_length % 2 == 0 ? 1 : 0));
}

// One directory record, with the location and the size in both byte orders as
// ISO 9660 asks for.
static std::string iso_record(const std::string& name, uint32_t lba, uint32_t size,
    bool directory)
{
    std::string record;
    record.push_back(static_cast<char>(iso_record_size(name.size())));
    record.push_back('\0'); // extended attribute length
    put_u32(record, lba);
    put_be32(record, lba);
    put_u32(record, size);
    put_be32(record, size);
    for (int index = 0; index < 7; index++) {
        record.push_back('\0'); // recording date
    }
    record.push_back(static_cast<char>(directory ? 0x02 : 0x00)); // file flags
    record.push_back('\0'); // file unit size
    record.push_back('\0'); // interleave gap
    put_u16(record, 1);     // volume sequence number
    put_be16(record, 1);
    record.push_back(static_cast<char>(name.size()));
    record += name;
    if (name.size() % 2 == 0) {
        record.push_back('\0'); // a record ends on a whole word
    }
    return record;
}

static uint32_t iso_listing_size(const std::vector<IsoNode>& nodes, size_t directory,
    bool joliet)
{
    uint32_t size = iso_record_size(1) + iso_record_size(1); // "." and ".."

    for (size_t child : nodes[directory].children) {
        size += iso_record_size(iso_stored_name(nodes[child], joliet).size());
    }

    return ((size + 2047) / 2048) * 2048;
}

static std::string iso_listing(const std::vector<IsoNode>& nodes, size_t directory,
    bool joliet)
{
    const IsoNode& folder = nodes[directory];

    std::string listing;
    listing += iso_record(std::string(1, '\0'), folder.lba, folder.size, true);
    listing += iso_record(std::string(1, '\1'), nodes[folder.parent].lba,
        nodes[folder.parent].size, true);

    for (size_t child : folder.children) {
        const IsoNode& entry = nodes[child];
        listing += iso_record(iso_stored_name(entry, joliet), entry.lba, entry.size,
            entry.directory);
    }

    return listing;
}

// Places the folder listings first and the file data behind them, so every
// record can name where its entry really starts.
static uint32_t iso_place(std::vector<IsoNode>& nodes, uint32_t sector, bool joliet)
{
    for (size_t index = 0; index < nodes.size(); index++) {
        if (!nodes[index].directory) {
            continue;
        }
        nodes[index].size = iso_listing_size(nodes, index, joliet);
        nodes[index].lba = sector;
        sector += nodes[index].size / 2048;
    }

    for (IsoNode& node : nodes) {
        if (node.directory) {
            continue;
        }
        node.lba = sector;
        node.size = static_cast<uint32_t>(node.contents.size());
        sector += static_cast<uint32_t>((node.size + 2047) / 2048);
    }

    return sector;
}

static void iso_descriptor(std::string& image, uint32_t sector, unsigned char type,
    const IsoNode& root, uint32_t total_sectors, const char* escape)
{
    const size_t base = static_cast<size_t>(sector) * 2048;

    image[base] = static_cast<char>(type);
    std::memcpy(&image[base + 1], "CD001", 5);
    image[base + 6] = 1; // version

    std::string field;
    put_u32(field, total_sectors);
    put_be32(field, total_sectors);
    std::memcpy(&image[base + 80], field.data(), field.size()); // volume space size

    field.clear();
    put_u16(field, 2048);
    put_be16(field, 2048);
    std::memcpy(&image[base + 128], field.data(), field.size()); // logical block size

    field.clear();
    put_u16(field, 1);
    put_be16(field, 1);
    std::memcpy(&image[base + 120], field.data(), field.size()); // volume set size
    std::memcpy(&image[base + 124], field.data(), field.size()); // volume sequence number

    if (escape != nullptr) {
        std::memcpy(&image[base + 88], escape, 3);
    }

    const std::string record = iso_record(std::string(1, '\0'), root.lba, root.size, true);
    std::memcpy(&image[base + 156], record.data(), record.size()); // the root record
}

static std::string build_iso(const std::vector<IsoItem>& primary,
    const std::vector<IsoItem>& joliet)
{
    std::vector<IsoNode> primary_nodes = iso_tree(primary);
    std::vector<IsoNode> joliet_nodes = iso_tree(joliet);

    // Sectors 0-15 are the system area, then the descriptors, then one sector
    // that ends them.
    const uint32_t last_descriptor = joliet.empty() ? 17 : 18;
    uint32_t sector = last_descriptor + 1;

    sector = iso_place(primary_nodes, sector, false);
    if (!joliet.empty()) {
        sector = iso_place(joliet_nodes, sector, true);
    }

    std::string image(static_cast<size_t>(sector) * 2048, '\0');

    iso_descriptor(image, 16, 1, primary_nodes[0], sector, nullptr);
    if (!joliet.empty()) {
        iso_descriptor(image, 17, 2, joliet_nodes[0], sector, "%/E");
    }

    const size_t end = static_cast<size_t>(last_descriptor) * 2048;
    image[end] = static_cast<char>(0xff);
    std::memcpy(&image[end + 1], "CD001", 5);
    image[end + 6] = 1;

    for (size_t index = 0; index < primary_nodes.size(); index++) {
        if (!primary_nodes[index].directory) {
            continue;
        }
        const std::string listing = iso_listing(primary_nodes, index, false);
        std::memcpy(&image[static_cast<size_t>(primary_nodes[index].lba) * 2048],
            listing.data(), listing.size());
    }

    if (!joliet.empty()) {
        for (size_t index = 0; index < joliet_nodes.size(); index++) {
            if (!joliet_nodes[index].directory) {
                continue;
            }
            const std::string listing = iso_listing(joliet_nodes, index, true);
            std::memcpy(&image[static_cast<size_t>(joliet_nodes[index].lba) * 2048],
                listing.data(), listing.size());
        }
    }

    for (const IsoNode& node : primary_nodes) {
        if (node.directory) {
            continue;
        }
        std::memcpy(&image[static_cast<size_t>(node.lba) * 2048], node.contents.data(),
            node.contents.size());
    }

    if (!joliet.empty()) {
        for (const IsoNode& node : joliet_nodes) {
            if (node.directory) {
                continue;
            }
            std::memcpy(&image[static_cast<size_t>(node.lba) * 2048], node.contents.data(),
                node.contents.size());
        }
    }

    return image;
}

// A raw MODE1/2352 track: the sync pattern and the header in front of every one
// of the image's 2048-byte sectors.
static std::string raw_track(const std::string& image)
{
    std::string track;

    for (size_t sector = 0; sector * 2048 < image.size(); sector++) {
        std::string raw(2352, '\0');
        std::fill(raw.begin() + 1, raw.begin() + 11, static_cast<char>(0xff));
        raw[12] = 0; // minutes
        raw[13] = 0; // seconds
        raw[14] = 0; // frames
        raw[15] = 1; // mode 1
        std::memcpy(&raw[16], image.data() + sector * 2048, 2048);
        track += raw;
    }

    return track;
}

// The folders the importer unpacks a disc image into: there must be none left
// over after an import, whether it worked or not.
static int import_folders()
{
    std::error_code ec;
    int count = 0;

    for (const fs::directory_entry& entry :
        fs::directory_iterator(fs::temp_directory_path(ec), ec)) {
        if (entry.path().filename().string().rfind("vaultos-import-", 0) == 0) {
            count++;
        }
    }

    return count;
}

// ---------------------------------------------------------------------------
// 7z and RAR archives
// ---------------------------------------------------------------------------
//
// The 7z fixtures are written by libarchive itself, and the RAR ones are built
// here, so no game data has to be shipped and the reader meets real archives.

struct ArcItem {
    std::string name;
    std::string contents;
    std::string link; // a symbolic link's target, when this is a link
    bool encrypted = false; // the password flag of a RAR4 file header
};

static uint16_t rar_header_crc(const std::string& block)
{
    return static_cast<uint16_t>(crc32_of(block) & 0xffff);
}

static std::string rar4_file_block(const ArcItem& item)
{
    std::string block;
    block.push_back(static_cast<char>(0x74)); // HEAD_TYPE: a file
    put_u16(block, static_cast<uint16_t>(0x8000 | (item.encrypted ? 0x0004 : 0)));
    put_u16(block, static_cast<uint16_t>(32 + item.name.size()));     // HEAD_SIZE
    put_u32(block, static_cast<uint32_t>(item.contents.size()));       // PACK_SIZE
    put_u32(block, static_cast<uint32_t>(item.contents.size()));       // UNP_SIZE
    block.push_back(static_cast<char>(3));                              // HOST_OS: Unix
    put_u32(block, crc32_of(item.contents));                           // FILE_CRC
    put_u32(block, 0x58216000);                                         // FTIME
    block.push_back(static_cast<char>(20));                             // UNP_VER
    block.push_back(static_cast<char>(0x30));                           // METHOD: stored
    put_u16(block, static_cast<uint16_t>(item.name.size()));
    put_u32(block, 0x81a4);                                             // ATTR: -rw-r--r--
    block += item.name;

    std::string archive;
    put_u16(archive, rar_header_crc(block));
    archive += block;
    archive += item.contents;
    return archive;
}

// A RAR4 archive, stored: the format RAR 4 wrote, and the one older archives
// of a game are in.
static void write_rar4(const fs::path& path, const std::vector<ArcItem>& items)
{
    std::string archive;
    archive.append("Rar!\x1A\x07\x00", 7); // the RAR4 marker

    std::string main;
    main.push_back(static_cast<char>(0x73)); // HEAD_TYPE: the archive
    put_u16(main, 0);                          // HEAD_FLAGS
    put_u16(main, 13);                         // HEAD_SIZE
    put_u16(main, 0);                          // reserved
    put_u32(main, 0);
    put_u16(archive, rar_header_crc(main));
    archive += main;

    for (const ArcItem& item : items) {
        archive += rar4_file_block(item);
    }

    std::string end;
    end.push_back(static_cast<char>(0x7B)); // HEAD_TYPE: the end of the archive
    put_u16(end, 0x4000);
    put_u16(end, 7);
    put_u16(archive, rar_header_crc(end));
    archive += end;

    write_file(path, archive);
}

// A RAR5 variable-length integer: seven bits a byte, low first.
static void put_vint(std::string& out, uint64_t value)
{
    while (value >= 0x80) {
        out.push_back(static_cast<char>((value & 0x7f) | 0x80));
        value >>= 7;
    }
    out.push_back(static_cast<char>(value));
}

static void put_rar5_block(std::string& archive, uint64_t type, uint64_t flags,
    const std::string& fields, const std::string& data)
{
    std::string body;
    put_vint(body, type);
    put_vint(body, flags);
    if ((flags & 0x0002) != 0) {
        put_vint(body, data.size()); // DATA_SIZE
    }
    body += fields;

    std::string size;
    put_vint(size, body.size());

    put_u32(archive, crc32_of(size + body)); // HEAD_CRC
    archive += size;
    archive += body;
    archive += data;
}

// A RAR5 archive, stored: what RAR 5 and 7-Zip write today.
static void write_rar5(const fs::path& path, const std::vector<ArcItem>& items)
{
    std::string archive;
    archive.append("Rar!\x1A\x07\x01\x00", 8); // the RAR5 marker

    std::string main;
    put_vint(main, 0); // ARCHIVE_FLAGS
    put_rar5_block(archive, 1, 0, main, std::string());

    for (const ArcItem& item : items) {
        std::string fields;
        put_vint(fields, 0x0004);                  // FILE_FLAGS: a data CRC
        put_vint(fields, item.contents.size());    // UNP_SIZE
        put_vint(fields, 0x81a4);                  // ATTRIBUTES: -rw-r--r--
        put_u32(fields, crc32_of(item.contents));  // DATA_CRC32
        put_vint(fields, 0);                       // COMPRESSION_INFO: stored
        put_vint(fields, 1);                       // HOST_OS: Unix
        put_vint(fields, item.name.size());
        fields += item.name;

        put_rar5_block(archive, 2, 0x0002, fields, item.contents);
    }

    std::string end;
    put_vint(end, 1); // ENDARC_FLAGS: the end of the archive
    put_rar5_block(archive, 5, 0, end, std::string());

    write_file(path, archive);
}

// A real 7z archive, written by libarchive's own 7z encoder.
static void write_7z(const fs::path& path, const std::vector<ArcItem>& items,
    const char* method)
{
    struct archive* writer = archive_write_new();
    CHECK(writer != nullptr);

    CHECK(archive_write_set_format_7zip(writer) == ARCHIVE_OK);
    const std::string option = std::string("7zip:compression=") + method;
    CHECK(archive_write_set_options(writer, option.c_str()) == ARCHIVE_OK);
    CHECK(archive_write_open_filename(writer, path.string().c_str()) == ARCHIVE_OK);

    for (const ArcItem& item : items) {
        struct archive_entry* entry = archive_entry_new();
        archive_entry_set_pathname(entry, item.name.c_str());
        archive_entry_set_perm(entry, 0644);

        if (!item.link.empty()) {
            archive_entry_set_filetype(entry, AE_IFLNK);
            archive_entry_set_symlink(entry, item.link.c_str());
            archive_entry_set_size(entry, 0);
        } else {
            archive_entry_set_filetype(entry, AE_IFREG);
            archive_entry_set_size(entry, static_cast<la_int64_t>(item.contents.size()));
        }

        CHECK(archive_write_header(writer, entry) == ARCHIVE_OK);
        if (!item.contents.empty()) {
            CHECK(archive_write_data(writer, item.contents.data(), item.contents.size())
                == static_cast<la_ssize_t>(item.contents.size()));
        }
        archive_entry_free(entry);
    }

    CHECK(archive_write_close(writer) == ARCHIVE_OK);
    CHECK(archive_write_free(writer) == ARCHIVE_OK);
}

// libarchive ships its own test archives uuencoded, and the RAR fixture is one
// of them, so a real archive is read rather than only ones built here.
static std::string uu_decode(const std::string& text)
{
    std::string binary;
    size_t position = 0;

    while (position < text.size()) {
        const size_t newline = text.find('\n', position);
        const std::string line = text.substr(position,
            newline == std::string::npos ? std::string::npos : newline - position);
        position = newline == std::string::npos ? text.size() : newline + 1;

        if (line.compare(0, 3, "end") == 0) {
            break;
        }
        if (line.size() < 2 || line.compare(0, 6, "begin ") == 0) {
            continue;
        }

        int remaining = (static_cast<unsigned char>(line[0]) - 0x20) & 0x3f;
        for (size_t index = 1; index + 3 < line.size() && remaining > 0; index += 4) {
            const int first = (static_cast<unsigned char>(line[index]) - 0x20) & 0x3f;
            const int second = (static_cast<unsigned char>(line[index + 1]) - 0x20) & 0x3f;
            const int third = (static_cast<unsigned char>(line[index + 2]) - 0x20) & 0x3f;
            const int fourth = (static_cast<unsigned char>(line[index + 3]) - 0x20) & 0x3f;

            const unsigned char bytes[3] = {
                static_cast<unsigned char>((first << 2) | (second >> 4)),
                static_cast<unsigned char>((second << 4) | (third >> 2)),
                static_cast<unsigned char>((third << 6) | fourth),
            };
            for (int byte = 0; byte < 3 && remaining > 0; byte++) {
                binary += static_cast<char>(bytes[byte]);
                remaining--;
            }
        }
    }

    return binary;
}

static void write_uu_fixture(const fs::path& source, const fs::path& path)
{
    std::ifstream stream(source.string(), std::ios::binary);
    CHECK(stream.good());

    const std::string text((std::istreambuf_iterator<char>(stream)),
        std::istreambuf_iterator<char>());
    write_file(path, uu_decode(text));
}

int main()
{
    check_translation_tables();

    const fs::path root = fs::temp_directory_path() / "fallout-ce-launcher-tests";
    std::error_code ec;
    fs::remove_all(root, ec);
    fs::create_directories(root, ec);

    check_log_trim(root);

    // A Fallout 1 installation: master.dat, critter.dat and data, no patch.
    const fs::path fallout1 = root / "Fallout";
    write_file(fallout1 / "master.dat");
    write_file(fallout1 / "critter.dat");
    fs::create_directories(fallout1 / "data", ec);

    LauncherInstallInfo info = {};

    scan(fallout1, LAUNCHER_GAME_FALLOUT1, &info);
    CHECK(info.installed == 1);
    CHECK(info.has_master_dat == 1);
    CHECK(info.has_critter_dat == 1);
    CHECK(info.has_data_folder == 1);
    CHECK(info.has_patch_dat == 0);

    // The same files must NOT satisfy Fallout 2, which needs patch000.dat.
    scan(fallout1, LAUNCHER_GAME_FALLOUT2, &info);
    CHECK(info.installed == 0);
    CHECK(info.has_patch_dat == 0);

    // Writing Fallout 2 settings into a Fallout 1 layout must fail and must say
    // what is missing, instead of producing a broken configuration.
    {
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_write_options(fallout1.string().c_str(), &options) == LAUNCHER_ERROR);
        const std::string error = launcher_last_error();
        CHECK(error.find("patch000.dat") != std::string::npos);
        CHECK(!fs::exists(fallout1 / "fallout2.cfg"));
    }

    // Fallout 1 settings go to fallout.cfg/f1_res.ini and never to the Fallout 2
    // files.
    {
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_write_options(fallout1.string().c_str(), &options) == LAUNCHER_OK);
        CHECK(fs::exists(fallout1 / "fallout.cfg"));
        CHECK(fs::exists(fallout1 / "f1_res.ini"));
        CHECK(!fs::exists(fallout1 / "fallout2.cfg"));
        CHECK(!fs::exists(fallout1 / "f2_res.ini"));
        CHECK(file_contains(fallout1 / "fallout.cfg", "master_dat=master.dat"));
        CHECK(file_contains(fallout1 / "f1_res.ini", "SCR_WIDTH=1280"));
    }

    // A Fallout 2 installation: the Fallout 1 files plus patch000.dat.
    const fs::path fallout2 = root / "Fallout2";
    write_file(fallout2 / "master.dat");
    write_file(fallout2 / "critter.dat");
    write_file(fallout2 / "patch000.dat");
    fs::create_directories(fallout2 / "data", ec);

    scan(fallout2, LAUNCHER_GAME_FALLOUT2, &info);
    CHECK(info.installed == 1);
    CHECK(info.has_patch_dat == 1);

    // The two games write different configuration files even though both use
    // the same data file names.
    {
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_write_options(fallout2.string().c_str(), &options) == LAUNCHER_OK);
        CHECK(fs::exists(fallout2 / "fallout2.cfg"));
        CHECK(fs::exists(fallout2 / "f2_res.ini"));
        CHECK(!fs::exists(fallout2 / "fallout.cfg"));
        CHECK(!fs::exists(fallout2 / "f1_res.ini"));
        CHECK(file_contains(fallout2 / "fallout2.cfg", "master_dat=master.dat"));
        CHECK(file_contains(fallout2 / "fallout2.cfg", "critter_dat=critter.dat"));
        CHECK(file_contains(fallout2 / "f2_res.ini", "SCR_WIDTH=1280"));
    }

    // Savegames belong to the player: rewriting settings must not touch them,
    // and the installation scan must report them.
    write_file(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data");
    write_file(fallout2 / "data" / "SAVEGAME" / "SLOT03" / "save.dat", "other-save-data");
    {
        LauncherOptions fallout1Options = options_for(LAUNCHER_GAME_FALLOUT1);
        LauncherOptions fallout2Options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_write_options(fallout1.string().c_str(), &fallout1Options) == LAUNCHER_OK);
        CHECK(launcher_write_options(fallout2.string().c_str(), &fallout2Options) == LAUNCHER_OK);

        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
        CHECK(file_contains(fallout2 / "data" / "SAVEGAME" / "SLOT03" / "save.dat", "other-save-data"));

        scan(fallout1, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.has_saves == 1);
        scan(fallout2, LAUNCHER_GAME_FALLOUT2, &info);
        CHECK(info.has_saves == 1);

        // Neither game's settings appear in the other installation.
        CHECK(!fs::exists(fallout1 / "fallout2.cfg"));
        CHECK(!fs::exists(fallout2 / "fallout.cfg"));
    }

    // An archive that is neither game is refused before anything is extracted:
    // the installation and the savegames stay as they were.
    {
        const fs::path junk = root / "holiday photos.zip";
        write_zip(junk, { { "readme.txt", "these are not game files" } });

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(junk.string().c_str(), fallout1.string().c_str(), &options)
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("master.dat") != std::string::npos);
        CHECK(!fs::exists(fallout1 / "readme.txt"));
        CHECK(file_contains(fallout1 / "master.dat", "test"));
        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));

        scan(fallout1, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.installed == 1);
    }

    // A Fallout 2 archive offered to Fallout 1 is refused too, so its
    // patch000.dat can never land in a Fallout 1 folder.
    {
        const fs::path fallout2Zip = root / "Fallout2 install.zip";
        write_zip(fallout2Zip, {
            { "master.dat", "fallout2-master" },
            { "critter.dat", "fallout2-critter" },
            { "patch000.dat", "fallout2-patch" },
            { "data/art/tiles.trx", "fallout2-tiles" },
        });

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(fallout2Zip.string().c_str(), fallout1.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("patch000.dat") != std::string::npos);
        CHECK(!fs::exists(fallout1 / "patch000.dat"));
        CHECK(!fs::exists(fallout1 / "data" / "art" / "tiles.trx"));
        CHECK(file_contains(fallout1 / "master.dat", "test"));
    }

    // A language pack carries only the game's own text tree, and it lands where
    // the engine looks for it before the archive. The pack reports which
    // languages it carried so the launcher can select one.
    {
        const fs::path pack = root / "fallout french.zip";
        write_zip(pack, {
            { "text/french/game/misc.msg", "bonjour" },
            { "readme.txt", "unofficial translation" },
        });

        int32_t languages = 0;
        CHECK(launcher_install_language_pack(pack.string().c_str(), fallout1.string().c_str(),
                  &languages) == LAUNCHER_OK);
        CHECK((languages & (1 << LAUNCHER_LANGUAGE_FRENCH)) != 0);
        CHECK(file_contains(fallout1 / "data" / "text" / "french" / "game" / "misc.msg",
            "bonjour"));
        CHECK(!fs::exists(fallout1 / "readme.txt"));

        // The game data itself is untouched by a pack.
        CHECK(file_contains(fallout1 / "master.dat", "test"));
    }

    // A pack wrapped in a folder, holding a whole data folder, and naming its
    // language folder in its own language: it is found, and stored under the
    // name the engine asks for.
    {
        const fs::path wrapped = root / "wrapped pack.zip";
        write_zip(wrapped, { { "Fallout/data/text/FRANCAIS/game/misc.msg", "salut" } });

        int32_t languages = 0;
        CHECK(launcher_install_language_pack(wrapped.string().c_str(),
                  fallout1.string().c_str(), &languages) == LAUNCHER_OK);
        CHECK((languages & (1 << LAUNCHER_LANGUAGE_FRENCH)) != 0);
        CHECK(file_contains(fallout1 / "data" / "text" / "french" / "game" / "misc.msg", "salut"));
        CHECK(!fs::exists(fallout1 / "data" / "text" / "FRANCAIS"));
    }

    // Anything that is not a text tree is refused rather than scattered over the
    // installation.
    {
        const fs::path wrong = root / "no text.zip";
        write_zip(wrong, { { "art/tiles.trx", "not a translation" } });

        int32_t languages = 0;
        CHECK(launcher_install_language_pack(wrong.string().c_str(), fallout1.string().c_str(),
                  &languages) == LAUNCHER_ERROR);
        CHECK(languages == 0);
        CHECK(std::string(launcher_last_error()).find("text") != std::string::npos);
        CHECK(!fs::exists(fallout1 / "data" / "art" / "tiles.trx"));
    }

    // A backup carries the savegames and nothing else, and putting one back
    // replaces what is there.
    {
        write_file(fallout1 / "data" / "SAVEGAME" / "SLOT02" / "SAVE.DAT", "slot-two");

        char backup[1024] = { 0 };
        CHECK(launcher_backup_saves(fallout1.string().c_str(), LAUNCHER_GAME_FALLOUT1, backup,
                  static_cast<int32_t>(sizeof(backup))) == LAUNCHER_OK);
        CHECK(backup[0] != '\0');
        CHECK(fs::path(backup).filename().string().find("-fo1-bkup-") != std::string::npos);
        CHECK(fs::path(backup).filename().string().find("-#1.zip") != std::string::npos);
        CHECK(fs::path(backup).parent_path().filename().string() == "Backups");
        CHECK(fs::exists(fs::path(backup)));

        // A second backup lands beside the first rather than over it, under the
        // next number.
        char second[1024] = { 0 };
        CHECK(launcher_backup_saves(fallout1.string().c_str(), LAUNCHER_GAME_FALLOUT1, second,
                  static_cast<int32_t>(sizeof(second))) == LAUNCHER_OK);
        CHECK(std::string(second) != std::string(backup));
        CHECK(fs::path(second).filename().string().find("-#2.zip") != std::string::npos);
        CHECK(fs::exists(fs::path(second)));

        // The newer saves are replaced by the ones in the backup, so a slot that
        // is not in it must be gone afterwards.
        write_file(fallout1 / "data" / "SAVEGAME" / "SLOT07" / "SAVE.DAT", "newer");

        CHECK(launcher_import_saves(backup, fallout1.string().c_str()) == LAUNCHER_OK);
        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT02" / "SAVE.DAT", "slot-two"));
        CHECK(!fs::exists(fallout1 / "data" / "SAVEGAME" / "SLOT07" / "SAVE.DAT"));
    }

    // An archive that is not a backup is refused, and the saves stay put.
    {
        const fs::path wrong = root / "not a backup.zip";
        write_zip(wrong, { { "art/tiles.trx", "not a save" } });

        CHECK(launcher_import_saves(wrong.string().c_str(), fallout1.string().c_str())
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("SAVEGAME") != std::string::npos);
        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
    }

    // A game ZIP offered as a language pack is refused before anything is
    // written, so its text tree can never land over the game's own data.
    {
        const fs::path game = root / "fallout game.zip";
        write_zip(game, {
            { "master.dat", "game" },
            { "critter.dat", "game" },
            { "data/text/english/game/misc.msg", "hello" },
        });

        int32_t languages = 0;
        CHECK(launcher_install_language_pack(game.string().c_str(), fallout1.string().c_str(),
                  &languages) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("game ZIP") != std::string::npos);
        CHECK(languages == 0);
        CHECK(!fs::exists(fallout1 / "data" / "text" / "english"));
    }

    {
        const fs::path withSaves = root / "Fallout with saves.zip";
        write_zip(withSaves, {
            { "master.dat", "installed-master" },
            { "critter.dat", "installed-critter" },
            { "data/art/tiles.trx", "installed-tiles" },
            { "data/SAVEGAME/SLOT01/save.dat", "archive-save" },
            { "SAVEGAME/SLOT01/save.dat", "archive-save" },
        });

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(withSaves.string().c_str(), fallout1.string().c_str(), &options)
            == LAUNCHER_OK);
        CHECK(file_contains(fallout1 / "data" / "art" / "tiles.trx", "installed-tiles"));
        CHECK(file_contains(fallout1 / "data" / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
        CHECK(!fs::exists(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat"));
    }

    // A game CD offered as an ISO is installed from the image itself, and the
    // files it holds are validated exactly as a ZIP's are.
    const fs::path iso_install = root / "Fallout from ISO";
    {
        const fs::path iso = root / "Fallout CD.iso";
        write_file(iso, build_iso({
            { "master.dat", "iso-master" },
            { "critter.dat", "iso-critter" },
            { "data/art/tiles.trx", "iso-tiles" },
        }, {}));

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(iso.string().c_str(), iso_install.string().c_str(), &options)
            == LAUNCHER_OK);
        CHECK(file_contains(iso_install / "master.dat", "iso-master"));
        CHECK(file_contains(iso_install / "critter.dat", "iso-critter"));
        CHECK(file_contains(iso_install / "data" / "art" / "tiles.trx", "iso-tiles"));

        scan(iso_install, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.installed == 1);
    }

    // A Fallout 2 disc installs as Fallout 2, and is refused as Fallout 1 before
    // its patch archive can land in a Fallout 1 folder.
    {
        const fs::path iso = root / "Fallout 2 CD.iso";
        write_file(iso, build_iso({
            { "master.dat", "iso2-master" },
            { "critter.dat", "iso2-critter" },
            { "patch000.dat", "iso2-patch" },
            { "data/art/tiles.trx", "iso2-tiles" },
        }, {}));

        LauncherOptions fallout1Options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(iso.string().c_str(), iso_install.string().c_str(),
                  &fallout1Options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("patch000.dat") != std::string::npos);
        CHECK(!fs::exists(iso_install / "patch000.dat"));
        CHECK(file_contains(iso_install / "master.dat", "iso-master"));

        const fs::path fallout2_install = root / "Fallout 2 from ISO";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_install_zip(iso.string().c_str(), fallout2_install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(fallout2_install / "patch000.dat", "iso2-patch"));
        CHECK(file_contains(fallout2_install / "data" / "art" / "tiles.trx", "iso2-tiles"));
    }

    // A disc that carries Joliet names is read with them: its plain names have no
    // data folder, so only the Joliet tree can install.
    {
        const fs::path iso = root / "Fallout Joliet.iso";
        write_file(iso, build_iso({
            { "master.dat", "joliet-master" },
            { "critter.dat", "joliet-critter" },
        }, {
            { "master.dat", "joliet-master" },
            { "critter.dat", "joliet-critter" },
            { "data/art/tiles.trx", "joliet-tiles" },
        }));

        const fs::path install = root / "Fallout from Joliet";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(iso.string().c_str(), install.string().c_str(), &options)
            == LAUNCHER_OK);
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "joliet-tiles"));
    }

    // A raw BIN with its CUE: the reader keeps the 2048 bytes behind each
    // sector's sync pattern and header, and the sheet says where they start.
    {
        const fs::path bin = root / "Fallout CD.bin";
        write_file(bin, raw_track(build_iso({
            { "master.dat", "bin-master" },
            { "critter.dat", "bin-critter" },
            { "data/art/tiles.trx", "bin-tiles" },
        }, {})));
        write_file(root / "Fallout CD.cue",
            "FILE \"Fallout CD.bin\" BINARY\n"
            "  TRACK 01 MODE1/2352\n"
            "    INDEX 01 00:00:00\n");

        const fs::path install = root / "Fallout from BIN";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip((root / "Fallout CD.cue").string().c_str(),
                  install.string().c_str(), &options) == LAUNCHER_OK);
        CHECK(file_contains(install / "master.dat", "bin-master"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "bin-tiles"));

        // A bare BIN has no sheet to name its track, so the layout is read from
        // the sector pattern itself.
        const fs::path bare = root / "Fallout from a bare BIN";
        CHECK(launcher_install_zip(bin.string().c_str(), bare.string().c_str(), &options)
            == LAUNCHER_OK);
        CHECK(file_contains(bare / "master.dat", "bin-master"));
    }

    // A mixed-mode sheet names an audio track first: it is stepped over rather
    // than read as the disc's data.
    {
        const fs::path bin = root / "mixed.bin";
        write_file(bin, raw_track(build_iso({
            { "master.dat", "mixed-master" },
            { "critter.dat", "mixed-critter" },
            { "data/art/tiles.trx", "mixed-tiles" },
        }, {})));
        write_file(root / "mixed.cue",
            "FILE \"mixed.bin\" BINARY\n"
            "  TRACK 01 AUDIO\n"
            "    INDEX 01 00:00:00\n"
            "  TRACK 02 MODE1/2352\n"
            "    INDEX 01 00:00:00\n");

        const fs::path install = root / "Fallout from a mixed-mode disc";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip((root / "mixed.cue").string().c_str(),
                  install.string().c_str(), &options) == LAUNCHER_OK);
        CHECK(file_contains(install / "master.dat", "mixed-master"));
    }

    // A ZIP of a CD holds the image rather than the game: both are unpacked into
    // a folder of the app's own, which is gone when the import ends.
    {
        const fs::path archive = root / "Fallout CD.zip";
        write_zip(archive, {
            { "cd.bin", raw_track(build_iso({
                { "master.dat", "zipcd-master" },
                { "critter.dat", "zipcd-critter" },
                { "data/art/tiles.trx", "zipcd-tiles" },
            }, {})) },
            { "cd.cue", "FILE \"cd.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n" },
        });

        const int before = import_folders();
        const fs::path install = root / "Fallout from a ZIP of a CD";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(), &options)
            == LAUNCHER_OK);
        CHECK(file_contains(install / "master.dat", "zipcd-master"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "zipcd-tiles"));
        CHECK(import_folders() == before);

        // A CD that holds no game files is refused, and that folder is gone too.
        const fs::path wrong = root / "Wrong CD.zip";
        write_zip(wrong, { { "cd.iso", build_iso({ { "readme.txt", "hello" } }, {}) } });

        CHECK(launcher_install_zip(wrong.string().c_str(),
                  (root / "Fallout from a wrong CD").string().c_str(), &options)
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("master.dat") != std::string::npos);
        CHECK(import_folders() == before);
    }

    // A disc that is one of a set says so, rather than reporting the game as
    // damaged.
    {
        const fs::path iso = root / "Fallout disc 1.iso";
        write_file(iso, build_iso({ { "master.dat", "disc-master" } }, {}));

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(iso.string().c_str(),
                  (root / "Fallout from disc 1").string().c_str(), &options)
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("critter.dat") != std::string::npos);
        CHECK(std::string(launcher_last_error()).find("one disc of a set")
            != std::string::npos);
    }

    // An image with no filesystem, and a sheet pointing outside its own folder,
    // are both refused with a reason and nothing is installed.
    {
        const fs::path broken = root / "broken.iso";
        write_file(broken, std::string(64 * 2048, '\0'));

        const fs::path install = root / "Fallout from a broken CD";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(broken.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("ISO 9660") != std::string::npos);
        CHECK(!fs::exists(install / "master.dat"));

        write_file(root / "escaping.cue",
            "FILE \"../outside.bin\" BINARY\n"
            "  TRACK 01 MODE1/2352\n"
            "    INDEX 01 00:00:00\n");
        CHECK(launcher_install_zip((root / "escaping.cue").string().c_str(),
                  install.string().c_str(), &options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("outside its folder")
            != std::string::npos);
        CHECK(!fs::exists(install / "master.dat"));
    }

    // The container is read from the file rather than its name: a 7z archive
    // named as something else still reaches the 7z reader.
    {
        const fs::path renamed = root / "Fallout copy.data";
        write_7z(renamed, {
            { "master.dat", "renamed-master" },
            { "critter.dat", "renamed-critter" },
            { "data/art/tiles.trx", "renamed-tiles" },
        }, "copy");

        const fs::path install = root / "Fallout from a renamed 7z";
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(renamed.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(install / "master.dat", "renamed-master"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "renamed-tiles"));
    }

    // A 7z archive is unpacked and the game installed from it by the path a
    // ZIP takes, so Fallout's checks see the same files.
    const fs::path seven_install = root / "Fallout from a 7z";
    const fs::path seven2_install = root / "Fallout 2 from a 7z";
    {
        const fs::path archive = root / "Fallout copy.7z";
        write_7z(archive, {
            { "master.dat", "seven-master" },
            { "critter.dat", "seven-critter" },
            { "data/art/tiles.trx", "seven-tiles" },
        }, "copy");

        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), seven_install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(seven_install / "master.dat", "seven-master"));
        CHECK(file_contains(seven_install / "critter.dat", "seven-critter"));
        CHECK(file_contains(seven_install / "data" / "art" / "tiles.trx", "seven-tiles"));
        CHECK(import_folders() == before);

        scan(seven_install, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.installed == 1);
    }

    // The LZMA2 compression most 7z repacks use is decoded: a Fallout 2 archive
    // installs as Fallout 2, and the same archive is refused as Fallout 1.
    {
        const fs::path archive = root / "Fallout 2.7z";
        write_7z(archive, {
            { "master.dat", "seven2-master" },
            { "critter.dat", "seven2-critter" },
            { "patch000.dat", "seven2-patch" },
            { "data/art/tiles.trx", "seven2-tiles" },
        }, "lzma2");

        LauncherOptions fallout1Options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), seven_install.string().c_str(),
                  &fallout1Options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("patch000.dat") != std::string::npos);
        CHECK(file_contains(seven_install / "master.dat", "seven-master"));

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_install_zip(archive.string().c_str(), seven2_install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(seven2_install / "patch000.dat", "seven2-patch"));
        CHECK(file_contains(seven2_install / "data" / "art" / "tiles.trx", "seven2-tiles"));
    }

    // A folder tree inside the archive is kept, a repeated name keeps its last
    // version, and a name or a link that would leave the installation is never
    // written.
    {
        const fs::path archive = root / "Fallout odd names.7z";
        write_7z(archive, {
            { "Fallout/master.dat", "names-first" },
            { "Fallout/master.dat", "names-last" },
            { "Fallout/critter.dat", "names-critter" },
            { "Fallout/data/art/tiles.trx", "names-tiles" },
            { "Fallout/data/SAVEGAME/SLOT01/save.dat", "names-save" },
            { "../escape.txt", "escaped" },
            { "/absolute.txt", "absolute" },
            { "Fallout/data/link", "", "../../etc/hosts" },
        }, "copy");

        const fs::path install = root / "Fallout from odd names";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_OK);

        CHECK(file_contains(install / "master.dat", "names-last"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "names-tiles"));
        CHECK(!fs::exists(install / "data" / "link"));
        CHECK(!fs::exists(install / "data" / "SAVEGAME" / "SLOT01" / "save.dat"));
        CHECK(!fs::exists(root / "escape.txt"));
        CHECK(!fs::exists(root / "absolute.txt"));
        CHECK(import_folders() == before);
    }

    // A damaged archive fails with a reason, leaves the installation alone and
    // cleans up what it unpacked.
    {
        const fs::path whole = root / "Fallout whole.7z";
        write_7z(whole, {
            { "master.dat", "damaged-master" },
            { "critter.dat", "damaged-critter" },
            { "data/art/tiles.trx", "damaged-tiles" },
        }, "lzma2");

        std::ifstream stream(whole.string(), std::ios::binary);
        const std::string contents((std::istreambuf_iterator<char>(stream)),
            std::istreambuf_iterator<char>());
        stream.close();

        const fs::path truncated = root / "Fallout truncated.7z";
        write_file(truncated, contents.substr(0, contents.size() / 2));

        const fs::path install = root / "Fallout from a truncated 7z";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(truncated.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(!std::string(launcher_last_error()).empty());
        CHECK(!fs::exists(install / "master.dat"));
        CHECK(import_folders() == before);
    }

    // A RAR4 archive is read as well: stored, so the fixture is one this
    // project can build without a RAR tool.
    {
        const fs::path archive = root / "Fallout rar4.rar";
        write_rar4(archive, {
            { "Fallout/master.dat", "rar4-master" },
            { "Fallout/critter.dat", "rar4-critter" },
            { "Fallout/data/art/tiles.trx", "rar4-tiles" },
        });

        std::vector<LauncherArchiveEntry> entries;
        std::string error;
        CHECK(launcher_archive_open(archive.string().c_str(), &entries, &error));
        CHECK(entries.size() == 3);

        const fs::path install = root / "Fallout from a RAR4";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(install / "master.dat", "rar4-master"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "rar4-tiles"));
        CHECK(import_folders() == before);
    }

    // A RAR5 archive, the one RAR and 7-Zip write today, is installed the same.
    {
        const fs::path archive = root / "Fallout rar5.rar";
        write_rar5(archive, {
            { "Fallout2/master.dat", "rar5-master" },
            { "Fallout2/critter.dat", "rar5-critter" },
            { "Fallout2/patch000.dat", "rar5-patch" },
            { "Fallout2/data/art/tiles.trx", "rar5-tiles" },
        });

        const fs::path install = root / "Fallout 2 from a RAR5";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_OK);
        CHECK(file_contains(install / "patch000.dat", "rar5-patch"));
        CHECK(file_contains(install / "data" / "art" / "tiles.trx", "rar5-tiles"));
        CHECK(import_folders() == before);
    }

    // libarchive's own RAR4 test archive is read, and its files go through the
    // game checks: it holds no game files, so the import names what is missing.
    {
        const fs::path archive = root / "libarchive rar4.rar";
        write_uu_fixture("tests/fixtures/libarchive-rar4.rar.uu", archive);

        std::vector<LauncherArchiveEntry> entries;
        std::string error;
        CHECK(launcher_archive_open(archive.string().c_str(), &entries, &error));
        CHECK(entries.size() >= 2);

        const fs::path install = root / "Fallout from a real RAR";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("master.dat") != std::string::npos);
        CHECK(!fs::exists(install / "master.dat"));
        CHECK(import_folders() == before);
    }

    // An archive that says it is encrypted is refused rather than read as if it
    // were empty.
    {
        const fs::path archive = root / "Fallout encrypted.rar";
        ArcItem item;
        item.name = "master.dat";
        item.contents = "secret";
        item.encrypted = true;
        write_rar4(archive, { item });

        const fs::path install = root / "Fallout from an encrypted RAR";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(!std::string(launcher_last_error()).empty());
        CHECK(!fs::exists(install / "master.dat"));
        CHECK(import_folders() == before);
    }

    // An archive that holds more files than the launcher will unpack is refused
    // while it is listed, so nothing of it reaches the disk.
    {
        std::vector<ArcItem> items;
        items.reserve(50001);
        for (int index = 0; index < 50001; index++) {
            ArcItem item;
            item.name = "pack/data/file" + std::to_string(index) + ".dat";
            item.contents = "x";
            items.push_back(item);
        }

        const fs::path archive = root / "Fallout packed.7z";
        write_7z(archive, items, "copy");

        const fs::path install = root / "Fallout from a packed 7z";
        const int before = import_folders();
        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(archive.string().c_str(), install.string().c_str(),
                  &options) == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("too many files") != std::string::npos);
        CHECK(!fs::exists(install / "master.dat"));
        CHECK(import_folders() == before);
    }

    // A Windows installer is still named, now that 7z and RAR are read.
    {
        const fs::path installer = root / "setup_fallout2.exe";
        write_file(installer, std::string("MZ", 2) + "not really an installer");

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_install_zip(installer.string().c_str(),
                  (root / "Fallout 2 from an installer").string().c_str(), &options)
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("installer") != std::string::npos);
    }

    // Uppercase installations (CD-era copies) are detected as well.
    const fs::path uppercase = root / "FALLOUT2";
    write_file(uppercase / "MASTER.DAT");
    write_file(uppercase / "CRITTER.DAT");
    write_file(uppercase / "PATCH000.DAT");
    fs::create_directories(uppercase / "DATA", ec);
    scan(uppercase, LAUNCHER_GAME_FALLOUT2, &info);
    CHECK(info.installed == 1);

    // A missing folder is not an installation and does not crash.
    scan(root / "does-not-exist", LAUNCHER_GAME_FALLOUT1, &info);
    CHECK(info.installed == 0);
    CHECK(info.has_master_dat == 0);

    if (g_failures != 0) {
        std::fprintf(stderr, "%d launcher check(s) failed\n", g_failures);
        return 1;
    }

    std::printf("All launcher validation checks passed\n");
    return 0;
}
