#ifndef FALLOUT_LAUNCHER_LAUNCHER_DISC_H_
#define FALLOUT_LAUNCHER_LAUNCHER_DISC_H_

#include <cstdint>
#include <string>
#include <vector>

// A game CD read straight from its image: the launcher needs the filesystem, not
// a mounted drive, so nothing is emulated.

struct LauncherDiscImage {
    std::string path;          // the file that holds the data track
    uint64_t stride = 2048;    // bytes per sector in that file
    uint64_t data_offset = 0;  // bytes into a sector where file data starts
    uint64_t first_sector = 0; // the data track's first sector in the file
    uint64_t sectors = 0;      // sectors the data track holds
};

// One file in the image, at the sector its data starts on.
struct LauncherDiscFile {
    std::string name; // path inside the image, forward slashes
    uint32_t sector = 0;
    uint64_t size = 0;
};

typedef void (*LauncherDiscProgress)(void* context, uint64_t bytes);

// Reads the image at `path` - an ISO, an IMG or a CUE naming its BIN - and
// lists every file in it, through Joliet when the disc carries it. Returns false
// and says why in `error` when there is no readable ISO 9660 filesystem.
bool launcher_disc_open(const char* path, LauncherDiscImage* image,
    std::vector<LauncherDiscFile>* files, std::string* error);

// Writes one file out a sector at a time. Returns false and says why in `error`
// when the image ends early or the file cannot be written.
bool launcher_disc_extract(const LauncherDiscImage& image, const LauncherDiscFile& file,
    const char* destination, LauncherDiscProgress progress, void* context, std::string* error);

#endif /* FALLOUT_LAUNCHER_LAUNCHER_DISC_H_ */
