#include "launcher/launcher.h"
#include "launcher/launcher_archive.h"
#include "launcher/launcher_disc.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <mutex>
#include <string>
#include <vector>

#include <zlib.h>

namespace fs = std::filesystem;

namespace {

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

std::atomic<uint64_t> g_progress_done { 0 };
std::atomic<uint64_t> g_progress_total { 0 };

int64_t g_pack_bytes[LAUNCHER_LANGUAGE_SPANISH + 1];
int64_t g_pack_largest;

std::mutex g_message_mutex;
std::string g_status;
std::string g_error;

void set_status(const std::string& status)
{
    std::lock_guard<std::mutex> lock(g_message_mutex);
    g_status = status;
}

void set_error(const std::string& error)
{
    std::lock_guard<std::mutex> lock(g_message_mutex);
    g_error = error;
}

void clear_messages()
{
    std::lock_guard<std::mutex> lock(g_message_mutex);
    g_status.clear();
    g_error.clear();
}

std::string copy_message(const std::string& message)
{
    std::lock_guard<std::mutex> lock(g_message_mutex);
    return message;
}

bool fail(const std::string& error)
{
    set_error(error);
    return false;
}

std::string lower_ascii(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string quote(const std::string& value)
{
    return "'" + value + "'";
}

// ---------------------------------------------------------------------------
// ZIP reader
// ---------------------------------------------------------------------------

struct ZipEntry {
    std::string name; // sanitized, forward slashes
    uint16_t method = 0;
    uint32_t crc = 0;
    uint64_t compressed_size = 0;
    uint64_t uncompressed_size = 0;
    uint64_t local_header_offset = 0;
};

// One file a source can hand over, whichever container it came from.
struct SourceFile {
    std::string name;
    uint64_t size = 0;
    const ZipEntry* zip = nullptr; // set for a ZIP, which reads it in place
    size_t disc = 0;               // index into a disc image's file list
};

uint16_t read_u16(const unsigned char* data)
{
    return static_cast<uint16_t>(data[0] | (data[1] << 8));
}

uint32_t read_u32(const unsigned char* data)
{
    return static_cast<uint32_t>(data[0])
        | (static_cast<uint32_t>(data[1]) << 8)
        | (static_cast<uint32_t>(data[2]) << 16)
        | (static_cast<uint32_t>(data[3]) << 24);
}

bool read_at(std::ifstream& stream, uint64_t offset, void* data, size_t size)
{
    stream.clear();
    stream.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
    if (!stream) {
        return false;
    }
    stream.read(static_cast<char*>(data), static_cast<std::streamsize>(size));
    return stream.gcount() == static_cast<std::streamsize>(size);
}

bool is_junk_entry(const std::string& name)
{
    std::string lower = lower_ascii(name);
    size_t slash = lower.find_last_of('/');
    std::string base = slash == std::string::npos ? lower : lower.substr(slash + 1);

    if (base == ".ds_store" || base == "thumbs.db" || base == "desktop.ini") {
        return true;
    }
    if (base.size() >= 2 && base[0] == '.' && base[1] == '_') {
        return true; // AppleDouble metadata
    }
    if (lower == "__macosx" || lower.rfind("__macosx/", 0) == 0
        || lower.find("/__macosx/") != std::string::npos) {
        return true;
    }
    return false;
}

// Normalizes an archive path and rejects absolute paths and traversal.
bool sanitize_entry_name(const std::string& name, std::string& result)
{
    std::string path = name;
    std::replace(path.begin(), path.end(), '\\', '/');

    if (path.empty() || path[0] == '/') {
        return false;
    }
    if (path.size() >= 2 && std::isalpha(static_cast<unsigned char>(path[0])) && path[1] == ':') {
        return false;
    }

    std::vector<std::string> parts;
    size_t start = 0;
    while (start <= path.size()) {
        size_t slash = path.find('/', start);
        std::string part = slash == std::string::npos
            ? path.substr(start)
            : path.substr(start, slash - start);

        if (!part.empty() && part != ".") {
            if (part == "..") {
                return false;
            }
            parts.push_back(part);
        }

        if (slash == std::string::npos) {
            break;
        }
        start = slash + 1;
    }

    if (parts.empty()) {
        return false;
    }

    result.clear();
    for (size_t index = 0; index < parts.size(); index++) {
        if (index != 0) {
            result += '/';
        }
        result += parts[index];
    }

    return true;
}

bool load_archive(const char* path, std::ifstream& archive, std::vector<ZipEntry>& entries)
{
    archive.open(path, std::ios::binary);
    if (!archive) {
        return fail("Cannot open the game ZIP. Make sure the file is still available.");
    }

    archive.seekg(0, std::ios::end);
    std::streamoff end = archive.tellg();
    if (end < 22) {
        return fail("This file is not a valid ZIP archive.");
    }
    uint64_t file_size = static_cast<uint64_t>(end);

    // End of central directory record lives in the last 64 KB (maximum comment).
    uint64_t tail_size = std::min<uint64_t>(file_size, 65557);
    std::vector<unsigned char> tail(static_cast<size_t>(tail_size));
    if (!read_at(archive, file_size - tail_size, tail.data(), tail.size())) {
        return fail("Cannot read the ZIP archive.");
    }

    bool found = false;
    size_t eocd = 0;
    for (size_t index = tail.size() - 22 + 1; index-- > 0;) {
        if (read_u32(&tail[index]) != 0x06054b50) {
            continue;
        }
        uint16_t comment_length = read_u16(&tail[index + 20]);
        if (index + 22 + comment_length > tail.size()) {
            continue;
        }
        eocd = index;
        found = true;
        break;
    }

    if (!found) {
        return fail("This file is not a valid ZIP archive.");
    }

    uint16_t entry_count = read_u16(&tail[eocd + 10]);
    uint32_t directory_size = read_u32(&tail[eocd + 12]);
    uint32_t directory_offset = read_u32(&tail[eocd + 16]);

    if (entry_count == 0xffff || directory_size == 0xffffffff || directory_offset == 0xffffffff) {
        return fail("ZIP64 archives are not supported. Re-create the ZIP without ZIP64.");
    }

    if (entry_count == 0) {
        return fail("The ZIP archive is empty.");
    }

    if (static_cast<uint64_t>(directory_offset) + directory_size > file_size) {
        return fail("This ZIP archive is damaged (bad central directory).");
    }
    if (directory_size > 64 * 1024 * 1024) {
        return fail("This ZIP archive is too large to index.");
    }

    std::vector<unsigned char> directory(directory_size);
    if (!read_at(archive, directory_offset, directory.data(), directory.size())) {
        return fail("Cannot read the ZIP archive directory.");
    }

    entries.reserve(entry_count);

    size_t cursor = 0;
    for (uint16_t index = 0; index < entry_count; index++) {
        if (cursor + 46 > directory.size()) {
            return fail("This ZIP archive is damaged (truncated directory).");
        }
        if (read_u32(&directory[cursor]) != 0x02014b50) {
            return fail("This ZIP archive is damaged (bad directory entry).");
        }

        uint16_t flags = read_u16(&directory[cursor + 8]);
        uint16_t method = read_u16(&directory[cursor + 10]);
        uint32_t crc = read_u32(&directory[cursor + 16]);
        uint32_t compressed_size = read_u32(&directory[cursor + 20]);
        uint32_t uncompressed_size = read_u32(&directory[cursor + 24]);
        uint16_t name_length = read_u16(&directory[cursor + 28]);
        uint16_t extra_length = read_u16(&directory[cursor + 30]);
        uint16_t comment_length = read_u16(&directory[cursor + 32]);
        uint32_t local_offset = read_u32(&directory[cursor + 42]);

        if (cursor + 46 + name_length + extra_length + comment_length > directory.size()) {
            return fail("This ZIP archive is damaged (truncated directory entry).");
        }

        std::string raw_name(
            reinterpret_cast<const char*>(&directory[cursor + 46]),
            name_length);

        cursor += 46 + name_length + extra_length + comment_length;

        if (flags & 0x0001) {
            return fail("Password protected ZIP archives are not supported.");
        }

        bool is_directory = !raw_name.empty() && (raw_name.back() == '/' || raw_name.back() == '\\');
        std::string name;
        if (!sanitize_entry_name(raw_name, name)) {
            continue; // unsafe path, ignore it
        }

        if (is_junk_entry(name)) {
            continue;
        }

        if (method != 0 && method != 8) {
            return fail("The ZIP uses an unsupported compression method (only stored and deflate are supported).");
        }

        if (compressed_size == 0xffffffff || uncompressed_size == 0xffffffff || local_offset == 0xffffffff) {
            return fail("ZIP64 archives are not supported. Re-create the ZIP without ZIP64.");
        }

        if (is_directory) {
            continue;
        }

        ZipEntry entry;
        entry.name = std::move(name);
        entry.method = method;
        entry.crc = crc;
        entry.compressed_size = compressed_size;
        entry.uncompressed_size = uncompressed_size;
        entry.local_header_offset = local_offset;
        entries.push_back(std::move(entry));
    }

    if (entries.empty()) {
        return fail("The ZIP archive contains no usable files.");
    }

    return true;
}

bool has_data_folder(const std::vector<SourceFile>& entries, const std::string& prefix)
{
    std::string wanted = lower_ascii(prefix + "data/");

    for (const SourceFile& entry : entries) {
        if (lower_ascii(entry.name).rfind(wanted, 0) == 0) {
            return true;
        }
    }

    return false;
}

// Locates the folder containing the game: archives either store it at the root or
// inside a single wrapper folder, and preferring one that also holds `data` keeps
// an unrelated stray master.dat from winning.
std::string find_game_prefix(const std::vector<SourceFile>& entries)
{
    struct Candidate {
        std::string prefix;
        int depth;
        int priority;
    };

    std::vector<Candidate> candidates;

    for (const SourceFile& entry : entries) {
        size_t slash = entry.name.find_last_of('/');
        std::string base = lower_ascii(slash == std::string::npos ? entry.name : entry.name.substr(slash + 1));

        int priority;
        if (base == "master.dat") {
            priority = 0;
        } else if (base == "critter.dat") {
            priority = 1;
        } else {
            continue;
        }

        std::string directory = slash == std::string::npos ? "" : entry.name.substr(0, slash + 1);
        int depth = static_cast<int>(std::count(directory.begin(), directory.end(), '/'));
        candidates.push_back({ directory, depth, priority });
    }

    std::sort(candidates.begin(), candidates.end(), [](const Candidate& left, const Candidate& right) {
        if (left.depth != right.depth) {
            return left.depth < right.depth;
        }
        return left.priority < right.priority;
    });

    for (const Candidate& candidate : candidates) {
        if (has_data_folder(entries, candidate.prefix)) {
            return candidate.prefix;
        }
    }

    return candidates.empty() ? "" : candidates.front().prefix;
}

bool write_streamed(std::ofstream& output, const unsigned char* data, size_t size, uLong& crc, uint64_t& written)
{
    output.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
    if (!output) {
        return false;
    }
    crc = crc32(crc, data, static_cast<uInt>(size));
    written += size;
    g_progress_done.fetch_add(size);
    return true;
}

bool extract_entry(std::ifstream& archive, const ZipEntry& entry, const fs::path& destination)
{
    unsigned char header[30];
    if (!read_at(archive, entry.local_header_offset, header, sizeof(header))) {
        return fail("Cannot read " + quote(entry.name) + " from the ZIP.");
    }
    if (read_u32(header) != 0x04034b50) {
        return fail("The ZIP entry " + quote(entry.name) + " is damaged.");
    }

    uint16_t name_length = read_u16(header + 26);
    uint16_t extra_length = read_u16(header + 28);
    uint64_t data_offset = entry.local_header_offset + 30 + name_length + extra_length;

    archive.clear();
    archive.seekg(static_cast<std::streamoff>(data_offset), std::ios::beg);
    if (!archive) {
        return fail("Cannot read " + quote(entry.name) + " from the ZIP.");
    }

    std::error_code ec;
    fs::create_directories(destination.parent_path(), ec);
    if (ec) {
        return fail("Cannot create " + destination.parent_path().string() + ": " + ec.message());
    }

    // Never follow a symlink that may have been left behind by a previous install.
    if (fs::is_symlink(fs::symlink_status(destination, ec))) {
        fs::remove(destination, ec);
    }

    std::ofstream output(destination, std::ios::binary | std::ios::trunc);
    if (!output) {
        return fail("Cannot write " + destination.string() + ". The device may be out of storage.");
    }

    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t written = 0;
    bool ok = true;

    const size_t buffer_size = 64 * 1024;
    std::vector<unsigned char> input(buffer_size);
    std::vector<unsigned char> output_buffer(buffer_size);

    if (entry.method == 0) {
        uint64_t remaining = entry.compressed_size;
        while (remaining > 0) {
            size_t chunk = static_cast<size_t>(std::min<uint64_t>(remaining, buffer_size));
            archive.read(reinterpret_cast<char*>(input.data()), static_cast<std::streamsize>(chunk));
            if (archive.gcount() != static_cast<std::streamsize>(chunk)) {
                ok = fail("The ZIP entry " + quote(entry.name) + " is truncated.");
                break;
            }
            if (!write_streamed(output, input.data(), chunk, crc, written)) {
                ok = fail("Cannot write " + destination.string() + ". The device may be out of storage.");
                break;
            }
            remaining -= chunk;
        }
    } else {
        z_stream stream;
        std::memset(&stream, 0, sizeof(stream));

        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            return fail("Cannot initialize the decompressor.");
        }

        uint64_t remaining = entry.compressed_size;
        bool finished = false;

        while (ok && !finished) {
            if (stream.avail_in == 0 && remaining > 0) {
                size_t chunk = static_cast<size_t>(std::min<uint64_t>(remaining, buffer_size));
                archive.read(reinterpret_cast<char*>(input.data()), static_cast<std::streamsize>(chunk));
                if (archive.gcount() != static_cast<std::streamsize>(chunk)) {
                    ok = fail("The ZIP entry " + quote(entry.name) + " is truncated.");
                    break;
                }
                remaining -= chunk;
                stream.next_in = input.data();
                stream.avail_in = static_cast<uInt>(chunk);
            }

            stream.next_out = output_buffer.data();
            stream.avail_out = static_cast<uInt>(output_buffer.size());

            int result = inflate(&stream, Z_NO_FLUSH);
            if (result != Z_OK && result != Z_STREAM_END) {
                ok = fail("Cannot decompress " + quote(entry.name) + " (damaged ZIP).");
                break;
            }

            size_t produced = output_buffer.size() - stream.avail_out;
            if (produced > 0 && !write_streamed(output, output_buffer.data(), produced, crc, written)) {
                ok = fail("Cannot write " + destination.string() + ". The device may be out of storage.");
                break;
            }

            if (result == Z_STREAM_END) {
                finished = true;
            } else if (produced == 0 && stream.avail_in == 0 && remaining == 0) {
                ok = fail("The ZIP entry " + quote(entry.name) + " is damaged.");
                break;
            }
        }

        inflateEnd(&stream);
    }

    output.close();

    if (!ok) {
        std::error_code remove_ec;
        fs::remove(destination, remove_ec);
        return false;
    }

    if (written != entry.uncompressed_size) {
        std::error_code remove_ec;
        fs::remove(destination, remove_ec);
        return fail("The ZIP entry " + quote(entry.name) + " has an unexpected size.");
    }

    if (static_cast<uint32_t>(crc) != entry.crc) {
        std::error_code remove_ec;
        fs::remove(destination, remove_ec);
        return fail("The ZIP entry " + quote(entry.name) + " failed its integrity check.");
    }

    return true;
}

// ---------------------------------------------------------------------------
// Installed game layout
// ---------------------------------------------------------------------------

struct InstallLayout {
    std::string master_dat;
    std::string critter_dat;
    std::string patch000_dat;
    std::string ce_dat;
    std::string data_folder;
    std::string music_path;
};

bool is_fallout2(int32_t game)
{
    return game == LAUNCHER_GAME_FALLOUT2;
}

bool is_fallout2(const LauncherOptions& options)
{
    return is_fallout2(options.game);
}

const char* game_name(const LauncherOptions& options)
{
    return is_fallout2(options) ? "Fallout 2" : "Fallout";
}

std::string find_child(const fs::path& directory, const std::string& wanted, bool want_directory)
{
    std::error_code ec;
    fs::directory_iterator iterator(directory, ec);
    if (ec) {
        return "";
    }

    std::string wanted_lower = lower_ascii(wanted);

    for (const fs::directory_entry& entry : iterator) {
        std::string name = entry.path().filename().string();
        if (lower_ascii(name) != wanted_lower) {
            continue;
        }

        std::error_code type_ec;
        bool is_directory = entry.is_directory(type_ec);
        if (want_directory != is_directory) {
            continue;
        }

        return name;
    }

    return "";
}

InstallLayout detect_layout(const fs::path& install_dir)
{
    InstallLayout layout;
    layout.master_dat = find_child(install_dir, "master.dat", false);
    layout.critter_dat = find_child(install_dir, "critter.dat", false);
    layout.patch000_dat = find_child(install_dir, "patch000.dat", false);
    layout.ce_dat = find_child(install_dir, "ce.dat", false);
    layout.data_folder = find_child(install_dir, "data", true);

    if (!layout.data_folder.empty()) {
        std::string sound = find_child(install_dir / layout.data_folder, "sound", true);
        if (!sound.empty()) {
            std::string music = find_child(install_dir / layout.data_folder / sound, "music", true);
            if (!music.empty()) {
                layout.music_path = layout.data_folder + "/" + sound + "/" + music + "/";
            }
        }
    }

    if (layout.music_path.empty()) {
        std::string sound = find_child(install_dir, "sound", true);
        if (!sound.empty()) {
            std::string music = find_child(install_dir / sound, "music", true);
            if (!music.empty()) {
                layout.music_path = sound + "/" + music + "/";
            }
        }
    }

    if (layout.music_path.empty()) {
        layout.music_path = "sound/music/";
    }

    return layout;
}

fs::path savegame_root(const fs::path& install_dir)
{
    InstallLayout layout = detect_layout(install_dir);
    if (!layout.data_folder.empty()) {
        return install_dir / layout.data_folder / "SAVEGAME";
    }

    return install_dir / "SAVEGAME";
}

bool folder_has_saves(const fs::path& root)
{
    std::error_code ec;
    fs::directory_iterator iterator(root, ec);
    if (ec) {
        return false;
    }

    for (const fs::directory_entry& entry : iterator) {
        if (!entry.is_directory()) {
            continue;
        }
        if (!find_child(entry.path(), "save.dat", false).empty()) {
            return true;
        }
    }

    return false;
}

// Both engines write saves to SAVEGAME/SLOTnn under the patches directory, the
// game's own data folder. The original installation ships it, minimal archives
// often do not, so make sure it exists.
void ensure_save_directories(const fs::path& install_dir)
{
    std::error_code ec;
    const fs::path root = savegame_root(install_dir);
    for (int slot = 1; slot <= 10; slot++) {
        char name[16];
        std::snprintf(name, sizeof(name), "SLOT%02d", slot);
        fs::create_directories(root / name, ec);
        ec.clear();
    }
}

bool has_save_files(const fs::path& install_dir)
{
    return folder_has_saves(savegame_root(install_dir));
}

// Fallout 1 needs master.dat, critter.dat and the data folder. Fallout 2 also
// needs patch000.dat: upstream's installation notes list it as required data, and
// the engine loads it as its patch archive.
bool layout_is_complete(const InstallLayout& layout, int32_t game)
{
    return !layout.master_dat.empty()
        && !layout.critter_dat.empty()
        && !layout.data_folder.empty()
        && (!is_fallout2(game) || !layout.patch000_dat.empty());
}

std::string describe_missing(const InstallLayout& layout, int32_t game)
{
    std::string missing;
    if (layout.master_dat.empty()) {
        missing += "master.dat";
    }
    if (layout.critter_dat.empty()) {
        if (!missing.empty()) {
            missing += ", ";
        }
        missing += "critter.dat";
    }
    if (is_fallout2(game) && layout.patch000_dat.empty()) {
        if (!missing.empty()) {
            missing += ", ";
        }
        missing += "patch000.dat";
    }
    if (layout.data_folder.empty()) {
        if (!missing.empty()) {
            missing += ", ";
        }
        missing += "data folder";
    }
    return missing;
}

// ---------------------------------------------------------------------------
// Configuration files
// ---------------------------------------------------------------------------

const char* language_name(int32_t language)
{
    switch (language) {
    case LAUNCHER_LANGUAGE_FRENCH:
        return "french";
    case LAUNCHER_LANGUAGE_GERMAN:
        return "german";
    case LAUNCHER_LANGUAGE_ITALIAN:
        return "italian";
    case LAUNCHER_LANGUAGE_SPANISH:
        return "spanish";
    case LAUNCHER_LANGUAGE_ENGLISH:
    default:
        return "english";
    }
}

int clamp_int(int value, int minimum, int maximum)
{
    return std::max(minimum, std::min(maximum, value));
}

int volume_to_config(int32_t percent)
{
    int value = clamp_int(percent, 0, 100);
    return (value * 32767 + 50) / 100;
}

bool write_text_file(const fs::path& path, const std::string& contents)
{
    fs::path temporary = path;
    temporary += ".tmp";

    FILE* file = std::fopen(temporary.string().c_str(), "wb");
    if (file == NULL) {
        return fail("Cannot write " + path.string() + ": " + std::strerror(errno));
    }

    bool ok = std::fwrite(contents.data(), 1, contents.size(), file) == contents.size();
    if (std::fclose(file) != 0) {
        ok = false;
    }

    if (!ok) {
        std::remove(temporary.string().c_str());
        return fail("Cannot write " + path.string() + ". The device may be out of storage.");
    }

    std::error_code ec;
    fs::rename(temporary, path, ec);
    if (ec) {
        std::remove(temporary.string().c_str());
        return fail("Cannot replace " + path.string() + ": " + ec.message());
    }

    return true;
}

std::string build_game_config(const InstallLayout& layout, const LauncherOptions& options)
{
    std::string config;
    config += "; Generated by the Fallout Community Edition launcher.\n";
    config += "\n[system]\n";
    config += "executable=game\n";
    config += "master_dat=" + layout.master_dat + "\n";
    config += "master_patches=" + layout.data_folder + "\n";
    config += "critter_dat=" + layout.critter_dat + "\n";
    config += "critter_patches=" + layout.data_folder + "\n";
    config += std::string("language=") + language_name(options.language) + "\n";
    config += "hashing=1\n";
    config += "splash=0\n";
    config += "\n[preferences]\n";
    config += std::string("subtitles=") + (options.subtitles ? "1" : "0") + "\n";
    config += std::string("running=") + (options.always_run ? "1" : "0") + "\n";
    config += "target_highlight=" + std::to_string(clamp_int(options.target_highlight, 0, 2)) + "\n";
    config += "brightness=1.09\n";
    config += "\n[sound]\n";
    config += std::string("initialize=") + (options.sound ? "1" : "0") + "\n";
    config += std::string("sounds=") + (options.sound ? "1" : "0") + "\n";
    config += std::string("music=") + (options.music ? "1" : "0") + "\n";
    config += std::string("speech=") + (options.speech ? "1" : "0") + "\n";
    config += "master_volume=" + std::to_string(volume_to_config(options.master_volume)) + "\n";
    config += "music_volume=" + std::to_string(volume_to_config(options.music_volume)) + "\n";
    config += "sndfx_volume=" + std::to_string(volume_to_config(options.sfx_volume)) + "\n";
    config += "speech_volume=" + std::to_string(volume_to_config(options.speech_volume)) + "\n";
    config += "music_path1=" + layout.music_path + "\n";
    config += "music_path2=" + layout.music_path + "\n";
    return config;
}

std::string build_resolution_config(const LauncherOptions& options)
{
    int width = clamp_int(options.width, 640, 4096);
    int height = clamp_int(options.height, 480, 4096);

    std::string config;
    config += "; Generated by the Fallout Community Edition launcher.\n";
    config += "\n[MAIN]\n";
    config += "SCR_WIDTH=" + std::to_string(width) + "\n";
    config += "SCR_HEIGHT=" + std::to_string(height) + "\n";
    config += "WINDOWED=0\n";
    config += std::string("SCALE_2X=") + (options.scale_2x ? "1" : "0") + "\n";
    return config;
}

bool write_configs(const fs::path& install_dir, const InstallLayout& layout, const LauncherOptions& options)
{
    const bool fallout2 = is_fallout2(options);
    const char* game_config_name = fallout2 ? "fallout2.cfg" : "fallout.cfg";
    const char* resolution_config_name = fallout2 ? "f2_res.ini" : "f1_res.ini";

    if (!write_text_file(install_dir / game_config_name, build_game_config(layout, options))) {
        return false;
    }
    return write_text_file(install_dir / resolution_config_name, build_resolution_config(options));
}

// ---------------------------------------------------------------------------
// Public API helpers
// ---------------------------------------------------------------------------

bool get_install_info(const fs::path& install_dir, int32_t game, LauncherInstallInfo& info, InstallLayout& layout)
{
    std::memset(&info, 0, sizeof(info));

    std::error_code ec;
    if (!fs::is_directory(install_dir, ec)) {
        return false;
    }

    layout = detect_layout(install_dir);
    info.has_master_dat = !layout.master_dat.empty();
    info.has_critter_dat = !layout.critter_dat.empty();
    info.has_data_folder = !layout.data_folder.empty();
    info.has_patch_dat = !layout.patch000_dat.empty();
    info.has_ce_dat = !layout.ce_dat.empty();
    info.installed = layout_is_complete(layout, game) ? 1 : 0;

    info.has_music = find_child(install_dir, "sound", true).empty() ? 0 : 1;
    if (!layout.data_folder.empty()) {
        info.has_music = find_child(install_dir / layout.data_folder, "sound", true).empty()
            ? info.has_music
            : 1;
    }

    info.has_saves = has_save_files(install_dir) ? 1 : 0;

    uint64_t total = 0;
    if (info.has_master_dat) {
        std::error_code size_ec;
        uint64_t size = fs::file_size(install_dir / layout.master_dat, size_ec);
        if (!size_ec) {
            total += size;
        }
    }
    if (info.has_critter_dat) {
        std::error_code size_ec;
        uint64_t size = fs::file_size(install_dir / layout.critter_dat, size_ec);
        if (!size_ec) {
            total += size;
        }
    }
    for (const std::string& archive : { layout.patch000_dat, layout.ce_dat }) {
        if (archive.empty()) {
            continue;
        }
        std::error_code size_ec;
        uint64_t size = fs::file_size(install_dir / archive, size_ec);
        if (!size_ec) {
            total += size;
        }
    }
    info.data_bytes = static_cast<int64_t>(total);

    return true;
}

// ---------------------------------------------------------------------------
// Importing a game
// ---------------------------------------------------------------------------

void add_progress(void* context, uint64_t bytes)
{
    (void)context;
    g_progress_done.fetch_add(bytes);
}

// One source of game files: a ZIP read in place, a disc image read by sector,
// or a folder a 7z or RAR archive was unpacked into.
struct Source {
    bool disc = false;
    fs::path folder;
    std::ifstream archive;
    LauncherDiscImage image;
    std::vector<LauncherDiscFile> disc_files;
    std::vector<SourceFile> files;
};

// A folder of the app's own, removed when the import ends whatever its outcome,
// so nothing an image was unpacked from is left behind.
std::atomic<int> g_temp_counter { 0 };

struct TempFolder {
    fs::path path;

