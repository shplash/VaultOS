#include "launcher/launcher_disc.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>

namespace fs = std::filesystem;

namespace {

const uint32_t kSectorSize = 2048;
const int kMaxDepth = 8;
const size_t kMaxFiles = 50000;
const uint64_t kMaxTotalBytes = 8ull * 1024ull * 1024ull * 1024ull;
const uint64_t kMaxDirectoryBytes = 16ull * 1024ull * 1024ull;
const uint64_t kMaxCueBytes = 1024ull * 1024ull;

uint16_t read_le16(const unsigned char* data)
{
    return static_cast<uint16_t>(data[0] | (data[1] << 8));
}

uint32_t read_le32(const unsigned char* data)
{
    return static_cast<uint32_t>(data[0])
        | (static_cast<uint32_t>(data[1]) << 8)
        | (static_cast<uint32_t>(data[2]) << 16)
        | (static_cast<uint32_t>(data[3]) << 24);
}

std::string lower_ascii(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string trim(const std::string& value)
{
    size_t start = 0;
    size_t end = value.size();
    while (start < end && (value[start] == ' ' || value[start] == '\t' || value[start] == '\r')) {
        start++;
    }
    while (end > start && (value[end - 1] == ' ' || value[end - 1] == '\t' || value[end - 1] == '\r')) {
        end--;
    }
    return value.substr(start, end - start);
}

// A sector source: the file, how its sectors are laid out, and where the data
// track starts inside it.
struct Reader {
    fs::path path;
    std::ifstream file;
    uint64_t stride = kSectorSize;
    uint64_t data_offset = 0;
    uint64_t first_sector = 0;
    uint64_t sectors = 0;
};

bool read_bytes(std::ifstream& stream, uint64_t offset, void* data, size_t size)
{
    stream.clear();
    stream.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!stream) {
        return false;
    }
    stream.read(static_cast<char*>(data), static_cast<std::streamsize>(size));
    return stream.gcount() == static_cast<std::streamsize>(size);
}

bool read_block(Reader& reader, uint32_t lba, unsigned char* block)
{
    if (lba >= reader.sectors) {
        return false;
    }

    const uint64_t offset = (reader.first_sector + lba) * reader.stride + reader.data_offset;
    return read_bytes(reader.file, offset, block, kSectorSize);
}

bool open_at(Reader& reader, const fs::path& path, uint64_t stride, uint64_t data_offset,
    uint64_t first_sector, std::string& error)
{
    reader.file.open(path, std::ios::binary);
    if (!reader.file) {
        error = "Cannot open " + path.filename().string() + ".";
        return false;
    }

    reader.file.seekg(0, std::ios::end);
    const std::streamoff end = reader.file.tellg();
    if (end <= 0) {
        error = "This disc image is empty.";
        return false;
    }
    const uint64_t size = static_cast<uint64_t>(end);
    reader.file.clear();

    reader.path = path;
    reader.stride = stride;
    reader.data_offset = data_offset;
    reader.first_sector = first_sector;

    if (first_sector * stride >= size) {
        error = "The CUE sheet points past the end of its image.";
        return false;
    }

    reader.sectors = (size - first_sector * stride) / stride;
    if (reader.sectors == 0) {
        error = "This disc image holds no sectors.";
        return false;
    }

    return true;
}

bool has_sync(const unsigned char* data)
{
    if (data[0] != 0x00 || data[11] != 0x00) {
        return false;
    }
    for (int index = 1; index <= 10; index++) {
        if (data[index] != 0xFF) {
            return false;
        }
    }
    return true;
}

bool first_descriptor_at(std::ifstream& stream, uint64_t offset)
{
    unsigned char descriptor[6] = { 0 };
    if (!read_bytes(stream, offset, descriptor, sizeof(descriptor))) {
        return false;
    }
    return std::memcmp(descriptor + 1, "CD001", 5) == 0;
}

// A plain ISO keeps its sectors whole; a raw track puts 16 or 24 bytes of sync,
// header and subheader in front of each one.
bool open_raw(const fs::path& path, Reader& reader, std::string& error)
{
    std::ifstream probe(path, std::ios::binary);
    if (!probe) {
        error = "Cannot open " + path.filename().string() + ".";
        return false;
    }

    probe.seekg(0, std::ios::end);
    if (probe.tellg() <= 0) {
        error = "This disc image is empty.";
        return false;
    }
    probe.clear();

    unsigned char header[16] = { 0 };
    const bool raw_sector = read_bytes(probe, 0, header, sizeof(header)) && has_sync(header);

    if (!raw_sector) {
        if (first_descriptor_at(probe, 0x8000)) {
            return open_at(reader, path, kSectorSize, 0, 0, error);
        }
        error = "This image has no ISO 9660 filesystem.";
        return false;
    }

    const uint64_t base = 16ull * 2352ull;
    for (uint64_t offset : { uint64_t(16), uint64_t(24) }) {
        if (first_descriptor_at(probe, base + offset)) {
            return open_at(reader, path, 2352, offset, 0, error);
        }
    }

    error = "This image has no ISO 9660 filesystem.";
    return false;
}

std::string quoted_name(const std::string& line)
{
    const size_t first = line.find('"');
    if (first == std::string::npos) {
        return std::string();
    }
    const size_t second = line.find('"', first + 1);
    if (second == std::string::npos) {
        return std::string();
    }
    return line.substr(first + 1, second - first - 1);
}

uint64_t msf_to_sector(const std::string& value)
{
    unsigned minutes = 0;
    unsigned seconds = 0;
    unsigned frames = 0;
    if (std::sscanf(value.c_str(), "%u:%u:%u", &minutes, &seconds, &frames) != 3) {
        return 0;
    }
    return (static_cast<uint64_t>(minutes) * 60 + seconds) * 75 + frames;
}

// How the data of a track is laid out in the file, per its CUE mode.
bool track_layout(const std::string& mode, uint64_t& stride, uint64_t& data_offset)
{
    if (mode == "MODE1/2048") {
        stride = 2048;
        data_offset = 0;
        return true;
    }
    if (mode == "MODE1/2352") {
        stride = 2352;
        data_offset = 16;
        return true;
    }
    if (mode == "MODE2/2352") {
        stride = 2352;
        data_offset = 24;
        return true;
    }
    return false;
}

// The CUE names the tracks: the first one carrying a filesystem is the one to
// read, so a mixed-mode disc's audio tracks are stepped over rather than read.
bool open_cue(const fs::path& path, Reader& reader, std::string& error)
{
    std::ifstream sheet(path, std::ios::binary);
    if (!sheet) {
        error = "Cannot open " + path.filename().string() + ".";
        return false;
    }

    sheet.seekg(0, std::ios::end);
    const std::streamoff end = sheet.tellg();
    if (end <= 0 || static_cast<uint64_t>(end) > kMaxCueBytes) {
        error = "This CUE sheet is empty or too large.";
        return false;
    }
    sheet.seekg(0);

    const std::string text((std::istreambuf_iterator<char>(sheet)), std::istreambuf_iterator<char>());

    std::string current_file;
    std::string current_mode;
    std::string data_file;
    uint64_t stride = 0;
    uint64_t data_offset = 0;
    uint64_t data_sector = 0;
    bool found = false;

    size_t position = 0;
    while (position < text.size()) {
        const size_t line_end = text.find('\n', position);
        const std::string line = trim(text.substr(position,
            line_end == std::string::npos ? std::string::npos : line_end - position));
        position = line_end == std::string::npos ? text.size() : line_end + 1;

        const std::string upper = [&line]() {
            std::string value = line;
            std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
                return static_cast<char>(std::toupper(c));
            });
            return value;
        }();

