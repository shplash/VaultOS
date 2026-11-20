// Fallout 1 CE engine adapter.
//
// This file is compiled into the launcher application together with the
// Fallout 1 engine. It replaces the executable entry point from winmain.cc
// (which is not compiled on iOS) and exposes the engine's in-game touch
// controls through the shared C ABI.

#include <SDL.h>

#include <cmath>
#include <unistd.h>

#include "audio_engine.h"
#include "engine_glue.h"
#include "fallout_engine.h"
#include "game/combat.h"
#include "game/combat_defs.h"
#include "game/game_vars.h"
#include "game/gdialog.h"
#include "game/gmouse.h"
#include "game/gmovie.h"
#include "game/intface.h"
#include "game/ios_screen.h"
#include "game/item.h"
#include "game/loadsave.h"
#include "game/main.h"
#include "game/mainmenu.h"
#include "game/map.h"
#include "game/object.h"
#include "game/object_types.h"
#include "int/movie.h"
#include "launcher/launcher.h"
#include "plib/gnw/debug.h"
#include "plib/gnw/gnw.h"
#include "plib/gnw/kb.h"
#include "plib/gnw/mouse.h"
#include "plib/gnw/svga.h"
#include "plib/gnw/winmain.h"
#include "vaultos_build_sha.h"