    bool create()
    {
        std::error_code ec;
        const fs::path root = fs::temp_directory_path(ec);
        if (ec) {
            return fail("Cannot reach the temporary folder.");
        }

        for (int attempt = 0; attempt < 100; attempt++) {
            const int index = g_temp_counter.fetch_add(1);
            const std::string name = "vaultos-import-"
                + std::to_string(static_cast<long long>(std::time(nullptr))) + "-"
                + std::to_string(index);
            path = root / name;
            ec.clear();
            if (fs::create_directory(path, ec)) {
                return true;
            }
        }

        return fail("Cannot create a temporary folder for the disc image.");
    }

    ~TempFolder()
    {
        if (path.empty()) {
            return;
        }
        std::error_code ec;
        fs::remove_all(path, ec);
    }
};

bool is_image_name(const std::string& name)
{
    const std::string lower = lower_ascii(name);
    for (const char* extension : { ".cue", ".iso", ".bin", ".img" }) {
        const size_t length = std::strlen(extension);
        if (lower.size() > length && lower.compare(lower.size() - length, length, extension) == 0) {
            return true;
        }
    }
    return false;
}

bool zip_has_master_dat(const std::vector<ZipEntry>& entries)
{
    for (const ZipEntry& entry : entries) {
        const std::string lower = lower_ascii(entry.name);
        const size_t slash = lower.find_last_of('/');
        if ((slash == std::string::npos ? lower : lower.substr(slash + 1)) == "master.dat") {
            return true;
        }
    }
    return false;
}

// A disc image inside a ZIP: the CUE first, since it names its own track, then a
// whole image, and a bare BIN last.
const ZipEntry* find_game_image(const std::vector<ZipEntry>& entries)
{
    const ZipEntry* cue = nullptr;
    const ZipEntry* iso = nullptr;
    const ZipEntry* img = nullptr;
    const ZipEntry* bin = nullptr;

    for (const ZipEntry& entry : entries) {
        if (is_junk_entry(entry.name)) {
            continue;
        }

        const std::string lower = lower_ascii(entry.name);
        const size_t length = lower.size();
        if (length > 4 && lower.compare(length - 4, 4, ".cue") == 0) {
            if (cue == nullptr) {
                cue = &entry;
            }
        } else if (length > 4 && lower.compare(length - 4, 4, ".iso") == 0) {
            if (iso == nullptr) {
                iso = &entry;
            }
        } else if (length > 4 && lower.compare(length - 4, 4, ".img") == 0) {
            if (img == nullptr) {
                img = &entry;
            }
        } else if (length > 4 && lower.compare(length - 4, 4, ".bin") == 0) {
            if (bin == nullptr) {
                bin = &entry;
            }
        }
    }

    if (cue != nullptr) {
        return cue;
    }
    if (iso != nullptr) {
        return iso;
    }
    if (img != nullptr) {
        return img;
    }
    return bin;
}

// The container is read from the file rather than asked for, so the picker has
// no format of its own and a wrongly named file still lands in the right reader.
enum class Container { Zip, Image, Archive };

bool has_archive_magic(const unsigned char* magic, std::streamsize read)
{
    if (read >= 6 && magic[0] == '7' && magic[1] == 'z' && magic[2] == 0xBC && magic[3] == 0xAF) {
        return true; // 7z
    }
    return read >= 4 && std::memcmp(magic, "Rar!", 4) == 0;
}

Container detect_container(const char* path)
{
    const std::string extension = lower_ascii(fs::path(path).extension().string());
    if (extension == ".iso" || extension == ".img" || extension == ".cue" || extension == ".bin") {
        return Container::Image;
    }
    if (extension == ".7z" || extension == ".rar") {
        return Container::Archive;
    }

    std::ifstream stream(path, std::ios::binary);
    if (stream) {
        unsigned char magic[6] = { 0 };
        stream.read(reinterpret_cast<char*>(magic), sizeof(magic));
        if (has_archive_magic(magic, stream.gcount())) {
            return Container::Archive;
        }
    }

    return Container::Zip;
}

// Windows installers cannot be run here: GOG's offline installers are one, and
// they say so rather than failing as an archive that cannot be opened.
bool reject_installer(const char* path)
{
    std::ifstream stream(path, std::ios::binary);
    if (!stream) {
        return true; // the archive reader reports a file that cannot be opened
    }

    unsigned char magic[2] = { 0, 0 };
    stream.read(reinterpret_cast<char*>(magic), sizeof(magic));
    if (stream.gcount() == 2 && magic[0] == 'M' && magic[1] == 'Z') {
        return fail("Windows installers cannot be run here. GOG's offline installers are one: unpack them on a computer with innoextract, or import the game CD as an ISO, BIN/CUE or IMG.");
    }

    return true;
}

// A file unpacked from an archive is moved into the installation a block at a
// time, so a large game file never sits in memory whole.
bool copy_source_file(const fs::path& source, const fs::path& destination)
{
    std::ifstream input(source.string(), std::ios::binary);
    if (!input) {
        return fail("Cannot read " + source.filename().string() + ".");
    }

    std::error_code ec;
    fs::create_directories(destination.parent_path(), ec);

    // Never follow a link an earlier import may have left behind.
    if (fs::is_symlink(fs::symlink_status(destination, ec))) {
        fs::remove(destination, ec);
    }

    std::ofstream output(destination.string(), std::ios::binary | std::ios::trunc);
    if (!output) {
        return fail("Cannot write " + destination.string() + ". The device may be out of storage.");
    }

    std::vector<char> block(64 * 1024);
    while (input) {
        input.read(block.data(), static_cast<std::streamsize>(block.size()));
        const std::streamsize read = input.gcount();
        if (read <= 0) {
            break;
        }

        output.write(block.data(), read);
        if (!output) {
            return fail("Cannot write " + destination.string()
                + ". The device may be out of storage.");
        }

        g_progress_done.fetch_add(static_cast<uint64_t>(read));
    }

    return true;
}

bool read_source_file(Source& source, const SourceFile& file, const fs::path& destination)
{
    if (!source.disc) {
        if (!source.folder.empty()) {
            return copy_source_file(source.folder / fs::path(file.name), destination);
        }
        return extract_entry(source.archive, *file.zip, destination);
    }

    std::string error;
    if (!launcher_disc_extract(source.image, source.disc_files[file.disc],
            destination.string().c_str(), add_progress, nullptr, &error)) {
        return fail(error.empty() ? "Cannot read " + quote(file.name) + " from the disc image." : error);
    }

    return true;
}

// The one installation path for every container: the same game validation,
// extraction and configuration, told what the files came from for its messages.
int install_source(Source& source, const fs::path& destination, const LauncherOptions& options,
    const char* kind)
{
    const std::string prefix = find_game_prefix(source.files);

    bool has_master = false;
    bool has_critter = false;
    bool has_patch = false;
    for (const SourceFile& file : source.files) {
        const std::string name = lower_ascii(file.name);
        if (name.size() < prefix.size() || name.compare(0, prefix.size(), lower_ascii(prefix)) != 0) {
            continue;
        }
        const std::string relative = name.substr(prefix.size());
        if (relative == "master.dat") {
            has_master = true;
        } else if (relative == "critter.dat") {
            has_critter = true;
        } else if (relative == "patch000.dat") {
            has_patch = true;
        }
    }

    const bool requires_patch = is_fallout2(options);
    const std::string from = std::string("This ") + kind + " doesn't look like a ";
    if (requires_patch && !has_patch) {
        fail(from + "Fallout 2 installation: patch000.dat not found. If this is the first game, choose Fallout in the launcher.");
        return LAUNCHER_ERROR;
    }
    if (!requires_patch && has_patch) {
        // patch000.dat only exists in Fallout 2. Extracting it over Fallout 1
        // mixes the two data sets and the engine crashes on the first map.
        fail(from + "Fallout installation: it contains patch000.dat. Choose Fallout 2 in the launcher first.");
        return LAUNCHER_ERROR;
    }
    if (!has_master || !has_critter) {
        std::string missing;
        if (!has_master) {
            missing = "master.dat";
        }
        if (!has_critter) {
            if (!missing.empty()) {
                missing += " and ";
            }
            missing += "critter.dat";
        }
        std::string message = from + game_name(options) + " installation: " + missing + " not found.";
        if (source.disc) {
            message += " If this is one disc of a set, import the disc that holds the game files.";
        }
        fail(message);
        return LAUNCHER_ERROR;
    }

    if (!has_data_folder(source.files, prefix)) {
        fail(from + game_name(options) + " installation: the data folder is missing.");
        return LAUNCHER_ERROR;
    }

    uint64_t total_bytes = 0;
    for (const SourceFile& file : source.files) {
        const std::string name = lower_ascii(file.name);
        if (name.size() < prefix.size() || name.compare(0, prefix.size(), lower_ascii(prefix)) != 0) {
            continue;
        }
        total_bytes += file.size;
    }

    // Unpacking an archive has a progress of its own, so this phase starts over.
    g_progress_done.store(0);
    g_progress_total.store(std::max<uint64_t>(total_bytes, 1));

    uint32_t extracted = 0;
    for (const SourceFile& file : source.files) {
        const std::string name = lower_ascii(file.name);
        if (name.size() < prefix.size() || name.compare(0, prefix.size(), lower_ascii(prefix)) != 0) {
            continue;
        }

        const std::string relative = file.name.substr(prefix.size());
        if (relative.empty()) {
            continue;
        }

        // Savegames are the player's data, never installation data: ignore any
        // entry that would replace them, in either folder a game keeps them in.
        const std::string lower_relative = lower_ascii(relative);
        if (lower_relative.rfind("savegame/", 0) == 0
            || lower_relative.rfind("data/savegame/", 0) == 0) {
            continue;
        }

        set_status("Installing " + relative + "...");

        if (!read_source_file(source, file, destination / fs::path(relative))) {
            return LAUNCHER_ERROR;
        }

        extracted++;
    }

    source.archive.close();

    if (extracted == 0) {
        fail(std::string("The ") + kind + " didn't contain any game files to install.");
        return LAUNCHER_ERROR;
    }

    set_status("Checking game data...");
    InstallLayout layout = detect_layout(destination);
    if (!layout_is_complete(layout, options.game)) {
        fail("Some game files are missing after extraction: " + describe_missing(layout, options.game) + ".");
        return LAUNCHER_ERROR;
    }

    ensure_save_directories(destination);

    set_status("Writing configuration...");
    if (!write_configs(destination, layout, options)) {
        return LAUNCHER_ERROR;
    }

    // A Fallout 1 folder must not keep Fallout 2's patch archive from an
    // earlier import: the engine reads it as game data and crashes.
    if (!is_fallout2(options)) {
        std::error_code remove_ec;
        fs::remove(destination / "patch000.dat", remove_ec);
    }

    g_progress_done.store(g_progress_total.load());
    set_status("Game data installed.");
    return LAUNCHER_OK;
}

int install_from_image(const fs::path& image_path, const fs::path& destination,
    const LauncherOptions& options)
{
    set_status("Reading the disc image...");

    Source source;
    source.disc = true;

    std::string error;
    if (!launcher_disc_open(image_path.string().c_str(), &source.image, &source.disc_files, &error)) {
        fail(error.empty() ? "This disc image has no readable ISO 9660 filesystem." : error);
        return LAUNCHER_ERROR;
    }

    for (size_t index = 0; index < source.disc_files.size(); index++) {
        source.files.push_back({ source.disc_files[index].name, source.disc_files[index].size,
            nullptr, index });
    }

    return install_source(source, destination, options, "disc image");
}

// A ZIP of a CD holds the disc rather than the game's own files: the image and
// the CUE beside it are unpacked into a folder of the app's own, and the same
// disc reader installs from there.
int install_from_zip_image(const char* zip_path, const std::vector<ZipEntry>& entries,
    const ZipEntry& image, const fs::path& destination, const LauncherOptions& options)
{
    TempFolder temporary;
    if (!temporary.create()) {
        return LAUNCHER_ERROR;
    }

    std::ifstream archive(zip_path, std::ios::binary);
    if (!archive) {
        fail("Cannot open the game ZIP.");
        return LAUNCHER_ERROR;
    }

    const size_t slash = image.name.find_last_of('/');
    const std::string directory = slash == std::string::npos ? std::string() : image.name.substr(0, slash + 1);

    uint64_t total = 0;
    for (const ZipEntry& entry : entries) {
        const std::string relative = entry.name.compare(0, directory.size(), directory) == 0
            ? entry.name.substr(directory.size())
            : std::string();
        if (!relative.empty() && relative.find('/') == std::string::npos && is_image_name(relative)) {
            total += entry.uncompressed_size;
        }
    }
    g_progress_total.store(std::max<uint64_t>(total, 1));

    for (const ZipEntry& entry : entries) {
        if (entry.name.compare(0, directory.size(), directory) != 0) {
            continue;
        }
        const std::string relative = entry.name.substr(directory.size());
        if (relative.empty() || relative.find('/') != std::string::npos || !is_image_name(relative)) {
            continue;
        }

        set_status("Unpacking " + relative + "...");
        if (!extract_entry(archive, entry, temporary.path / fs::path(relative))) {
            return LAUNCHER_ERROR;
        }
    }

    archive.close();

    return install_from_image(temporary.path / fs::path(image.name.substr(directory.size())),
        destination, options);
}

// A 7z or RAR archive is unpacked into a folder of the app's own, and the game
// is installed from there by the path every other container uses, so the same
// Fallout 1 and Fallout 2 checks see the same files.
int install_from_archive(const char* path, const fs::path& destination,
    const LauncherOptions& options)
{
    set_status("Reading the archive...");

    std::vector<LauncherArchiveEntry> entries;
    std::string error;
    if (!launcher_archive_open(path, &entries, &error)) {
        fail(error.empty() ? "This archive cannot be read." : error);
        return LAUNCHER_ERROR;
    }

    uint64_t total = 0;
    for (const LauncherArchiveEntry& entry : entries) {
        total += entry.size;
    }
    g_progress_done.store(0);
    g_progress_total.store(std::max<uint64_t>(total, 1));

    TempFolder temporary;
    if (!temporary.create()) {
        return LAUNCHER_ERROR;
    }

    set_status("Unpacking the archive...");
    if (!launcher_archive_extract(path, temporary.path.string().c_str(), add_progress, nullptr,
            &error)) {
        fail(error.empty() ? "This archive cannot be read." : error);
        return LAUNCHER_ERROR;
    }

    Source source;
    source.folder = temporary.path;

    std::error_code ec;
    fs::recursive_directory_iterator entry(temporary.path, ec);
    const fs::recursive_directory_iterator last;
    while (!ec && entry != last) {
        if (entry->is_regular_file(ec)) {
            const fs::path relative = entry->path().lexically_relative(temporary.path);
            const std::uintmax_t size = fs::file_size(entry->path(), ec);
            if (!ec && !relative.empty()) {
                source.files.push_back({ relative.generic_string(),
                    static_cast<uint64_t>(size), nullptr, 0 });
            }
        }
        entry.increment(ec);
    }

    if (ec) {
        fail("Cannot read the files unpacked from the archive.");
        return LAUNCHER_ERROR;
    }

    if (source.files.empty()) {
        fail("This archive holds no files the launcher can read.");
        return LAUNCHER_ERROR;
    }

    return install_source(source, destination, options, "archive");
}

} // namespace

