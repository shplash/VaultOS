#ifndef FALLOUT_GAME_LOADSAVE_SLOTS_H_
#define FALLOUT_GAME_LOADSAVE_SLOTS_H_

// The launcher's saves and the player's saves share the ten save slots the game
// has always written, and the first three belong to the launcher:
//
//   1. QUICK SAVE is written only when the player presses Quick Save.
//   2. AUTO SAVE is written by the launcher's timer.
//   3. BACKGROUND SAVE is written when the app leaves the foreground.
//
// None of the three is written by another, and the save window never reaches
// them: a manual save always writes one of the player's own slots.

enum {
    LOADSAVE_SLOT_QUICK = 0,
    LOADSAVE_SLOT_AUTO = 1,
    LOADSAVE_SLOT_BACKGROUND = 2,
    LOADSAVE_SLOT_MANUAL_FIRST = 3,
    LOADSAVE_SLOT_COUNT = 10,
};

// The name an automatic slot is written under, or nullptr for a manual slot.
static inline const char* loadsave_slot_name(int slot)
{
    switch (slot) {
    case LOADSAVE_SLOT_QUICK:
        return "Quick Save";
    case LOADSAVE_SLOT_AUTO:
        return "Auto Save";
    case LOADSAVE_SLOT_BACKGROUND:
        return "Background Save";
    default:
        return nullptr;
    }
}

// Whether a manual save may write this slot.
static inline bool loadsave_slot_is_manual(int slot)
{
    return slot >= LOADSAVE_SLOT_MANUAL_FIRST && slot < LOADSAVE_SLOT_COUNT;
}

// The slot a manual save lands on: the save window's own, and never one of the
// three automatic ones.
static inline int loadsave_manual_slot(int slot)
{
    if (slot < LOADSAVE_SLOT_MANUAL_FIRST) {
        return LOADSAVE_SLOT_MANUAL_FIRST;
    }
    if (slot >= LOADSAVE_SLOT_COUNT) {
        return LOADSAVE_SLOT_COUNT - 1;
    }
    return slot;
}

#endif /* FALLOUT_GAME_LOADSAVE_SLOTS_H_ */