namespace {

void set_host(const FalloutEngineHost* host)
{
    fallout_engine_set_host(host);
}

void set_install_dir(const char* path)
{
    fallout_engine_set_install_dir(path);
}

int run(int argc, char** argv)
{
    SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0");
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");

    const char* installDir = fallout_engine_install_dir();
    if (installDir[0] != '\0') {
        chdir(installDir);
    }

    // The engine's own log, written beside the game data. Start-up prints every
    // step it completes and every step that fails, so a game that stops before
    // its first frame leaves behind the step it stopped at - and the player can
    // open the file in the Files app instead of guessing.
    fallout::debug_register_log("vaultos-log.txt", "wt");

    // Which binary this log came from. Without it there is no way to tell a
    // fresh install from a stale one, and every build writes the same version
    // number to the About page. The commit is the reliable half: a restored
    // build tree compiles incrementally, so __DATE__ and __TIME__ can be older
    // than the source the IPA was made from.
    if (VAULTOS_BUILD_SHA[0] != '\0') {
        fallout::debug_printf("[vaultos] Fallout 1 engine built %s %s, commit %s\n",
            __DATE__,
            __TIME__,
            VAULTOS_BUILD_SHA);
    } else {
        fallout::debug_printf("[vaultos] Fallout 1 engine built %s %s\n", __DATE__, __TIME__);
    }

    SDL_ShowCursor(SDL_DISABLE);

    fallout::GNW95_isActive = true;

    int result = fallout::gnw_main(argc, argv);
    if (result != 0) {
        // The engine gives up with a plain return, which would leave the app
        // closing itself with no explanation at all.
        fallout_ios_report_engine_failure(
            "The game stopped while starting up. The files it needs are missing "
            "or damaged, or the game data left over from an earlier import is "
            "in the way. Import the game ZIP again from the launcher's HOME "
            "page. A log naming the step that failed is in vaultos-log.txt, "
            "beside your game files.");
    }

    return result;
}

void ios_send_scan_code(SDL_Scancode scanCode)
{
    fallout::KeyboardData key = {};
    key.key = scanCode;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

// The interface initialises both hand slots to (Object*)-1 (an upstream quirk
// in intface_init_items), so "no item" is either nullptr or that sentinel.
static bool is_real_item(fallout::Object* item)
{
    return item != nullptr && item != reinterpret_cast<fallout::Object*>(-1);
}

// Fallout 1 has the same attack modes as its sequel; the engine binds N to
// intface_toggle_item_state and reports the current mode through
// intface_get_attack, so the on-screen button reads and cycles it the same way.
int has_item_in_hand()
{
    fallout::Object* item = nullptr;
    if (fallout::intface_get_current_item(&item) != 0) {
        return 0;
    }

    return is_real_item(item) ? 1 : 0;
}

// Reloading in Fallout 1 lives in the interface, not on its own key: the
// interface loops item_w_try_reload on the active weapon when its slot is used.
// The same two calls are made here, so the on-screen button does exactly what
// the weapon slot does.
int has_reloadable_weapon()
{
    fallout::Object* item = nullptr;
    if (fallout::intface_get_current_item(&item) != 0 || !is_real_item(item)) {
        return 0;
    }

    // Same rule as Fallout 2's button: a weapon that takes ammunition.
    return fallout::item_get_type(item) == fallout::ITEM_TYPE_WEAPON
            && fallout::item_w_max_ammo(item) > 0
        ? 1
        : 0;
}

void reload_active_weapon()
{
    // The interface's own reload, sound included, so the on-screen button does
    // exactly what the game does when the weapon slot reloads - not a silent
    // copy of half of it.
    fallout::intface_item_reload();
}

int action_available(int action)
{
    if (!fallout::intface_is_enabled()) {
        return 0;
    }

    switch (action) {
    case 3:
        return fallout::isInCombat() ? 0 : 1;
    case 5:
        return fallout::isInCombat() ? 1 : 0;
    case 6:
        return fallout::combat_can_skip_turn() ? 1 : 0;
    case 8:
        // Reload: needs a loaded world and a weapon that takes ammunition.
        if (fallout::obj_dude == nullptr) {
            return 0;
        }
        return has_reloadable_weapon();
    case 9:
        // Attack-mode switch: needs a loaded world and an item in hand.
        if (fallout::obj_dude == nullptr) {
            return 0;
        }
        return has_item_in_hand();
    case 20:
        return fallout::dialog_active() ? 1 : 0;
    case 21:
        return fallout::dialog_active() ? 0 : 1;
    case 22:
        return fallout::dialog_active() ? 1 : 0;
    default:
        return 1;
    }
}

void press_action(int action)
{
    switch (action) {
    case 0:
        ios_send_scan_code(SDL_SCANCODE_I);
        break;
    case 1:
        ios_send_scan_code(SDL_SCANCODE_TAB);
        break;
    case 2:
        ios_send_scan_code(SDL_SCANCODE_C);
        break;
    case 3:
        ios_send_scan_code(SDL_SCANCODE_P);
        break;
    case 4:
        ios_send_scan_code(SDL_SCANCODE_S);
        break;
    case 5:
        ios_send_scan_code(SDL_SCANCODE_RETURN);
        break;
    case 6:
        ios_send_scan_code(SDL_SCANCODE_SPACE);
        break;
    case 7:
        // B is the game's change-active-hand binding.
        ios_send_scan_code(SDL_SCANCODE_B);
        break;
    case 8:
        reload_active_weapon();
        break;
    case 9:
        // N toggles the attack mode, the key the engine binds for it.
        ios_send_scan_code(SDL_SCANCODE_N);
        break;
    case 10:
        // SAVES opens the engine's save screen: game.cc binds KEY_CTRL_S and
        // KEY_F4 to SaveGame(1). F6 is a silent quick save into the quick slot
        // and F7 a quick load, and neither of those shows a screen.
        ios_send_scan_code(SDL_SCANCODE_F4);
        break;
    case 11:
        ios_send_scan_code(SDL_SCANCODE_F5);
        break;
    case 12:
        fallout::gmouse_set_cursor(fallout::MOUSE_CURSOR_CROSSHAIR);
        fallout::gmouse_3d_set_mode(fallout::GAME_MOUSE_MODE_CROSSHAIR);
        break;
    case 13:
        fallout::gmouse_set_cursor(fallout::MOUSE_CURSOR_ARROW);
        fallout::gmouse_3d_set_mode(fallout::GAME_MOUSE_MODE_MOVE);
        break;
    case 14:
        fallout::mouse_ios_left_click();
        break;
    case 16:
        fallout::mouse_ios_right_click();
        break;
    case 17:
        // INSPECT switched on: an item screen takes a touch as a click.
        fallout::ios_inspect = true;
        break;
    case 18:
        fallout::ios_inspect = false;
        break;
    case 19:
        // QUICK SAVE: the engine's own quick save into its own quick slot.
        ios_send_scan_code(SDL_SCANCODE_F6);
        break;
    case 20:
        ios_send_scan_code(SDL_SCANCODE_B);
        break;
    case 22:
        ios_send_scan_code(SDL_SCANCODE_A);
        break;
    default:
        break;
    }
}

void camera_pan(double x, double y)
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width <= 1 || height <= 1) {
        return;
    }

    // The engine scrolls only when the cursor touches a screen edge, so turn
    // the joystick into a directional edge target instead of a free cursor.
    const double deadzone = 0.30;
    const int dx = x < -deadzone ? -1 : (x > deadzone ? 1 : 0);
    const int dy = y < -deadzone ? -1 : (y > deadzone ? 1 : 0);

    int targetX = width / 2;
    int targetY = height / 2;
    if (dx < 0) {
        targetX = 0;
    } else if (dx > 0) {
        targetX = width - 1;
    }
    if (dy < 0) {
        targetY = 0;
    } else if (dy > 0) {
        targetY = height - 1;
    }

    fallout::mouse_set_position(targetX, targetY);
}

void camera_stop()
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width > 0 && height > 0) {
        fallout::mouse_set_position(width / 2, height / 2);
    }
}