// ---------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------

void launcher_default_options(LauncherOptions* options)
{
    if (options == NULL) {
        return;
    }

    std::memset(options, 0, sizeof(*options));
    options->width = 1280;
    options->height = 720;
    options->sound = 1;
    options->music = 1;
    options->speech = 1;
    options->master_volume = 70;
    options->music_volume = 70;
    options->sfx_volume = 70;
    options->speech_volume = 70;
    options->language = LAUNCHER_LANGUAGE_ENGLISH;
    options->game = LAUNCHER_GAME_FALLOUT1;
    options->target_highlight = 1;
}

void launcher_scan(const char* install_dir, int32_t game, LauncherInstallInfo* info)
{
    if (info == NULL) {
        return;
    }

    std::memset(info, 0, sizeof(*info));

    if (install_dir == NULL || install_dir[0] == '\0') {
        return;
    }

    InstallLayout layout;
    get_install_info(fs::path(install_dir), game, *info, layout);
}

int launcher_install_zip(const char* zip_path, const char* install_dir, const LauncherOptions* options)
{
    LauncherOptions defaults;
    if (options == NULL) {
        launcher_default_options(&defaults);
        options = &defaults;
    }

    clear_messages();
    g_progress_done.store(0);
    g_progress_total.store(0);
    set_status("Opening game archive...");

    if (zip_path == NULL || zip_path[0] == '\0') {
        fail("No game ZIP was selected.");
        return LAUNCHER_ERROR;
    }
    if (install_dir == NULL || install_dir[0] == '\0') {
        fail("No install folder was provided.");
        return LAUNCHER_ERROR;
    }

    fs::path destination(install_dir);
    std::error_code ec;
    fs::create_directories(destination, ec);
    if (ec) {
        fail("Cannot create the install folder: " + ec.message());
        return LAUNCHER_ERROR;
    }

    if (!reject_installer(zip_path)) {
        return LAUNCHER_ERROR;
    }

    switch (detect_container(zip_path)) {
    case Container::Image:
        return install_from_image(fs::path(zip_path), destination, *options);
    case Container::Archive:
        return install_from_archive(zip_path, destination, *options);
    case Container::Zip:
        break;
    }

    std::ifstream archive;
    std::vector<ZipEntry> entries;
    if (!load_archive(zip_path, archive, entries)) {
        return LAUNCHER_ERROR;
    }

    // A ZIP of a CD holds the disc image rather than the game's own files.
    if (!zip_has_master_dat(entries)) {
        const ZipEntry* image = find_game_image(entries);
        if (image != nullptr) {
            archive.close();
            return install_from_zip_image(zip_path, entries, *image, destination, *options);
        }
    }

    Source source;
    source.archive = std::move(archive);
    for (const ZipEntry& entry : entries) {
        source.files.push_back({ entry.name, entry.uncompressed_size, &entry, 0 });
    }

    return install_source(source, destination, *options, "ZIP");
}

