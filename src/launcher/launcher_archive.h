#ifndef FALLOUT_LAUNCHER_LAUNCHER_ARCHIVE_H_
#define FALLOUT_LAUNCHER_LAUNCHER_ARCHIVE_H_

#include <cstdint>
#include <string>
#include <vector>

// One file of a 7z or RAR archive, as the launcher learns of it before
// anything is written: enough to check the archive holds a game, and to show
// how much there is to unpack.
struct LauncherArchiveEntry {
    std::string name;
    uint64_t size;
};

// Bytes unpacked so far, for the launcher's progress bar.
typedef void (*LauncherArchiveProgress)(void* context, uint64_t bytes);

// Lists the files an archive holds without writing anything. Folders, links and
// anything else that is not a file are left out, and so is a name that would
// leave the folder the archive is unpacked into. Returns false and fills
// `error` when the archive cannot be read.
bool launcher_archive_open(const char* path, std::vector<LauncherArchiveEntry>* entries,
    std::string* error);

// Unpacks every file of the archive into `destination`, one block at a time, so
// no file is ever held in memory whole. A folder inside it is created as
// needed; a link is never created or followed, and a name that would leave
// `destination` is skipped. Returns false and fills `error` when the archive
// cannot be read or written.
bool launcher_archive_extract(const char* path, const char* destination,
    LauncherArchiveProgress progress, void* context, std::string* error);

#endif
