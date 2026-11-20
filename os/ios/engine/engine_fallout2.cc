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
#include "debug.h"
#include "engine_glue.h"
#include "fallout_engine.h"
#include "game.h"
#include "game_movie.h"
#include "game_mouse.h"
#include "interface.h"
#include "item.h"
#include "loadsave.h"
#include "main.h"
#include "map.h"
#include "mouse.h"
#include "movie.h"
#include "object.h"
#include "proto_types.h"
#include "svga.h"
#include "win32.h"
#include "window_manager.h"

namespace fallout {
extern int gMovieCurrent;
extern bool iosInspect;
void mouseIosClick(int state);
}

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

    // Fallout 2's own log, beside its game files, so a crash or a failed start
    // leaves a trail the player can read - the same file Fallout 1 writes.
    fallout::_debug_register_log("vaultos-log.txt", "wt");

    atexit(SDL_Quit);

    SDL_ShowCursor(SDL_DISABLE);

    // Fallout 2 draws leather side panels beside the interface bar whenever the
    // bar is narrower than the screen. A panel image id of zero makes
    // sidePanelsInit skip them, so the gaps stay the game's own black, the way
    // Fallout 1 looks. The bar itself is untouched, so every HUD button keeps
    // its position and the on-screen controls stay aligned with it.
    fallout::gInterfaceSidePanelsImageId = 0;

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

// Reload and fire mode only make sense with a weapon in hand; reloading also
// needs a weapon that takes ammunition (melee weapons have no ammo capacity).
// The interface seeds both hands with (Object*)-1 until its first
// interfaceUpdateItems call. That sentinel is not a valid object, so it must
// never be dereferenced by the touch controls (which poll while the HUD is
// still initializing).
fallout::Object* active_item()
{
    fallout::Object* item = nullptr;
    if (fallout::interfaceGetActiveItem(&item) != 0) {
        return nullptr;
    }

    if (item == nullptr || item == reinterpret_cast<fallout::Object*>(-1)) {
        return nullptr;
    }

    return item;
}

int has_weapon_in_hand()
{
    fallout::Object* item = active_item();
    if (item == nullptr) {
        return 0;
    }

    return fallout::itemGetType(item) == fallout::ITEM_TYPE_WEAPON ? 1 : 0;
}

int has_firearm_in_hand()
{
    fallout::Object* item = active_item();
    if (item == nullptr) {
        return 0;
    }

    return fallout::itemGetType(item) == fallout::ITEM_TYPE_WEAPON
            && fallout::ammoGetCapacity(item) > 0
        ? 1
        : 0;
}

// 0 is HAND_LEFT, 1 is HAND_RIGHT in the engine.
int active_item_action()
{
    int left = -1;
    int right = -1;
    if (fallout::interfaceGetItemActions(&left, &right) != 0) {
        return -1;
    }

    return fallout::interfaceGetCurrentHand() == 0 ? left : right;
}

int fire_mode()
{
    return active_item_action();
}

int in_game()
{
    if (fallout::_moviePlaying()) {
        return 0;
    }

    if (fallout::gDude == nullptr) {
        return 0;
    }

    if (fallout::isInCombat()) {
        return 1;
    }

    fallout::Window* window = fallout::windowGetWindow(fallout::gIsoWindow);
    if (window == nullptr || (window->flags & fallout::WINDOW_HIDDEN) != 0) {
        return 0;
    }

    return fallout::interfaceBarEnabled() ? 1 : 0;
}

int movie_state()
{
    const int movie = fallout::gMovieCurrent;
    if (movie < 0) {
        return 0;
    }

    if (movie == fallout::MOVIE_IPLOGO
        || movie == fallout::MOVIE_INTRO
        || movie == fallout::MOVIE_CREDITS) {
        return 1;
    }

    return 2;
}