// ---------------------------------------------------------------------------
// Language packs
// ---------------------------------------------------------------------------

// Finds the shallowest `<folder>` tree in the archive - `text/` for a language
// pack, `savegame/` for a backup - so a pack wrapped in a folder, or holding a
// whole data folder, is still found.
static std::string find_tree_prefix(const std::vector<ZipEntry>& entries, const char* folder, bool& found)
{
    const std::string wanted = lower_ascii(folder);
    std::string best;
    found = false;

    for (const ZipEntry& entry : entries) {
        const std::string lower = lower_ascii(entry.name);
        size_t position = lower.find(wanted);
        while (position != std::string::npos) {
            // Only the folder at the start of a path counts, not `art/text/`.
            if (position == 0 || lower[position - 1] == '/') {
                std::string prefix = entry.name.substr(0, position);
                if (!found || prefix.size() < best.size()) {
                    best = prefix;
                    found = true;
                }
                break;
            }
            position = lower.find(wanted, position + 1);
        }
    }

    return best;
}

// A pack's language folder under whichever name its edition used. The engine asks
// for `text/<language>` with the English name, so a pack shipped as text/FRANCAIS
// or text/DEUTSCH is stored under the name it looks for.
struct LanguageFolder {
    const char* folder;
    const char* canonical;
    int32_t bit;
};

