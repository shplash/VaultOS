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
} IosScreen;

extern int ios_screen;

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
