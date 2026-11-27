// Fallout 1 CE engine adapter.
//
// Compiled into the launcher application with the Fallout 1 engine. It replaces
// the winmain.cc entry point (not built on iOS) and exposes the engine's in-game
// touch controls through the shared C ABI.

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
#include "game/inventry.h"
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

    // The engine's start-up log, in the launcher's own folder: every step
    // printed as it completes or fails, so a game that stops before its first
    // frame leaves behind the step it stopped at.
    fallout::debug_register_log(fallout_engine_support_file("fallout1-log.txt"), "wt");

    // Which binary this log came from: the About page version alone cannot tell
    // a fresh install from a stale one, and a restored build tree compiles
    // incrementally, so __DATE__ can predate the source the IPA was built from.
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
        // The engine gives up with a plain return, which would close the app
        // with no explanation.
        fallout_ios_report_engine_failure(
            "The game stopped while starting up. The files it needs are missing "
            "or damaged, or the game data left over from an earlier import is "
            "in the way. Import the game ZIP again from the launcher's HOME "
            "page. A log naming the step that failed is in the VaultOS folder, "
            "as fallout1-log.txt.");
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

// Reloading lives in the interface, which loops item_w_try_reload on the active
// weapon when its slot is used: the same two calls are made here, so the button
// does exactly what the weapon slot does - on a weapon that takes ammunition and
// is not already full.
int has_reloadable_weapon()
{
    fallout::Object* item = nullptr;
    if (fallout::intface_get_current_item(&item) != 0 || !is_real_item(item)) {
        return 0;
    }

    return fallout::item_get_type(item) == fallout::ITEM_TYPE_WEAPON
            && fallout::item_w_max_ammo(item) > fallout::item_w_curr_ammo(item)
        ? 1
        : 0;
}

// A weapon that takes ammunition, full or not.
int has_firearm_in_hand()
{
    fallout::Object* item = nullptr;
    if (fallout::intface_get_current_item(&item) != 0 || !is_real_item(item)) {
        return 0;
    }

    return fallout::item_get_type(item) == fallout::ITEM_TYPE_WEAPON
            && fallout::item_w_max_ammo(item) > 0
        ? 1
        : 0;
}

void reload_active_weapon()
{
    int hitModeBefore = 0;
    bool aimingBefore = false;
    bool hadAttackBefore = fallout::intface_get_attack(&hitModeBefore, &aimingBefore) == 0;

    // The interface's own reload, sound included, so the button does what the
    // weapon slot does rather than a silent copy of half of it.
    fallout::intface_item_reload();

    if (!hadAttackBefore) {
        return;
    }

    for (int attempt = 0; attempt < fallout::INTERFACE_ITEM_ACTION_COUNT; attempt++) {
        int hitMode = 0;
        bool aiming = false;
        if (fallout::intface_get_attack(&hitMode, &aiming) == 0
            && hitMode == hitModeBefore
            && aiming == aimingBefore) {
            break;
        }

        fallout::intface_toggle_item_state();
    }
}

int screen();

int action_available(int action)
{
    switch (action) {
    case 5:
        return fallout::combat_can_end_combat() ? 1 : 0;
    case 6:
        return fallout::combat_can_skip_turn() ? 1 : 0;
    case 25:
        return fallout::isInCombat() ? 1 : 0;
    case 26:
        return has_firearm_in_hand() ? 1 : 0;
    case 21:
        return screen() == fallout::IOS_SCREEN_DIALOGUE ? 0 : 1;
    case 28:
    case 29:
    case 30:
    case 31:
        // ALL, DONE and the two quantity steps on the "MOVE ITEMS" window,
        // which the game drives itself: they exist only while it is on screen.
        return screen() == fallout::IOS_SCREEN_PICK_AMOUNT ? 1 : 0;
    default:
        break;
    }

    if (!fallout::intface_is_enabled()) {
        return 0;
    }

    switch (action) {
    case 3:
        return fallout::isInCombat() ? 0 : 1;
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
    case 22: {
        int width = 0;
        int height = 0;
        return fallout::ios_dialogue_button_rect(action, NULL, NULL, &width, &height) != 0 ? 1 : 0;
    }
    case 23:
    case 24:
        return screen() == fallout::IOS_SCREEN_BARTER ? 1 : 0;
    case 27:
        return screen() == fallout::IOS_SCREEN_GAME && !fallout::isInCombat() ? 1 : 0;
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
    case 23:
        ios_send_scan_code(SDL_SCANCODE_M);
        break;
    case 24:
        ios_send_scan_code(SDL_SCANCODE_T);
        break;
    case 27:
        ios_send_scan_code(SDL_SCANCODE_A);
        break;
    case 28:
        // ALL on the "MOVE ITEMS" window, read by that window's own loop.
        fallout::ios_move_timer_request = 1;
        break;
    case 29:
        fallout::ios_move_timer_request = 2;
        break;
    case 30:
        fallout::ios_move_timer_request = 3;
        break;
    case 31:
        fallout::ios_move_timer_request = 4;
        break;
    default:
        break;
    }
}

