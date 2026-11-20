#ifndef FALLOUT_GAME_IOS_SCREEN_H_
#define FALLOUT_GAME_IOS_SCREEN_H_

namespace fallout {

typedef enum IosScreen {
    IOS_SCREEN_GAME = 0,
    IOS_SCREEN_INVENTORY = 1,
    IOS_SCREEN_LOOT = 2,
    IOS_SCREEN_BARTER = 3,
    IOS_SCREEN_DIALOGUE = 4,
    IOS_SCREEN_CHARACTER = 5,
    IOS_SCREEN_PIPBOY = 6,
    IOS_SCREEN_SKILLDEX = 7,
    IOS_SCREEN_AUTOMAP = 8,
    IOS_SCREEN_WORLDMAP = 9,
    IOS_SCREEN_OPTIONS = 10,
    IOS_SCREEN_SAVES = 11,
    // The panel that picks the item to use something on. It is drawn like the
    // inventory but has a cursor of its own, so it keeps the trackpad.
    IOS_SCREEN_USE_ON = 12,
    IOS_SCREEN_PICK_AMOUNT = 13,
} IosScreen;

extern int ios_screen;

// Set by the INSPECT button. On the item screens it turns a touch into a click
// on the item instead of a drag, which is the path that shows its description.
extern bool ios_inspect;

class IosScreenScope {
public:
    explicit IosScreenScope(int screen)
        : previous_(ios_screen)
    {
        ios_screen = screen;
    }

    ~IosScreenScope()
    {
        ios_screen = previous_;
    }

private:
    int previous_;
};

} // namespace fallout

#endif /* FALLOUT_GAME_IOS_SCREEN_H_ */
