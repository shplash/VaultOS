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
#include "game/gmouse.h"
#include "game/intface.h"
#include "game/main.h"
#include "plib/gnw/kb.h"
#include "plib/gnw/mouse.h"
#include "plib/gnw/svga.h"
#include "plib/gnw/winmain.h"

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

    SDL_ShowCursor(SDL_DISABLE);

    fallout::GNW95_isActive = true;
    return fallout::gnw_main(argc, argv);
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

// Fallout 1 has the same attack modes as its sequel; the engine binds N to
// intface_toggle_item_state and reports the current mode through
// intface_get_attack, so the on-screen button reads and cycles it the same way.
int has_item_in_hand()
{
    fallout::Object* item = nullptr;
    if (fallout::intface_get_current_item(&item) != 0) {
        return 0;
    }

    return item != nullptr ? 1 : 0;
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
        // Fallout 1 reloads through the weapon itself, not a separate button.
        return 0;
    case 9:
        // Any item in hand can be switched between its attack modes.
        return has_item_in_hand();
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
    case 9:
        // N toggles the attack mode, the key the engine binds for it.
        ios_send_scan_code(SDL_SCANCODE_N);
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

    // The icon carries the same meaning as in Fallout 2: one dot is the plain
    // attack, a dot with a crosshair is the aimed one.
    return aiming ? 2 : 1;
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
};

} // namespace

extern "C" const FalloutEngineAPI* fallout_engine_api(void)
{
    return &g_api;
}