const LanguageFolder kLanguageFolders[] = {
    { "english", "english", 1 << LAUNCHER_LANGUAGE_ENGLISH },
    { "englisch", "english", 1 << LAUNCHER_LANGUAGE_ENGLISH },
    { "anglais", "english", 1 << LAUNCHER_LANGUAGE_ENGLISH },
    { "french", "french", 1 << LAUNCHER_LANGUAGE_FRENCH },
    { "francais", "french", 1 << LAUNCHER_LANGUAGE_FRENCH },
    { "german", "german", 1 << LAUNCHER_LANGUAGE_GERMAN },
    { "deutsch", "german", 1 << LAUNCHER_LANGUAGE_GERMAN },
    { "italian", "italian", 1 << LAUNCHER_LANGUAGE_ITALIAN },
    { "italiano", "italian", 1 << LAUNCHER_LANGUAGE_ITALIAN },
    { "spanish", "spanish", 1 << LAUNCHER_LANGUAGE_SPANISH },
    { "espanol", "spanish", 1 << LAUNCHER_LANGUAGE_SPANISH },
};

// Rewrites the `text/<language>/` head of a pack entry to the name the engine
// looks for, and records the language the entry belongs to.
static std::string canonical_text_path(const std::string& relative, int32_t& languages)
{
    const size_t start = sizeof("text/") - 1;
    const size_t slash = relative.find('/', start);
    if (slash == std::string::npos) {
        return relative;
    }

    const std::string folder = lower_ascii(relative.substr(start, slash - start));
    for (const LanguageFolder& known : kLanguageFolders) {
        if (folder == known.folder) {
            languages |= known.bit;
            return std::string("text/") + known.canonical + relative.substr(slash);
        }
    }

    return relative;
}

