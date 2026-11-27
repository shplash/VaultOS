#include "launcher/launcher_archive.h"

#include <archive.h>
#include <archive_entry.h>

#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

// The same limits the disc reader keeps, so no archive can fill the device
// before the game data is even looked at.
const size_t kMaxFiles = 50000;
const uint64_t kMaxTotalBytes = 8ull * 1024ull * 1024ull * 1024ull;
const size_t kBlockSize = 64 * 1024;

std::string message_of(struct archive* reader)
{
    const char* message = archive_error_string(reader);
    return message != nullptr && message[0] != '\0' ? std::string(message) : std::string();
}

// What went wrong, in words the launcher can show: the reader's own words when
// it has any, and the encrypted case named rather than left as a code.
std::string describe(struct archive* reader, const char* path)
{
    if (archive_read_has_encrypted_entries(reader) == 1) {
        return "This archive is encrypted. Unpack it on a computer first, or import the game folder itself.";
    }

    const std::string file = fs::path(path).filename().string();
    const std::string detail = message_of(reader);
    if (detail.empty()) {
        return "Cannot read " + file + ". It may be damaged.";
    }
    return "Cannot read " + file + ": " + detail + ".";
}

// The 7z and RAR readers, and nothing else: an archive of another format is
// refused with the reader's own message rather than guessed at.
bool open_reader(const char* path, struct archive** reader, std::string* error)
{
    struct archive* opened = archive_read_new();
    if (opened == nullptr) {
        *error = "Cannot start the archive reader.";
        return false;
    }

    archive_read_support_filter_none(opened);
    archive_read_support_format_7zip(opened);
    archive_read_support_format_rar(opened);
    archive_read_support_format_rar5(opened);

    if (archive_read_open_filename(opened, path, kBlockSize) != ARCHIVE_OK) {
        *error = describe(opened, path);
        archive_read_free(opened);
        return false;
    }

    *reader = opened;
    return true;
}

// A name as this project writes paths, or nothing when it would leave the
// folder the archive is unpacked into: an absolute path, a drive letter or a
// `..` anywhere in it is never followed.
bool safe_name(const std::string& raw, std::string* name)
{
    std::string value;
    value.reserve(raw.size());

    for (char character : raw) {
        if (character == '\\') {
            value += '/'; // an archive written on Windows names folders this way
        } else if (static_cast<unsigned char>(character) < 0x20) {
            return false; // a control character has no place in a file name
        } else {
            value += character;
        }
    }

    // "./data/art" and "data/art" are the same file.
    while (value.compare(0, 2, "./") == 0) {
        value.erase(0, 2);
    }

    if (value.empty() || value[0] == '/') {
        return false;
    }
    if (value.size() >= 2 && value[1] == ':') {
        return false;
    }

    size_t start = 0;
    while (true) {
        const size_t slash = value.find('/', start);
        const std::string part = value.substr(start,
            slash == std::string::npos ? std::string::npos : slash - start);
        if (part.empty() || part == "." || part == "..") {
            return false;
        }
        if (slash == std::string::npos) {
            break;
        }
        start = slash + 1;
    }

    *name = value;
    return true;
}

// Only the data of an archive is written. A folder, a link or a device node is
// never created, so nothing an archive holds can point outside the folder it is
// unpacked into.
bool is_regular(struct archive_entry* entry)
{
    if (archive_entry_symlink(entry) != nullptr || archive_entry_hardlink(entry) != nullptr) {
        return false;
    }

    switch (archive_entry_filetype(entry)) {
    case AE_IFDIR:
    case AE_IFLNK:
    case AE_IFBLK:
    case AE_IFCHR:
    case AE_IFIFO:
    case AE_IFSOCK:
        return false;
    default:
        // A 7z or RAR archive written on Windows carries no file type, and
        // everything in it is a file.
        return true;
    }
}

} // namespace