int screen()
{
    const int mode = fallout::GameMode::getCurrentGameMode();

    if ((mode & fallout::GameMode::kCounter) != 0) {
        return 13;
    }

    if ((mode & fallout::GameMode::kLoot) != 0) {
        return 2;
    }

    if ((mode & fallout::GameMode::kBarter) != 0) {
        return 3;
    }

    if ((mode & fallout::GameMode::kDialog) != 0) {
        return 4;
    }

    // The dialogue review screen is a dialogue screen, and the character editor
    // and the character sheet are both the character screen - the editor is a
    // page of it, not a separate mode.
    if ((mode & fallout::GameMode::kDialogReview) != 0) {
        return 4;
    }

    if ((mode & fallout::GameMode::kEditor) != 0) {
        return 5;
    }

    if ((mode & fallout::GameMode::kInventory) != 0) {
        return 1;
    }

    if ((mode & fallout::GameMode::kUseOn) != 0) {
        return 12;
    }

    if ((mode & fallout::GameMode::kPipboy) != 0) {
        return 6;
    }

    if ((mode & fallout::GameMode::kSkilldex) != 0) {
        return 7;
    }

    if ((mode & fallout::GameMode::kAutomap) != 0) {
        return 8;
    }

    if ((mode & fallout::GameMode::kWorldmap) != 0) {
        return 9;
    }

    if ((mode & fallout::GameMode::kSaveGame) != 0
        || (mode & fallout::GameMode::kLoadGame) != 0) {
        return 11;
    }

    if ((mode & fallout::GameMode::kOptions) != 0
        || (mode & fallout::GameMode::kPreferences) != 0
        || (mode & fallout::GameMode::kHelp) != 0) {
        return 10;
    }

    if ((mode & fallout::GameMode::kHero) != 0) {
        return 5;
    }

    return 0;
}