        if (upper.rfind("FILE", 0) == 0) {
            current_file = quoted_name(line);
        } else if (upper.rfind("TRACK", 0) == 0) {
            const size_t space = upper.find_last_of(' ');
            current_mode = space == std::string::npos ? std::string() : trim(upper.substr(space + 1));
        } else if (upper.rfind("INDEX 01", 0) == 0 && !found) {
            uint64_t candidate_stride = 0;
            uint64_t candidate_offset = 0;
            if (!track_layout(current_mode, candidate_stride, candidate_offset)) {
                continue; // an audio track, or a layout this reader cannot use
            }
            if (current_file.empty()) {
                error = "This CUE sheet names a track before any file.";
                return false;
            }
            found = true;
            data_file = current_file;
            stride = candidate_stride;
            data_offset = candidate_offset;
            data_sector = msf_to_sector(trim(upper.substr(8)));
        }
    }

    if (!found) {
        error = "This CUE sheet names no data track the launcher can read.";
        return false;
    }

    // The image has to sit beside the sheet: a name that leaves that folder is
    // not trusted.
    if (data_file.empty() || data_file[0] == '/' || data_file.find("..") != std::string::npos) {
        error = "The CUE sheet points outside its folder.";
        return false;
    }

    return open_at(reader, path.parent_path() / fs::path(data_file), stride, data_offset,
        data_sector, error);
}

struct Record {
    std::string name;
    uint32_t lba = 0;
    uint32_t size = 0;
    bool directory = false;
    bool multi_extent = false;
};