bool launcher_archive_open(const char* path, std::vector<LauncherArchiveEntry>* entries,
    std::string* error)
{
    if (error != nullptr) {
        error->clear();
    }

    if (entries == nullptr) {
        if (error != nullptr) {
            *error = "No place to list the archive in.";
        }
        return false;
    }
    entries->clear();

    if (path == nullptr || path[0] == '\0') {
        if (error != nullptr) {
            *error = "No archive was selected.";
        }
        return false;
    }

    struct archive* reader = nullptr;
    std::string reason;
    if (!open_reader(path, &reader, &reason)) {
        if (error != nullptr) {
            *error = reason;
        }
        return false;
    }

    uint64_t total = 0;
    while (true) {
        struct archive_entry* entry = nullptr;
        const int status = archive_read_next_header(reader, &entry);
        if (status == ARCHIVE_EOF) {
            break;
        }
        if (status < ARCHIVE_WARN) {
            reason = describe(reader, path);
            archive_read_free(reader);
            if (error != nullptr) {
                *error = reason;
            }
            return false;
        }

        std::string name;
        const char* stored = archive_entry_pathname(entry);
        if (!is_regular(entry) || stored == nullptr || !safe_name(stored, &name)) {
            archive_read_data_skip(reader);
            continue;
        }

        const la_int64_t size = archive_entry_size(entry);
        const uint64_t bytes = size > 0 ? static_cast<uint64_t>(size) : 0;

        if (entries->size() >= kMaxFiles) {
            reason = "This archive holds too many files.";
            archive_read_free(reader);
            if (error != nullptr) {
                *error = reason;
            }
            return false;
        }

        total += bytes;
        if (total > kMaxTotalBytes) {
            reason = "This archive is too large.";
            archive_read_free(reader);
            if (error != nullptr) {
                *error = reason;
            }
            return false;
        }

        entries->push_back({ name, bytes });
        archive_read_data_skip(reader);
    }

    archive_read_free(reader);

    if (entries->empty()) {
        if (error != nullptr) {
            *error = "This archive holds no files the launcher can read.";
        }
        return false;
    }

    return true;
}

bool launcher_archive_extract(const char* path, const char* destination,
    LauncherArchiveProgress progress, void* context, std::string* error)
{
    if (error != nullptr) {
        error->clear();
    }

    if (destination == nullptr || destination[0] == '\0') {
        if (error != nullptr) {
            *error = "No place to unpack the archive into.";
        }
        return false;
    }
    if (path == nullptr || path[0] == '\0') {
        if (error != nullptr) {
            *error = "No archive was selected.";
        }
        return false;
    }

    const fs::path root(destination);
    std::error_code ec;
    fs::create_directories(root, ec);
    if (ec) {
        if (error != nullptr) {
            *error = "Cannot create " + root.string() + ".";
        }
        return false;
    }

    struct archive* reader = nullptr;
    std::string reason;
    if (!open_reader(path, &reader, &reason)) {
        if (error != nullptr) {
            *error = reason;
        }
        return false;
    }

    std::vector<char> block(kBlockSize);
    size_t files = 0;
    uint64_t total = 0;
    bool ok = true;

    while (ok) {
        struct archive_entry* entry = nullptr;
        const int status = archive_read_next_header(reader, &entry);
        if (status == ARCHIVE_EOF) {
            break;
        }
        if (status < ARCHIVE_WARN) {
            reason = describe(reader, path);
            ok = false;
            break;
        }

        std::string name;
        const char* stored = archive_entry_pathname(entry);
        if (!is_regular(entry) || stored == nullptr || !safe_name(stored, &name)) {
            archive_read_data_skip(reader);
            continue;
        }

        if (files >= kMaxFiles) {
            reason = "This archive holds too many files.";
            ok = false;
            break;
        }
        files++;

        const fs::path target = root / fs::path(name);
        fs::create_directories(target.parent_path(), ec);
        if (ec) {
            reason = "Cannot create " + target.parent_path().string() + ".";
            ok = false;
            break;
        }

        // Never follow a link an earlier import may have left behind.
        if (fs::is_symlink(fs::symlink_status(target, ec))) {
            fs::remove(target, ec);
            ec.clear();
        }

        FILE* output = std::fopen(target.string().c_str(), "wb");
        if (output == nullptr) {
            reason = "Cannot write " + target.string() + ". The device may be out of storage.";
            ok = false;
            break;
        }

        while (true) {
            const la_ssize_t read = archive_read_data(reader, block.data(), block.size());
            if (read == 0) {
                break;
            }
            if (read < 0) {
                reason = describe(reader, path);
                ok = false;
                break;
            }

            const size_t bytes = static_cast<size_t>(read);
            if (std::fwrite(block.data(), 1, bytes, output) != bytes) {
                reason = "Cannot write " + target.string() + ". The device may be out of storage.";
                ok = false;
                break;
            }

            total += static_cast<uint64_t>(bytes);
            if (total > kMaxTotalBytes) {
                reason = "This archive is too large.";
                ok = false;
                break;
            }

            if (progress != nullptr) {
                progress(context, static_cast<uint64_t>(bytes));
            }
        }

        if (std::fclose(output) != 0 && ok) {
            reason = "Cannot write " + target.string() + ". The device may be out of storage.";
            ok = false;
        }

        if (!ok) {
            std::remove(target.string().c_str());
            break;
        }
    }

    archive_read_free(reader);

    if (!ok) {
        if (error != nullptr) {
            *error = reason;
        }
        return false;
    }

    return true;
}
