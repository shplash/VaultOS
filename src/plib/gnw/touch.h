#ifndef FALLOUT_PLIB_GNW_TOUCH_H
#define FALLOUT_PLIB_GNW_TOUCH_H

#include <SDL.h>

namespace fallout {

enum GestureType {
    kUnrecognized,
    kTap,
    kLongPress,
    kPan,
};

enum GestureState {
    kPossible,
    kBegan,
    kChanged,
    kEnded,
};

struct Gesture {
    GestureType type;
    GestureState state;
    int numberOfTouches;
    int x;
    int y;
};

void touch_handle_start(SDL_TouchFingerEvent* event);
void touch_handle_move(SDL_TouchFingerEvent* event);
void touch_handle_end(SDL_TouchFingerEvent* event);
void touch_process_gesture();
bool touch_get_gesture(Gesture* gesture);

// A touch reported the moment it lands, as a pan that began at the point it
// landed on, instead of after the move or hold thresholds below. The menus want
// the finger to be the pointer; the game view wants the trackpad behaviour and
// leaves this off.
void touch_set_immediate_press(bool enabled);

} // namespace fallout

#endif /* FALLOUT_PLIB_GNW_TOUCH_H */
