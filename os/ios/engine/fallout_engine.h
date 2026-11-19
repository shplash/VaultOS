#ifndef FALLOUT_IOS_ENGINE_H_
#define FALLOUT_IOS_ENGINE_H_

// The contract between the launcher application and an engine.
//
// Fallout 1 CE and Fallout 2 CE are separate programs that share most of their
// global symbol names (game_init, gnw_main, db_init, ...) and their global
// state. They cannot be linked into one image: the second definition of every
// such symbol wins or the link fails.
//
// The application therefore contains exactly one engine image at a time:
//
//   * Fallout 1 CE is linked into the launcher executable and always present.
//     It is entered through engine_fallout1.cc.
//   * Fallout 2 CE is built as Fallout2Engine.framework and loaded with dlopen
//     only when the player picks Fallout 2. It is entered through
//     engine_fallout2.cc.
//
// Each engine has its own copy of the globals in this ABI, so switching games
// never shares mutable engine state. Only SDL is shared: the framework binds
// its SDL calls to the instance already owned by the application, so a process
// has one SDL event pump, one video subsystem and one set of UIKit classes.
//
// Everything the launcher needs from an engine goes through this small C ABI,
// which keeps the launcher independent of either engine's headers.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FALLOUT_ENGINE_ABI_VERSION 4

// Callbacks the engine may use to talk back to the launcher application.
// They are implemented by the application and passed to the engine before run()
// is called. Keeping them in a struct means the engine framework has no
// undefined references to application symbols.
typedef struct FalloutEngineHost {
    int32_t abi_version;
    void (*install_controls)(void);
    void (*menu_music_start)(void);
    void (*menu_music_stop)(void);

    // Lets the touch overlay refresh what it offers - which controls are
    // available, whether reload and attack mode exist, what the action button
    // says. Called from the engine's own loop, on the main thread between
    // frames, which is the only place it is safe: the overlay must never be
    // asked to do this from a timer of its own interrupting the engine.
    void (*refresh_controls)(void);
} FalloutEngineHost;

typedef struct FalloutEngineAPI {
    int32_t abi_version;

    // "fallout1" or "fallout2". Used to reject a wrongly named framework.
    const char* identifier;

    // Stores the host callbacks. Called once before run().
    void (*set_host)(const FalloutEngineHost* host);

    // Sets the engine's install directory. The engine changes into this
    // directory when it starts, so every relative path it uses (config files,
    // SAVEGAME, data folder, master.dat) stays inside its own installation.
    void (*set_install_dir)(const char* path);

    // Starts the engine. Blocks until the player exits the game.
    int (*run)(int argc, char** argv);

    // In-game touch controls.
    int (*action_available)(int action);
    void (*press_action)(int action);
    void (*camera_pan)(double x, double y);
    void (*camera_stop)(void);
    void (*right_click)(void);
    void (*back)(void);
    int (*cursor_mode)(void);
    void (*screen_size)(int* width, int* height);
    void (*set_cursor_speed)(double value);

    // Pause and resume the engine's audio when the app leaves the foreground.
    void (*pause_audio)(void);
    void (*resume_audio)(void);

    // Fallout 2: the selected attack/fire mode (INTERFACE_ITEM_ACTION_*), or
    // -1 when the game has no weapon mode to report. Fallout 1 returns -1.
    int (*fire_mode)(void);

    int (*in_game)(void);

    // 0 when no movie is playing, 1 for a startup movie that a tap may skip,
    // and 2 for any other movie, which the overlay lets the player skip only by
    // holding the button.
    int (*movie_state)(void);
} FalloutEngineAPI;

// Exported by the in-process Fallout 1 adapter and by Fallout2Engine.framework.
const FalloutEngineAPI* fallout_engine_api(void);

#ifdef __cplusplus
}
#endif

#endif /* FALLOUT_IOS_ENGINE_H_ */