std::string joliet_name(const unsigned char* data, size_t length)
{
    std::string name;
    for (size_t index = 0; index + 1 < length; index += 2) {
        const uint32_t code = (static_cast<uint32_t>(data[index]) << 8) | data[index + 1];
        if (code == 0) {
            break;
        }
        if (code < 0x80) {
            name += static_cast<char>(code);
        } else if (code < 0x800) {
            name += static_cast<char>(0xC0 | (code >> 6));
            name += static_cast<char>(0x80 | (code & 0x3F));
        } else {
            name += static_cast<char>(0xE0 | ((code >> 12) & 0x0F));
            name += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
            name += static_cast<char>(0x80 | (code & 0x3F));
        }
    }
    return name;
}

std::string iso_name(const unsigned char* data, size_t length)
{
    std::string name;
    for (size_t index = 0; index < length; index++) {
        const unsigned char character = data[index];
        if (character < 0x20 || character == 0x7F || character == '/' || character == '\\') {
            return std::string();
        }
        if (character < 0x80) {
            name += static_cast<char>(character);
        } else {
            name += static_cast<char>(0xC0 | (character >> 6));
            name += static_cast<char>(0x80 | (character & 0x3F));
        }
    }
    return name;
}

bool parse_record(const unsigned char* data, size_t length, bool joliet, Record& record)
{
    if (length < 34) {
        return false;
    }

    const size_t name_length = data[32];
    if (name_length == 0 || 33 + name_length > length) {
        return false;
    }

    record.lba = read_le32(data + 2);
    record.size = read_le32(data + 10);
    record.directory = (data[25] & 0x02) != 0;
    record.multi_extent = (data[25] & 0x80) != 0;

    const unsigned char* name = data + 33;
    if (name_length == 1 && (name[0] == 0x00 || name[0] == 0x01)) {
        record.name.clear();
        return true;
    }

    record.name = joliet ? joliet_name(name, name_length) : iso_name(name, name_length);
    if (record.name.empty()) {
        return false;
    }

    const size_t version = record.name.find(';');
    if (version != std::string::npos) {
        record.name.erase(version);
    }
    return !record.name.empty();
}

struct Pending {
    uint32_t lba = 0;
    uint32_t size = 0;
    std::string prefix;
    int depth = 0;
};

// Reads the folder tree one listing at a time, sector by sector, and never the
// whole image: a game disc is a few hundred megabytes.
bool walk(Reader& reader, bool joliet, const Pending& root, std::vector<LauncherDiscFile>* files,
    std::string& error)
{
    std::vector<Pending> pending;
    pending.push_back(root);

    uint64_t total = 0;
    std::vector<unsigned char> block(kSectorSize);

    while (!pending.empty()) {
        const Pending item = pending.back();
        pending.pop_back();

        if (item.size > kMaxDirectoryBytes) {
            error = "A folder in this image is too large to read.";
            return false;
        }

        const uint32_t sectors = (item.size + kSectorSize - 1) / kSectorSize;
        for (uint32_t index = 0; index < sectors; index++) {
            if (!read_block(reader, item.lba + index, block.data())) {
                error = "The disc image ends before its folder listing does.";
                return false;
            }

            size_t cursor = 0;
            while (cursor + 34 <= kSectorSize) {
                const size_t length = block[cursor];
                if (length == 0) {
                    break;
                }
                if (length < 34 || cursor + length > kSectorSize) {
                    error = "A folder listing in this image is damaged.";
                    return false;
                }

                Record record;
                if (parse_record(block.data() + cursor, length, joliet, record) && !record.name.empty()) {
                    if (record.multi_extent) {
                        error = "This image splits a file into parts, which is not supported.";
                        return false;
                    }

                    if (record.directory) {
                        if (item.depth + 1 > kMaxDepth) {
                            error = "This image nests folders too deeply.";
                            return false;
                        }
                        pending.push_back({ record.lba, record.size, item.prefix + record.name + "/",
                            item.depth + 1 });
                    } else {
                        if (files->size() >= kMaxFiles) {
                            error = "This image holds too many files.";
                            return false;
                        }
                        total += record.size;
                        if (total > kMaxTotalBytes) {
                            error = "This image is too large.";
                            return false;
                        }
                        files->push_back({ item.prefix + record.name, record.lba, record.size });
                    }
                }

                cursor += length;
            }
        }
    }

    return true;
}

} // namespace