void right_click()
{
    fallout::mouse_ios_right_click();
}

void back()
{
    fallout::KeyboardData key = {};
    key.key = SDL_SCANCODE_ESCAPE;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

int cursor_mode()
{
    const int mode = fallout::gmouse_3d_get_mode();
    if (mode == fallout::GAME_MOUSE_MODE_MOVE) {
        return 0;
    }
    if (mode == fallout::GAME_MOUSE_MODE_CROSSHAIR) {
        return 2;
    }
    // The skill modes all draw the yellow use crosshair, whether they were
    // picked in the skilldex or from an object's action menu.
    if (mode >= fallout::GAME_MOUSE_MODE_USE_CROSSHAIR) {
        return 3;
    }
    return 1;
}

void screen_size(int* width, int* height)
{
    if (width != NULL) {
        *width = fallout::screenGetWidth();
    }
    if (height != NULL) {
        *height = fallout::screenGetHeight();
    }
}

void set_cursor_speed(double value)
{
    fallout::mouse_set_ios_touch_sensitivity(value);
}

void pause_audio()
{
    fallout::audioEnginePause();
}

void resume_audio()
{
    fallout::audioEngineResume();
}

int fire_mode()
{
    int hitMode = 0;
    bool aiming = false;
    if (fallout::intface_get_attack(&hitMode, &aiming) != 0) {
        return -1;
    }

    // The interface's item states match Fallout 2's, so the same numbers are
    // reported and the launcher draws identical pictograms: 1 single, 2 aimed,
    // 3 secondary (burst), 4 aimed secondary.
    int mode;
    switch (hitMode) {
    case fallout::HIT_MODE_LEFT_WEAPON_SECONDARY:
    case fallout::HIT_MODE_RIGHT_WEAPON_SECONDARY:
        mode = 3;
        break;
    case fallout::HIT_MODE_LEFT_WEAPON_PRIMARY:
    case fallout::HIT_MODE_RIGHT_WEAPON_PRIMARY:
        mode = 1;
        break;
    default:
        return -1;
    }

    return aiming ? mode + 1 : mode;
}

int in_game()
{
    if (fallout::moviePlaying()) {
        return 0;
    }

    if (fallout::obj_dude == nullptr) {
        return 0;
    }

    if (fallout::isInCombat()) {
        return 1;
    }

    fallout::Window* window = fallout::GNW_find(fallout::display_win);
    if (window == nullptr || (window->flags & fallout::WINDOW_HIDDEN) != 0) {
        return 0;
    }

    return fallout::main_menu_is_shown() ? 0 : 1;
}

int movie_state()
{
    const int movie = fallout::gmovie_current;
    if (movie < 0) {
        return 0;
    }

    return movie == fallout::MOVIE_IPLOGO || movie == fallout::MOVIE_INTRO ? 1 : 2;
}

int screen()
{
    if (fallout::ios_screen != fallout::IOS_SCREEN_GAME) {
        return fallout::ios_screen;
    }

    return fallout::dialog_active() ? fallout::IOS_SCREEN_DIALOGUE : fallout::IOS_SCREEN_GAME;
}

// The engine's own quick save, into its own quick slot. The return value is the
// game's: 1 saved, 0 nothing to save, -1 failed.
int quick_save()
{
    return fallout::SaveGame(fallout::LOAD_SAVE_MODE_QUICK);
}

// The window of the menu the player is looking at, in game pixels. Every menu
// opens its own window, so the topmost one other than the game's display window
// is the panel the overlay should hang its buttons on.
int menu_rect(int* x, int* y, int* width, int* height)
{
    if (fallout::ios_screen == fallout::IOS_SCREEN_GAME) {
        return 0;
    }

    fallout::Rect rect;
    if (!fallout::win_top_menu_rect(fallout::display_win, &rect)) {
        return 0;
    }

    if (x != NULL) *x = rect.ulx;
    if (y != NULL) *y = rect.uly;
    if (width != NULL) *width = rect.lrx - rect.ulx + 1;
    if (height != NULL) *height = rect.lry - rect.uly + 1;
    return 1;
}

const FalloutEngineAPI g_api = {
    FALLOUT_ENGINE_ABI_VERSION,
    "fallout1",
    set_host,
    set_install_dir,
    run,
    action_available,
    press_action,
    camera_pan,
    camera_stop,
    right_click,
    back,
    cursor_mode,
    screen_size,
    set_cursor_speed,
    pause_audio,
    resume_audio,
    fire_mode,
    in_game,
    movie_state,
    screen,
    quick_save,
    menu_rect,
};

} // namespace

extern "C" const FalloutEngineAPI* fallout_engine_api(void)
{
    return &g_api;
}
