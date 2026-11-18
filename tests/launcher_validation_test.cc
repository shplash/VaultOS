// Host-side tests for the launcher's game-specific installation validation and
// the separation of the two installations.
//
// These do not need iOS, SDL or either engine: the launcher core is plain C++
// and can be compiled with the system compiler, which is what CI does. They
// cover what a build cannot: that Fallout 1 and Fallout 2 layouts are validated
// differently, that the configuration goes to the right files, and that
// savegames are never touched.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

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

    // An archive that is not one of the games is refused before anything is
    // extracted. This is the path a stray archive takes when it is picked
    // alongside the game's own ZIP: the installation and the savegames stay as
    // they were, so no game file the engine reads can be replaced by it.
    {
        const fs::path junk = root / "holiday photos.zip";
        write_zip(junk, { { "readme.txt", "these are not game files" } });

        LauncherOptions options = options_for(LAUNCHER_GAME_FALLOUT1);
        CHECK(launcher_install_zip(junk.string().c_str(), fallout1.string().c_str(), &options)
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("master.dat") != std::string::npos);
        CHECK(!fs::exists(fallout1 / "readme.txt"));
        CHECK(file_contains(fallout1 / "master.dat", "test"));
        CHECK(file_contains(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));

        scan(fallout1, LAUNCHER_GAME_FALLOUT1, &info);
        CHECK(info.installed == 1);
    }

    // A Fallout 2 archive offered to Fallout 1 is refused too, so its
    // patch000.dat can never land in a Fallout 1 folder, and the files already
    // installed are left alone.
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
        write_file(fallout1 / "SAVEGAME" / "SLOT02" / "SAVE.DAT", "slot-two");

        char backup[1024] = { 0 };
        CHECK(launcher_backup_saves(fallout1.string().c_str(), LAUNCHER_GAME_FALLOUT1, backup,
                  static_cast<int32_t>(sizeof(backup))) == LAUNCHER_OK);
        CHECK(backup[0] != '\0');
        CHECK(fs::path(backup).filename().string().find("fo1-save-backup-") == 0);
        CHECK(fs::exists(fs::path(backup)));

        // The newer saves are replaced by the ones in the backup, so a slot that
        // is not in it must be gone afterwards.
        write_file(fallout1 / "SAVEGAME" / "SLOT07" / "SAVE.DAT", "newer");

        CHECK(launcher_import_saves(backup, fallout1.string().c_str()) == LAUNCHER_OK);
        CHECK(file_contains(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
        CHECK(file_contains(fallout1 / "SAVEGAME" / "SLOT02" / "SAVE.DAT", "slot-two"));
        CHECK(!fs::exists(fallout1 / "SAVEGAME" / "SLOT07" / "SAVE.DAT"));
    }

    // An archive that is not a backup is refused, and the saves stay put.
    {
        const fs::path wrong = root / "not a backup.zip";
        write_zip(wrong, { { "art/tiles.trx", "not a save" } });

        CHECK(launcher_import_saves(wrong.string().c_str(), fallout1.string().c_str())
            == LAUNCHER_ERROR);
        CHECK(std::string(launcher_last_error()).find("SAVEGAME") != std::string::npos);
        CHECK(file_contains(fallout1 / "SAVEGAME" / "SLOT01" / "save.dat", "save-data"));
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