bool cameraIsPanning = false;
int cameraX = 0;
int cameraY = 0;
const int cameraSafeMargin = 5;

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

    int targetX = 0;
    int targetY = 0;
    fallout::mouse_get_position(&targetX, &targetY);

    if (!cameraIsPanning) {
        cameraIsPanning = true;
        cameraX = targetX;
        cameraY = targetY;
    }

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
    if (!cameraIsPanning) {
        return;
    }

    cameraIsPanning = false;

    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();

    int x = cameraX;
    int y = cameraY;

    if (width > cameraSafeMargin * 2) {
        if (x < cameraSafeMargin) {
            x = cameraSafeMargin;
        } else if (x > width - 1 - cameraSafeMargin) {
            x = width - 1 - cameraSafeMargin;
        }
    }

    if (height > cameraSafeMargin * 2) {
        if (y < cameraSafeMargin) {
            y = cameraSafeMargin;
        } else if (y > height - 1 - cameraSafeMargin) {
            y = height - 1 - cameraSafeMargin;
        }
    }

    fallout::mouse_set_position(x, y);
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

    // The logo is a tap; the intro is a full video and is held, like Fallout 2's.
    return movie == fallout::MOVIE_IPLOGO ? 1 : 2;
}

int screen()
{
    if (fallout::ios_screen != fallout::IOS_SCREEN_GAME) {
        return fallout::ios_screen;
    }

    return fallout::dialog_active() ? fallout::IOS_SCREEN_DIALOGUE : fallout::IOS_SCREEN_GAME;
}

int g_quick_save_serial = 0;

int quick_save()
{
    const int result = fallout::ios_quick_save_auto();
    if (result == 1) {
        g_quick_save_serial++;
    }

    return result;
}

int quick_save_serial()
{
    return g_quick_save_serial;
}

int auto_save_ready()
{
    if (fallout::obj_dude == nullptr || fallout::isInCombat() || fallout::moviePlaying()) {
        return 0;
    }

    return fallout::ios_screen == fallout::IOS_SCREEN_GAME
            && !fallout::dialog_active()
            && fallout::intface_is_enabled()
        ? 1
        : 0;
}

void auto_save()
{
    static int lastMinutes = -1;
    static Uint32 lastSave = 0;
    static Uint32 lastCheck = 0;
    const Uint32 now = SDL_GetTicks();

    if (lastCheck != 0 && now - lastCheck < 1000) {
        return;
    }
    lastCheck = now;

    const int minutes = fallout_engine_auto_save_minutes();

    if (minutes != lastMinutes) {
        lastMinutes = minutes;
        lastSave = now;
        return;
    }

    if (minutes <= 0 || lastSave == 0) {
        lastSave = now;
        return;
    }

    if (now - lastSave < static_cast<Uint32>(minutes) * 60000u) {
        return;
    }

    if (auto_save_ready() == 0) {
        return;
    }

    const int saved = fallout::ios_auto_save();
    lastSave = now;

    if (saved == 1) {
        g_quick_save_serial++;
    } else {
        fallout_engine_auto_save_failed();
    }
}

// The topmost menu window other than the game's display window, in game pixels:
// it is the panel the overlay hangs its buttons on.
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

int action_button_rect(int action, int* x, int* y, int* width, int* height)
{
    return fallout::ios_dialogue_button_rect(action, x, y, width, height);
}

int cursor_mode_requests()
{
    return fallout_engine_mode_requests();
}

void request_load_slot(int slot)
{
    fallout::loadsave_request_slot(slot);
}

// The recovery save the launcher asks for when the app leaves the foreground,
// and the note that the app is back, so a later one is written again.
int background_save()
{
    return fallout::loadsave_save_background();
}

void background_return()
{
    fallout::loadsave_background_return();
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
    quick_save_serial,
    action_button_rect,
    cursor_mode_requests,
    request_load_slot,
    background_save,
    background_return,
};

} // namespace

void fallout_engine_auto_save(void)
{
    auto_save();
}

extern "C" const FalloutEngineAPI* fallout_engine_api(void)
{
    return &g_api;
}
