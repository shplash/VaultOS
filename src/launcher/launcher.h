#ifndef FALLOUT_LAUNCHER_LAUNCHER_H_
#define FALLOUT_LAUNCHER_LAUNCHER_H_

// Launcher support.
//
// The launcher accepts a ZIP with a Fallout installation (master.dat,
// critter.dat and the data folder, optionally nested in a top level folder),
// extracts it into an install directory and generates the configuration files
// the engine needs - `fallout.cfg` and `f1_res.ini`.
//
// This API is plain C so it can be consumed from Swift through a bridging
// header. Installation is synchronous and may take a while for a full game
// installation; call it from a background thread and poll
// `launcher_progress`/`launcher_status` for UI updates.

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// Games supported by the launcher.
enum {
    LAUNCHER_GAME_FALLOUT1 = 1,
    LAUNCHER_GAME_FALLOUT2 = 2,
};

// Languages supported by the engine.
enum {
    LAUNCHER_LANGUAGE_ENGLISH = 0,
    LAUNCHER_LANGUAGE_FRENCH = 1,
    LAUNCHER_LANGUAGE_GERMAN = 2,
    LAUNCHER_LANGUAGE_ITALIAN = 3,
    LAUNCHER_LANGUAGE_SPANISH = 4,
};

// Result codes.
enum {
    LAUNCHER_OK = 0,
    LAUNCHER_ERROR = -1,
};

typedef struct LauncherOptions {
    // Internal render resolution. The engine clamps these to 640x480.
    int32_t width;
    int32_t height;

    // Render at half resolution and scale up (chunky pixels).
    int32_t scale_2x;

    // Audio toggles.
    int32_t sound;
    int32_t music;
    int32_t speech;

    // Audio volumes, 0-100.
    int32_t master_volume;
    int32_t music_volume;
    int32_t sfx_volume;
    int32_t speech_volume;

    // Gameplay preferences.
    int32_t subtitles;
    int32_t always_run;

    // One of LAUNCHER_LANGUAGE_*.
    int32_t language;

    // One of LAUNCHER_GAME_*. Selects the config filenames and the game name
    // used in diagnostics.
    int32_t game;
} LauncherOptions;

typedef struct LauncherInstallInfo {
    // Set when master.dat, critter.dat and the data folder are all present.
    int32_t installed;
    int32_t has_master_dat;
    int32_t has_critter_dat;
    int32_t has_data_folder;
    int32_t has_patch_dat;
    int32_t has_ce_dat;
    int32_t has_music;
    // Set when a SAVEGAME folder exists (saves are never touched).
    int32_t has_saves;
    // Combined size of master.dat and critter.dat, in bytes.
    int64_t data_bytes;
} LauncherInstallInfo;

// Fills `options` with the defaults used by the launcher.
void launcher_default_options(LauncherOptions* options);

// Inspects `install_dir` for game data. `info` is always fully initialized.
// `game` is one of LAUNCHER_GAME_*.
void launcher_scan(const char* install_dir, int32_t game, LauncherInstallInfo* info);

// Extracts the game data from `zip_path` into `install_dir` and writes the
// configuration files. Existing files are overwritten; savegames are left
// alone. Returns LAUNCHER_OK on success, LAUNCHER_ERROR otherwise.
int launcher_install_zip(const char* zip_path, const char* install_dir, const LauncherOptions* options);

// Rewrites `fallout.cfg` and `f1_res.ini` for an existing installation.
int launcher_write_options(const char* install_dir, const LauncherOptions* options);

// iOS game controls (implemented in Swift, input helpers in Objective-C++).
void fallout_ios_install_game_controls(void);
void fallout_ios_camera_pan(double x, double y);
void fallout_ios_camera_stop(void);
void fallout_ios_right_click(void);
void fallout_ios_back(void);
void fallout_ios_set_cursor_speed(double value);
int fallout_ios_cursor_mode(void);
void fallout_ios_screen_size(int* width, int* height);
int fallout_ios_action_available(int action);
void fallout_ios_press_action(int action);
void fallout_ios_menu_music_start(void);
void fallout_ios_menu_music_stop(void);
void fallout_ios_pause_game_audio(void);
void fallout_ios_resume_game_audio(void);

// Installation progress, 0..1. Only meaningful while an install is running.
double launcher_progress(void);

// Human readable status of the last/current operation.
const char* launcher_status(void);

// Human readable error of the last failed operation.
const char* launcher_last_error(void);

// iOS only: runs the main run loop until fallout_launcher_finish stops it.
// Implemented in Objective-C++.
void fallout_ios_run_launcher_loop(void);

// iOS only: called by the launcher when the user is done configuring. Implemented
// in Objective-C++. This header is also the Swift bridging header, so the entry
// point (`fallout_ios_present_launcher`, implemented in Swift) is declared by
// os/ios/host/HostMain.mm instead to avoid a duplicate declaration.
void fallout_launcher_finish(int launch_game);

// iOS only: whether the engine should boot after the launcher closed.
int fallout_ios_should_launch_game(void);

#if defined(__cplusplus)
}
#endif

#endif /* FALLOUT_LAUNCHER_LAUNCHER_H_ */
