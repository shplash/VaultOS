// Host-side tests for the launcher's game-specific installation validation and
// the separation of the two installations.
//
// These do not need iOS, SDL or either engine: the launcher core is plain C++
// and can be compiled with the system compiler, which is what CI does. They
// cover what a build cannot: that Fallout 1 and Fallout 2 layouts are validated
// differently, that the configuration goes to the right files, and that
// savegames are never touched.

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

#include "launcher/launcher.h"

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

int main()
{
    const fs::path root = fs::temp_directory_path() / "fallout-ce-launcher-tests";
    std::error_code ec;
    fs::remove_all(root, ec);
    fs::create_directories(root, ec);

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
    write_file(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat", "save-data");
    write_file(fallout2 / "SAVEGAME" / "SLOT03" / "save.dat", "other-save-data");
    {
        LauncherOptions fallout1Options = options_for(LAUNCHER_GAME_FALLOUT1);
        LauncherOptions fallout2Options = options_for(LAUNCHER_GAME_FALLOUT2);
        CHECK(launcher_write_options(fallout1.string().c_str(), &fallout1Options) == LAUNCHER_OK);
        CHECK(launcher_write_options(fallout2.string().c_str(), &fallout2Options) == LAUNCHER_OK);

        CHECK(file_contains(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
        CHECK(file_contains(fallout2 / "SAVEGAME" / "SLOT03" / "save.dat", "other-save-data"));

        scan(fallout1, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.has_saves == 1);
        scan(fallout2, LAUNCHER_GAME_FALLOUT2, &info);
        CHECK(info.has_saves == 1);

        // Neither game's settings appear in the other installation.
        CHECK(!fs::exists(fallout1 / "fallout2.cfg"));
        CHECK(!fs::exists(fallout2 / "fallout.cfg"));
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