static int canonical_language_index(const std::string& canonical)
{
    if (canonical == "english") {
        return LAUNCHER_LANGUAGE_ENGLISH;
    }
    if (canonical == "french") {
        return LAUNCHER_LANGUAGE_FRENCH;
    }
    if (canonical == "german") {
        return LAUNCHER_LANGUAGE_GERMAN;
    }
    if (canonical == "italian") {
        return LAUNCHER_LANGUAGE_ITALIAN;
    }
    if (canonical == "spanish") {
        return LAUNCHER_LANGUAGE_SPANISH;
    }

    return -1;
}

int launcher_install_language_pack(const char* zip_path, const char* install_dir, int32_t* out_languages)
{
    clear_messages();
    g_progress_done.store(0);
    g_progress_total.store(0);
    set_status("Opening language pack...");

    if (out_languages != NULL) {
        *out_languages = 0;
    }

    if (zip_path == NULL || zip_path[0] == '\0') {
        fail("No language pack was selected.");
        return LAUNCHER_ERROR;
    }

    if (install_dir == NULL || install_dir[0] == '\0') {
        fail("No install folder was provided.");
        return LAUNCHER_ERROR;
    }

    std::ifstream archive;
    std::vector<ZipEntry> entries;
    if (!load_archive(zip_path, archive, entries)) {
        return LAUNCHER_ERROR;
    }

    // A game ZIP is not a translation: picking one here used to write its text
    // tree over the other game's data, so refuse it before extracting.
    for (const ZipEntry& entry : entries) {
        const std::string name = lower_ascii(entry.name);
        const std::string base = name.substr(name.find_last_of('/') + 1);
        if (base == "master.dat" || base == "critter.dat" || base == "patch000.dat") {
            fail("That is a game ZIP, not a language pack. Use IMPORT GAME on HOME for it.");
            return LAUNCHER_ERROR;
        }
    }

    bool found = false;
    const std::string prefix = find_tree_prefix(entries, "text/", found);
    if (!found) {
        fail("This ZIP has no text folder. A language pack is the game's own data/text folder, zipped.");
        return LAUNCHER_ERROR;
    }

    struct PackFile {
        const ZipEntry* entry;
        std::string relative; // starts with "text/"
    };

    std::vector<PackFile> files;
    int32_t languages = 0;
    uint64_t total_bytes = 0;

    for (const ZipEntry& entry : entries) {
        if (lower_ascii(entry.name).compare(0, prefix.size(), lower_ascii(prefix)) != 0) {
            continue;
        }

        const std::string relative = entry.name.substr(prefix.size());
        if (lower_ascii(relative).rfind("text/", 0) != 0) {
            continue;
        }

        files.push_back({ &entry, canonical_text_path(relative, languages) });
        total_bytes += entry.uncompressed_size;
    }

    if (files.empty()) {
        fail("This ZIP has no text folder. A language pack is the game's own data/text folder, zipped.");
        return LAUNCHER_ERROR;
    }

    for (int index = 0; index <= LAUNCHER_LANGUAGE_SPANISH; index++) {
        g_pack_bytes[index] = 0;
    }
    g_pack_largest = 0;

    for (const PackFile& file : files) {
        const size_t start = sizeof("text/") - 1;
        const size_t slash = file.relative.find('/', start);
        if (slash == std::string::npos) {
            continue;
        }

        const int index = canonical_language_index(lower_ascii(file.relative.substr(start, slash - start)));
        if (index < 0) {
            continue;
        }

        g_pack_bytes[index] += static_cast<int64_t>(file.entry->uncompressed_size);
        if (g_pack_bytes[index] > g_pack_largest) {
            g_pack_largest = g_pack_bytes[index];
        }
    }

    // The engine reads `data` before master.dat, so a language the installation
    // does not carry has to land here to be seen.
    const InstallLayout layout = detect_layout(install_dir);
    const fs::path destination = fs::path(install_dir)
        / (layout.data_folder.empty() ? std::string("data") : layout.data_folder);
    std::error_code ec;
    fs::create_directories(destination, ec);
    if (ec) {
        fail("Cannot create " + destination.string() + ": " + ec.message());
        return LAUNCHER_ERROR;
    }

    g_progress_total.store(std::max<uint64_t>(total_bytes, 1));
    set_status("Adding language files...");

    for (const PackFile& file : files) {
        if (!extract_entry(archive, *file.entry, destination / fs::path(file.relative))) {
            return LAUNCHER_ERROR;
        }
    }

    archive.close();

    if (out_languages != NULL) {
        *out_languages = languages;
    }

    g_progress_done.store(g_progress_total.load());
    set_status("Language files added.");
    return LAUNCHER_OK;
}