// In Fallout 2 reloading is one of the attack modes cycled with N. Walk to the
// RELOAD mode and use the active item so the game applies its own AP cost,
// animation and sound.
void reload_active_weapon()
{
    fallout::Object* item = active_item();
    if (item == nullptr) {
        return;
    }

    const int capacity = fallout::ammoGetCapacity(item);
    if (capacity <= 0 || fallout::ammoGetQuantity(item) >= capacity) {
        return;
    }

    int action = active_item_action();
    for (int attempt = 0; attempt < fallout::INTERFACE_ITEM_ACTION_COUNT; attempt++) {
        if (action == fallout::INTERFACE_ITEM_ACTION_RELOAD) {
            fallout::_intface_use_item();
            return;
        }

        fallout::interfaceCycleItemAction();
        action = active_item_action();
    }
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
        // Reload: a firearm is in hand.
        return has_firearm_in_hand();
    case 9:
        // Fire mode: any weapon has attack modes to cycle.
        return has_weapon_in_hand();
    case 20:
        return screen() == 4 ? 1 : 0;
    case 21:
        return screen() == 4 ? 0 : 1;
    case 22:
        return 0;
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
        // The map is the TAB key, the shortcut the interface bar's own map
        // button uses. M cycles the mouse mode (move/action/target) instead.
        send_key(SDL_SCANCODE_TAB);
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
        reload_active_weapon();
        break;
    case 9:
        // N cycles the attack/fire mode in Fallout 2.
        send_key(SDL_SCANCODE_N);
        break;
    case 10:
        // SAVES: F4 is the save screen, the key the game's own key handler
        // binds to lsgSaveGame(1).
        send_key(SDL_SCANCODE_F4);
        break;
    case 11:
        send_key(SDL_SCANCODE_F5);
        break;
    case 12:
        fallout::gameMouseSetCursor(fallout::MOUSE_CURSOR_CROSSHAIR);
        fallout::gameMouseSetMode(fallout::GAME_MOUSE_MODE_CROSSHAIR);
        break;
    case 13:
        fallout::gameMouseSetCursor(fallout::MOUSE_CURSOR_ARROW);
        fallout::gameMouseSetMode(fallout::GAME_MOUSE_MODE_MOVE);
        break;
    case 14:
        fallout::mouseIosClick(MOUSE_STATE_LEFT_BUTTON_DOWN);
        break;
    case 16:
        fallout::mouseIosClick(MOUSE_STATE_RIGHT_BUTTON_DOWN);
        break;
    case 17:
        // INSPECT switched on: an item screen takes a touch as a click.
        fallout::iosInspect = true;
        break;
    case 18:
        fallout::iosInspect = false;
        break;
    case 19:
        // QUICK SAVE: the engine's own quick save into its own quick slot.
        send_key(SDL_SCANCODE_F6);
        break;
    case 20:
        send_key(SDL_SCANCODE_B);
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

// A right click is what cycles move/action/target in the game view. The
// engine's own handler for it is gameMouseCycleMode; injecting SDL button
// events does not reach the game's mouse state, so call the cycle directly.
void right_click()
{
    fallout::gameMouseCycleMode();
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

// The engine's own quick save, into its own quick slot. The return value is the
// game's: 1 saved, 0 nothing to save, -1 failed.
int quick_save()
{
    return fallout::lsgSaveGame(fallout::LOAD_SAVE_MODE_QUICK);
}

// The window of the menu the player is looking at, in game pixels. Fallout 2
// will not hand out its window list, so ask its manager which window is under a
// few points inside the game view and take the first that is not the game view
// itself. The points start in the middle and cover the lower half, the upper
// half and both sides, so a panel that sits off centre - the barter table and
// the dialogue reply are both in the bottom half - is found as well.
int menu_rect(int* x, int* y, int* width, int* height)
{
    if (screen() == 0) {
        return 0;
    }

    const int screenWidth = fallout::screenGetWidth();
    const int screenHeight = fallout::screenGetHeight();
    if (screenWidth < 8 || screenHeight < 8) {
        return 0;
    }

    const int probes[7][2] = {
        { screenWidth / 2, screenHeight / 2 },
        { screenWidth / 2, (screenHeight * 3) / 4 },
        { screenWidth / 2, screenHeight / 4 },
        { screenWidth / 4, (screenHeight * 3) / 4 },
        { (screenWidth * 3) / 4, (screenHeight * 3) / 4 },
        { screenWidth / 4, screenHeight / 2 },
        { (screenWidth * 3) / 4, screenHeight / 2 },
    };

    for (int index = 0; index < 7; index++) {
        const int id = fallout::windowGetAtPoint(probes[index][0], probes[index][1]);
        if (id < 0 || id == fallout::gIsoWindow) {
            continue;
        }

        fallout::Window* window = fallout::windowGetWindow(id);
        if (window == nullptr) {
            continue;
        }
        if ((window->flags & fallout::WINDOW_HIDDEN) != 0) {
            continue;
        }
        if (window->width < 8 || window->height < 8) {
            continue;
        }

        if (x != NULL) *x = window->rect.left;
        if (y != NULL) *y = window->rect.top;
        if (width != NULL) *width = window->width;
        if (height != NULL) *height = window->height;
        return 1;
    }

    return 0;
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
    fire_mode,
    in_game,
    movie_state,
    screen,
    quick_save,
    menu_rect,
};

} // namespace

namespace fallout {

bool iosItemScreen()
{
    const int current = screen();
    return current == 1 || current == 2 || current == 3;
}

// Only the screens that are grids of items take the finger as the pointer;
// everything else keeps the engine's trackpad behaviour.
bool iosDirectTouchScreen()
{
    const int current = screen();
    return current == 1 || current == 2 || current == 3 || current == 7;
}

// Every screen except the game view is a mouse UI: grids, lists and buttons,
// where the finger is expected to be the pointer.
bool iosMenuScreen()
{
    return screen() != 0;
}

} // namespace fallout

extern "C" const FalloutEngineAPI* fallout_engine_api(void)
{
    return &g_api;
}
