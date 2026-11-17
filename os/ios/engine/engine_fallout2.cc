// Fallout 2 CE engine adapter.
//
// This file is compiled into Fallout2Engine.framework only. It provides the
// entry point that src/win32.cc normally provides for a standalone app, plus
// the in-game touch controls, without modifying the upstream engine sources.

#include <SDL.h>

#include <cstdlib>
#include <unistd.h>

#include "audio_engine.h"
#include "combat.h"
#include "engine_glue.h"
#include "fallout_engine.h"
#include "game_mouse.h"
#include "interface.h"
#include "item.h"
#include "main.h"
#include "mouse.h"
#include "proto_types.h"
#include "svga.h"
#include "win32.h"

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

    if (SDL_Init(SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
        return EXIT_FAILURE;
    }

    atexit(SDL_Quit);

    SDL_ShowCursor(SDL_DISABLE);

    fallout::gProgramIsActive = true;
    return fallout::falloutMain(argc, argv);
}

// Fallout 2 CE reads input from SDL's event queue, so the touch controls are
// translated into ordinary SDL events. This needs no engine-specific input
// hooks and behaves exactly like a hardware keyboard or mouse.
void send_key(SDL_Scancode scanCode)
{
    SDL_Event event;
    SDL_zero(event);
    event.type = SDL_KEYDOWN;
    event.key.state = SDL_PRESSED;
    event.key.repeat = 0;
    event.key.keysym.scancode = scanCode;
    event.key.keysym.sym = SDL_GetKeyFromScancode(scanCode);
    SDL_PushEvent(&event);

    SDL_zero(event);
    event.type = SDL_KEYUP;
    event.key.state = SDL_RELEASED;
    event.key.repeat = 0;
    event.key.keysym.scancode = scanCode;
    event.key.keysym.sym = SDL_GetKeyFromScancode(scanCode);
    SDL_PushEvent(&event);
}

void send_mouse_button(Uint8 button, bool down)
{
    SDL_Event event;
    SDL_zero(event);
    event.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    event.button.button = button;
    event.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    event.button.clicks = 1;
    SDL_GetMouseState(&event.button.x, &event.button.y);
    SDL_PushEvent(&event);
}

// The reload and fire-mode keys only make sense while the player is actually
// aiming a firearm. The game targets with its crosshair cursor, and the active
// hand must hold a weapon that takes ammunition (melee weapons have no ammo
// capacity).
int has_firearm_in_hand()
{
    fallout::Object* item = nullptr;
    if (fallout::interfaceGetActiveItem(&item) != 0 || item == nullptr) {
        return 0;
    }

    return fallout::itemGetType(item) == fallout::ITEM_TYPE_WEAPON
            && fallout::ammoGetCapacity(item) > 0
        ? 1
        : 0;
}

int is_targeting()
{
    const int mode = fallout::gameMouseGetMode();
    return mode == fallout::GAME_MOUSE_MODE_CROSSHAIR
            || mode == fallout::GAME_MOUSE_MODE_USE_CROSSHAIR
        ? 1
        : 0;
}

int action_available(int action)
{
    if (!fallout::interfaceBarEnabled()) {
        return 0;
    }

    switch (action) {
    case 3:
        // The pip-boy is unavailable in combat.
        return fallout::isInCombat() ? 0 : 1;
    case 5:
    case 6:
        return fallout::isInCombat() ? 1 : 0;
    case 8:
    case 9:
        // Reload and fire mode: only while aiming a firearm.
        return is_targeting() && has_firearm_in_hand() ? 1 : 0;
    default:
        return 1;
    }
}

void press_action(int action)
{
    switch (action) {
    case 0:
        send_key(SDL_SCANCODE_I);
        break;
    case 1:
        send_key(SDL_SCANCODE_M);
        break;
    case 2:
        send_key(SDL_SCANCODE_C);
        break;
    case 3:
        send_key(SDL_SCANCODE_P);
        break;
    case 4:
        send_key(SDL_SCANCODE_S);
        break;
    case 5:
        send_key(SDL_SCANCODE_RETURN);
        break;
    case 6:
        send_key(SDL_SCANCODE_SPACE);
        break;
    case 7:
        send_key(SDL_SCANCODE_B);
        break;
    case 8:
        send_key(SDL_SCANCODE_R);
        break;
    case 9:
        send_key(SDL_SCANCODE_F);
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

    fallout::_mouse_set_position(targetX, targetY);
}

void camera_stop()
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width > 0 && height > 0) {
        fallout::_mouse_set_position(width / 2, height / 2);
    }
}

void right_click()
{
    // Two-finger tap in the engine's own touch handling is a right click; the
    // on-screen ACTION button sends the same pair of events directly.
    send_mouse_button(SDL_BUTTON_RIGHT, true);
    send_mouse_button(SDL_BUTTON_RIGHT, false);
}

void back()
{
    send_key(SDL_SCANCODE_ESCAPE);
}

int cursor_mode()
{
    const int mode = fallout::gameMouseGetMode();
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
    fallout::mouseSetSensitivity(value);
}

void pause_audio()
{
    fallout::audioEnginePause();
}

void resume_audio()
{
    fallout::audioEngineResume();
}

const FalloutEngineAPI g_api = {
    FALLOUT_ENGINE_ABI_VERSION,
    "fallout2",
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
};

} // namespace

extern "C" const FalloutEngineAPI* fallout_engine_api(void)
{
    return &g_api;
}
