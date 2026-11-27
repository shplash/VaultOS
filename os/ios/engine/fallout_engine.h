#ifndef FALLOUT_IOS_ENGINE_H_
#define FALLOUT_IOS_ENGINE_H_

// The contract between the launcher application and an engine.
//
// Fallout 1 CE and Fallout 2 CE share most global symbol names and their global
// state, so they cannot be linked into one image: the second definition of a
// symbol wins, or the link fails. The app therefore holds one engine image at a
// time. Fallout 1 is linked into the executable and entered through
// engine_fallout1.cc; Fallout 2 is built as Fallout2Engine.framework and
// dlopen'ed through engine_fallout2.cc when the player picks it.
//
// Each engine gets its own copy of the globals in this ABI, so switching games
// never shares mutable engine state. Only SDL is shared: the framework binds its
// SDL calls to the instance the app already owns. Everything the launcher needs
// from an engine goes through this small C ABI.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FALLOUT_ENGINE_ABI_VERSION 12

// Callbacks the engine may use to talk back to the launcher application.
// They are implemented by the application and passed to the engine before run()
// is called. Keeping them in a struct means the engine framework has no
// undefined references to application symbols.
typedef struct FalloutEngineHost {
    int32_t abi_version;
    void (*install_controls)(void);
    void (*menu_music_start)(void);
    void (*menu_music_stop)(void);

    // Lets the overlay refresh what it offers: which controls are available,
    // whether reload and attack mode exist, what the action button says. Called
    // from the engine's own loop between frames, never from a timer.
    void (*refresh_controls)(void);

    // Takes the keyboard off the screen without touching the game, so a window
    // whose buttons it covers can still be closed. Called when Return is pressed.
    void (*hide_keyboard)(void);

    // Minutes between the launcher's timed quick saves, 0 for off.
    int32_t (*auto_save_minutes)(void);

    void (*auto_save_failed)(void);
} FalloutEngineHost;

typedef struct FalloutEngineAPI {
    int32_t abi_version;

    // "fallout1" or "fallout2". Used to reject a wrongly named framework.
    const char* identifier;

    // Stores the host callbacks. Called once before run().
    void (*set_host)(const FalloutEngineHost* host);

    // Sets the install directory; the engine changes into it, so every relative
    // path (config files, SAVEGAME, data, master.dat) stays inside its own
    // installation.
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

    // The screen the player is looking at: 0 the game view, 1 inventory, 2
    // loot, 3 barter, 4 dialogue, 5 character, 6 pip-boy, 7 skilldex, 8 automap,
    // 9 world map, 10 options, 11 save or load, 12 the use-on picker, 13 the
    // amount picker, 14 the called shot panel.
    int (*screen)(void);

    // The engine's own quick save, writing to its own quick slot: 1 when the
    // game was saved, 0 when there was nothing to save, -1 on failure. The
    // overlay only shows its tick on 1. NULL where the engine cannot report it.
    int (*quick_save)(void);

    // The rectangle, in game screen pixels, of the panel the player is looking
    // at, so the overlay can hang its buttons on the real window instead of a
    // table of guesses. Returns 0 on the game view or when it cannot say.
    int (*menu_rect)(int* x, int* y, int* width, int* height);

    // Counts every quick save the engine has written, the launcher's own timed
    // ones included, so the overlay can tick one nobody pressed.
    int (*quick_save_serial)(void);

    int (*action_button_rect)(int action, int* x, int* y, int* width, int* height);

    int (*cursor_mode_requests)(void);

    // The slot the launcher wants loaded as the game starts; 0 for none.
    void (*request_load_slot)(int slot);

    // The recovery save, written when the app leaves the foreground: 1 saved, 0
    // nothing to save or already saved for this background session, -1 failed.
    int (*background_save)(void);

    // The app is back: the next background save belongs to a new session, so a
    // later one is written again.
    void (*background_return)(void);
} FalloutEngineAPI;

// Exported by the in-process Fallout 1 adapter and by Fallout2Engine.framework.
const FalloutEngineAPI* fallout_engine_api(void);

#ifdef __cplusplus
}
#endif

#endif /* FALLOUT_IOS_ENGINE_H_ */