bool launcher_disc_open(const char* path, LauncherDiscImage* image,
    std::vector<LauncherDiscFile>* files, std::string* error)
{
    if (error != nullptr) {
        error->clear();
    }

    if (path == nullptr || path[0] == '\0' || image == nullptr || files == nullptr) {
        if (error != nullptr) {
            *error = "No disc image was given.";
        }
        return false;
    }

    files->clear();

    const fs::path image_path(path);
    std::string reason;
    Reader reader;

    if (lower_ascii(image_path.extension().string()) == ".cue") {
        if (!open_cue(image_path, reader, reason)) {
            if (error != nullptr) {
                *error = reason;
            }
            return false;
        }
    } else if (!open_raw(image_path, reader, reason)) {
        if (error != nullptr) {
            *error = reason;
        }
        return false;
    }

    // The descriptors start at sector 16: the primary one names the root, and the
    // Joliet one repeats it with the disc's own long file names.
    bool have_primary = false;
    bool have_joliet = false;
    Pending primary_root;
    Pending joliet_root;

    std::vector<unsigned char> block(kSectorSize);
    for (uint32_t lba = 16; lba < 16 + 32; lba++) {
        if (!read_block(reader, lba, block.data())) {
            break;
        }

        if (std::memcmp(block.data() + 1, "CD001", 5) != 0) {
            break;
        }

        const unsigned char type = block[0];
        if (type == 255) {
            break;
        }

        Record root;
        if (type == 1 && !have_primary) {
            if (read_le16(block.data() + 128) != kSectorSize) {
                if (error != nullptr) {
                    *error = "This ISO uses a sector size of its own, which is not supported.";
                }
                reader.file.close();
                return false;
            }
            if (!parse_record(block.data() + 156, 34, false, root) || !root.directory) {
                if (error != nullptr) {
                    *error = "The ISO 9660 root folder is damaged.";
                }
                reader.file.close();
                return false;
            }
            have_primary = true;
            primary_root.lba = root.lba;
            primary_root.size = root.size;
        } else if (type == 2 && !have_joliet) {
            const bool escape = std::memcmp(block.data() + 88, "%/@", 3) == 0
                || std::memcmp(block.data() + 88, "%/C", 3) == 0
                || std::memcmp(block.data() + 88, "%/E", 3) == 0;
            if (escape && parse_record(block.data() + 156, 34, true, root) && root.directory) {
                have_joliet = true;
                joliet_root.lba = root.lba;
                joliet_root.size = root.size;
            }
        }
    }

    if (!have_primary && !have_joliet) {
        if (error != nullptr) {
            *error = "This image has no ISO 9660 filesystem.";
        }
        reader.file.close();
        return false;
    }

    const bool joliet = have_joliet;
    if (!walk(reader, joliet, joliet ? joliet_root : primary_root, files, reason)) {
        if (error != nullptr) {
            *error = reason;
        }
        reader.file.close();
        return false;
    }

    if (files->empty()) {
        if (error != nullptr) {
            *error = "This image holds no files the launcher can read.";
        }
        reader.file.close();
        return false;
    }

    image->path = reader.path.string();
    image->stride = reader.stride;
    image->data_offset = reader.data_offset;
    image->first_sector = reader.first_sector;
    image->sectors = reader.sectors;

    reader.file.close();
    return true;
}

bool launcher_disc_extract(const LauncherDiscImage& image, const LauncherDiscFile& file,
    const char* destination, LauncherDiscProgress progress, void* context, std::string* error)
{
    if (destination == nullptr || destination[0] == '\0') {
        if (error != nullptr) {
            *error = "No place to write " + file.name + ".";
        }
        return false;
    }

    Reader reader;
    std::string reason;
    if (!open_at(reader, fs::path(image.path), image.stride, image.data_offset,
            image.first_sector, reason)) {
        if (error != nullptr) {
            *error = reason;
        }
        return false;
    }

    const fs::path target(destination);
    std::error_code ec;
    fs::create_directories(target.parent_path(), ec);
    if (ec) {
        if (error != nullptr) {
            *error = "Cannot create " + target.parent_path().string() + ": " + ec.message();
        }
        reader.file.close();
        return false;
    }

    // Never follow a symlink that may have been left behind by an earlier install.
    if (fs::is_symlink(fs::symlink_status(target, ec))) {
        fs::remove(target, ec);
    }

    FILE* output = std::fopen(destination, "wb");
    if (output == nullptr) {
        if (error != nullptr) {
            *error = "Cannot write " + target.string() + ". The device may be out of storage.";
        }
        reader.file.close();
        return false;
    }

    bool ok = true;
    uint64_t remaining = file.size;
    uint32_t lba = file.sector;

    std::vector<unsigned char> block(kSectorSize);
    while (remaining > 0) {
        if (!read_block(reader, lba, block.data())) {
            if (error != nullptr) {
                *error = "The disc image ends before " + file.name + " does.";
            }
            ok = false;
            break;
        }

        const size_t chunk = static_cast<size_t>(std::min<uint64_t>(remaining, kSectorSize));
        if (std::fwrite(block.data(), 1, chunk, output) != chunk) {
            if (error != nullptr) {
                *error = "Cannot write " + target.string() + ". The device may be out of storage.";
            }
            ok = false;
            break;
        }

        if (progress != nullptr) {
            progress(context, chunk);
        }

        remaining -= chunk;
        lba++;
    }

    if (std::fclose(output) != 0) {
        ok = false;
    }

    reader.file.close();

    if (!ok) {
        std::remove(destination);
    }

    return ok;
}
