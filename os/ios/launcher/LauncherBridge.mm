#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cmath>

#include "game/combat.h"
#include "game/gmouse.h"
#include "game/intface.h"
#include "launcher/launcher.h"
#include "plib/gnw/kb.h"
#include "plib/gnw/mouse.h"
#include "plib/gnw/svga.h"

// Set by the Swift launcher when the user taps Play. `main` checks it after the
// launcher closes; keeping it false lets the app return without booting the
// engine (currently only reachable if the launcher is dismissed programmatically).
static bool g_should_launch_game = true;

extern "C" void fallout_ios_run_launcher_loop(void)
{
    CFRunLoopRun();
}

extern "C" void fallout_launcher_finish(int launch_game)
{
    g_should_launch_game = launch_game != 0;
    CFRunLoopStop(CFRunLoopGetMain());
}

extern "C" int fallout_ios_should_launch_game(void)
{
    return g_should_launch_game ? 1 : 0;
}

extern "C" void fallout_ios_camera_pan(double x, double y)
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

extern "C" void fallout_ios_camera_stop(void)
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width > 0 && height > 0) {
        fallout::mouse_set_position(width / 2, height / 2);
    }
}

extern "C" void fallout_ios_right_click(void)
{
    fallout::mouse_ios_right_click();
}

extern "C" void fallout_ios_back(void)
{
    fallout::KeyboardData key = {};
    key.key = SDL_SCANCODE_ESCAPE;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

extern "C" void fallout_ios_set_cursor_speed(double value)
{
    fallout::mouse_set_ios_touch_sensitivity(value);
}

extern "C" int fallout_ios_cursor_mode(void)
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

extern "C" void fallout_ios_screen_size(int* width, int* height)
{
    if (width != NULL) {
        *width = fallout::screenGetWidth();
    }
    if (height != NULL) {
        *height = fallout::screenGetHeight();
    }
}

// 0 inventory, 1 map, 2 character, 3 pip-boy, 4 skilldex, 5 end combat,
// 6 skip turn.
extern "C" int fallout_ios_action_available(int action)
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
    default:
        return 1;
    }
}

static void ios_send_scan_code(SDL_Scancode scanCode)
{
    fallout::KeyboardData key = {};
    key.key = scanCode;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

extern "C" void fallout_ios_press_action(int action)
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
    default:
        break;
    }
}