// ---------------------------------------------------------------------------
// Savegame backups
// ---------------------------------------------------------------------------

static void write_u16(std::string& out, uint16_t value)
{
    out.push_back(static_cast<char>(value & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
}

static void write_u32(std::string& out, uint32_t value)
{
    out.push_back(static_cast<char>(value & 0xff));
    out.push_back(static_cast<char>((value >> 8) & 0xff));
    out.push_back(static_cast<char>((value >> 16) & 0xff));
    out.push_back(static_cast<char>((value >> 24) & 0xff));
}

// d(day)-m(month)-(time)-fo(1/2)-bkup-(year)-#(number): the newest backup
// sorts by name, and no two backups ever share one.
static std::string backup_name(int game, int number)
{
    const std::time_t now = std::time(nullptr);
    std::tm parts = {};
#if defined(_WIN32)
    localtime_s(&parts, &now);
#else
    localtime_r(&now, &parts);
#endif

    char name[64];
    if (std::snprintf(name, sizeof(name), "d%02d-m%02d-%02d%02d-%s-bkup-%04d-#%d",
            parts.tm_mday,
            parts.tm_mon + 1,
            parts.tm_hour,
            parts.tm_min,
            game == LAUNCHER_GAME_FALLOUT2 ? "fo2" : "fo1",
            parts.tm_year + 1900,
            number) <= 0) {
        return "saves";
    }
    return name;
}

// One past the highest number in the folder, so a backup that is already there
// is never replaced by a new one.
static int next_backup_number(const fs::path& folder)
{
    int highest = 0;

    std::error_code ec;
    for (fs::directory_iterator it(folder, ec), end; it != end; it.increment(ec)) {
        if (ec) {
            break;
        }

        const std::string name = it->path().filename().string();
        const size_t marker = name.rfind("-#");
        if (marker == std::string::npos) {
            continue;
        }

        int number = 0;
        for (size_t index = marker + 2; index < name.size() && name[index] >= '0' && name[index] <= '9'; index++) {
            number = number * 10 + (name[index] - '0');
        }
        if (number > highest) {
            highest = number;
        }
    }

    return highest + 1;
}

// Every file under a SAVEGAME folder, as a path relative to that folder.
static std::vector<std::string> savegame_files(const fs::path& root)
{
    std::vector<std::string> names;

    std::error_code ec;
    if (!fs::is_directory(root, ec)) {
        return names;
    }

    for (fs::recursive_directory_iterator it(root, ec), end; it != end; it.increment(ec)) {
        if (ec) {
            break;
        }

        const fs::path& path = it->path();
        if (fs::is_symlink(fs::symlink_status(path, ec)) || !fs::is_regular_file(path, ec)) {
            continue;
        }

        const std::string name = fs::relative(path, root, ec).generic_string();
        if (ec || name.empty()) {
            continue;
        }
        names.push_back(name);
    }

    std::sort(names.begin(), names.end());
    return names;
}

int launcher_backup_saves(const char* install_dir, int32_t game, char* out_path, int32_t out_size)
{
    clear_messages();
    set_status("Backing up saves...");

    if (out_path != NULL && out_size > 0) {
        out_path[0] = '\0';
    }

    if (install_dir == NULL || install_dir[0] == '\0') {
        fail("No install folder was provided.");
        return LAUNCHER_ERROR;
    }

    const fs::path root(install_dir);
    const fs::path saves = savegame_root(root);
    const std::vector<std::string> names = savegame_files(saves);
    if (names.empty()) {
        fail("No saved games to back up.");
        return LAUNCHER_ERROR;
    }

    struct CentralEntry {
        std::string name;
        uint32_t crc;
        uint32_t size;
        uint32_t offset;
    };

    std::string archive;
    std::vector<CentralEntry> central;

    for (const std::string& name : names) {
        const fs::path source = saves / fs::path(name);
        const std::string entry_name = "SAVEGAME/" + name;

        std::error_code size_ec;
        const auto file_size = fs::file_size(source, size_ec);
        if (size_ec || file_size > 0xffffffffull) {
            fail("Cannot read " + source.string() + ".");
            return LAUNCHER_ERROR;
        }

        std::string data(static_cast<size_t>(file_size), '\0');
        if (!data.empty()) {
            std::ifstream input(source, std::ios::binary);
            if (!input) {
                fail("Cannot read " + source.string() + ".");
                return LAUNCHER_ERROR;
            }
            input.read(&data[0], static_cast<std::streamsize>(data.size()));
            if (!input) {
                fail("Cannot read " + source.string() + ".");
                return LAUNCHER_ERROR;
            }
        }

        const uLong crc = crc32(crc32(0L, Z_NULL, 0),
            reinterpret_cast<const Bytef*>(data.data()),
            static_cast<uInt>(data.size()));

        CentralEntry entry;
        entry.name = entry_name;
        entry.crc = static_cast<uint32_t>(crc);
        entry.size = static_cast<uint32_t>(data.size());
        entry.offset = static_cast<uint32_t>(archive.size());

        write_u32(archive, 0x04034b50); // local file header
        write_u16(archive, 20);         // version needed
        write_u16(archive, 0);          // flags
        write_u16(archive, 0);          // method: stored
        write_u16(archive, 0);          // time
        write_u16(archive, 0);          // date
        write_u32(archive, entry.crc);
        write_u32(archive, entry.size); // compressed
        write_u32(archive, entry.size); // uncompressed
        write_u16(archive, static_cast<uint16_t>(entry_name.size()));
        write_u16(archive, 0);          // extra field length
        archive += entry_name;
        archive += data;

        central.push_back(entry);
    }

    const uint32_t directory_offset = static_cast<uint32_t>(archive.size());

    for (const CentralEntry& entry : central) {
        write_u32(archive, 0x02014b50); // central directory entry
        write_u16(archive, 20);         // version made by
        write_u16(archive, 20);         // version needed
        write_u16(archive, 0);          // flags
        write_u16(archive, 0);          // method: stored
        write_u16(archive, 0);          // time
        write_u16(archive, 0);          // date
        write_u32(archive, entry.crc);
        write_u32(archive, entry.size);
        write_u32(archive, entry.size);
        write_u16(archive, static_cast<uint16_t>(entry.name.size()));
        write_u16(archive, 0);          // extra field length
        write_u16(archive, 0);          // comment length
        write_u16(archive, 0);          // disk number
        write_u16(archive, 0);          // internal attributes
        write_u32(archive, 0);          // external attributes
        write_u32(archive, entry.offset);
        archive += entry.name;
    }

    const uint32_t directory_size = static_cast<uint32_t>(archive.size()) - directory_offset;
    const uint16_t count = static_cast<uint16_t>(central.size());

    write_u32(archive, 0x06054b50); // end of central directory
    write_u16(archive, 0);          // disk number
    write_u16(archive, 0);          // disk with the directory
    write_u16(archive, count);      // entries on this disk
    write_u16(archive, count);      // entries in total
    write_u32(archive, directory_size);
    write_u32(archive, directory_offset);
    write_u16(archive, 0);          // comment length

    // A folder of its own, so the game folder keeps only the game, and a
    // backup is never replaced: a second one inside the same minute takes the
    // next free name.
    const fs::path backups = root / "Backups";
    std::error_code folder_ec;
    fs::create_directories(backups, folder_ec);
    if (folder_ec) {
        fail("Cannot create " + backups.string() + ".");
        return LAUNCHER_ERROR;
    }

    const fs::path target = backups / (backup_name(game, next_backup_number(backups)) + ".zip");

    FILE* file = std::fopen(target.string().c_str(), "wb");
    if (file == NULL) {
        fail("Cannot write " + target.string() + ". The device may be out of storage.");
        return LAUNCHER_ERROR;
    }

    const bool written = std::fwrite(archive.data(), 1, archive.size(), file) == archive.size();
    const bool closed = std::fclose(file) == 0;
    if (!written || !closed) {
        std::remove(target.string().c_str());
        fail("Cannot write " + target.string() + ". The device may be out of storage.");
        return LAUNCHER_ERROR;
    }

    if (out_path != NULL && out_size > 0) {
        std::snprintf(out_path, static_cast<size_t>(out_size), "%s", target.string().c_str());
    }

    set_status("Saves backed up.");
    return LAUNCHER_OK;
}

int launcher_import_saves(const char* zip_path, const char* install_dir)
{
    clear_messages();
    g_progress_done.store(0);
    g_progress_total.store(0);
    set_status("Opening backup...");

    if (zip_path == NULL || zip_path[0] == '\0') {
        fail("No backup was selected.");
        return LAUNCHER_ERROR;
    }

    if (install_dir == NULL || install_dir[0] == '\0') {
        fail("No install folder was provided.");
        return LAUNCHER_ERROR;
    }

    std::ifstream archive;
    std::vector<ZipEntry> entries;
    if (!load_archive(zip_path, archive, entries)) {
        return LAUNCHER_ERROR;
    }

    bool found = false;
    const std::string prefix = find_tree_prefix(entries, "savegame/", found);
    if (!found) {
        fail("This ZIP has no SAVEGAME folder.");
        return LAUNCHER_ERROR;
    }

    struct SaveFile {
        const ZipEntry* entry;
        std::string relative;
    };

    std::vector<SaveFile> files;
    uint64_t total_bytes = 0;

    for (const ZipEntry& entry : entries) {
        if (lower_ascii(entry.name).compare(0, prefix.size(), lower_ascii(prefix)) != 0) {
            continue;
        }

        const std::string relative = entry.name.substr(prefix.size());
        if (lower_ascii(relative).rfind("savegame/", 0) != 0) {
            continue;
        }

        files.push_back({ &entry, relative });
        total_bytes += entry.uncompressed_size;
    }

    if (files.empty()) {
        fail("This ZIP has no SAVEGAME folder.");
        return LAUNCHER_ERROR;
    }

    const fs::path destination(install_dir);
    const fs::path saves = savegame_root(destination);

    // The import replaces rather than merges: a slot left behind by newer saves
    // would look like part of the backup. The launcher warns first.
    std::error_code ec;
    fs::remove_all(saves, ec);
    ec.clear();

    g_progress_total.store(std::max<uint64_t>(total_bytes, 1));
    set_status("Restoring saves...");

    for (const SaveFile& file : files) {
        const size_t slash = file.relative.find('/');
        if (slash == std::string::npos) {
            continue;
        }

        const std::string name = file.relative.substr(slash + 1);
        if (name.empty()) {
            continue;
        }

        if (!extract_entry(archive, *file.entry, saves / fs::path(name))) {
            return LAUNCHER_ERROR;
        }
    }

    archive.close();

    ensure_save_directories(destination);

    g_progress_done.store(g_progress_total.load());
    set_status("Saves restored.");
    return LAUNCHER_OK;
}

// A failure that repeats writes a line every time it is tried, and the note sits
// in Documents beside the game files, so it has to be bounded. It is bounded
// here rather than in each writer, so both engines keep the same limit.
void launcher_trim_log(const char* path, int32_t limit, int32_t keep)
{
    if (path == NULL || path[0] == '\0' || limit <= 0 || keep <= 0 || keep >= limit) {
        return;
    }

    std::error_code ec;
    const fs::path target(path);
    const uintmax_t size = fs::file_size(target, ec);
    if (ec || size <= static_cast<uintmax_t>(limit)) {
        return;
    }

    std::ifstream input(target, std::ios::binary);
    if (!input) {
        return;
    }

    input.seekg(static_cast<std::streamoff>(size - static_cast<uintmax_t>(keep)));
    std::string tail((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    input.close();

    // From the start of a line, so the note still reads as whole entries.
    const size_t newline = tail.find('\n');
    if (newline != std::string::npos && newline + 1 < tail.size()) {
        tail.erase(0, newline + 1);
    }

    // Written beside the log and renamed over it: the log is trimmed because
    // something just failed, the worst moment to empty the file it is about to
    // write to.
    const fs::path temporary = target.string() + ".trim";
    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) {
            return;
        }

        output.write(tail.data(), static_cast<std::streamsize>(tail.size()));
        if (!output) {
            output.close();
            fs::remove(temporary, ec);
            return;
        }
    }

    fs::rename(temporary, target, ec);
    if (ec) {
        fs::remove(temporary, ec);
    }
}

int launcher_write_options(const char* install_dir, const LauncherOptions* options)
{
    LauncherOptions defaults;
    if (options == NULL) {
        launcher_default_options(&defaults);
        options = &defaults;
    }

    clear_messages();

    if (install_dir == NULL || install_dir[0] == '\0') {
        fail("No install folder was provided.");
        return LAUNCHER_ERROR;
    }

    fs::path destination(install_dir);
    InstallLayout layout = detect_layout(destination);
    if (!layout_is_complete(layout, options->game)) {
        fail("Install the game data first (" + describe_missing(layout, options->game) + " missing).");
        return LAUNCHER_ERROR;
    }

    ensure_save_directories(destination);

    if (!write_configs(destination, layout, *options)) {
        return LAUNCHER_ERROR;
    }

    set_status("Settings saved.");
    return LAUNCHER_OK;
}

int64_t launcher_language_pack_bytes(int32_t language)
{
    if (language < 0 || language > LAUNCHER_LANGUAGE_SPANISH) {
        return 0;
    }

    return g_pack_bytes[language];
}

int64_t launcher_language_pack_largest(void)
{
    return g_pack_largest;
}

double launcher_progress(void)
{
    uint64_t total = g_progress_total.load();
    if (total == 0) {
        return 0.0;
    }
    uint64_t done = g_progress_done.load();
    double progress = static_cast<double>(done) / static_cast<double>(total);
    return std::max(0.0, std::min(1.0, progress));
}

const char* launcher_status(void)
{
    static thread_local std::string copy;
    copy = copy_message(g_status);
    return copy.c_str();
}

const char* launcher_last_error(void)
{
    static thread_local std::string copy;
    copy = copy_message(g_error);
    return copy.c_str();
}
