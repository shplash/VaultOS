#ifndef FALLOUT_GAME_LOADSAVE_H_
#define FALLOUT_GAME_LOADSAVE_H_

#include "game/art.h"
#include "game/loadsave_slots.h"
#include "game/message.h"
#include "plib/db/db.h"
#include "plib/gnw/rect.h"

namespace fallout {

typedef enum LoadSaveMode {
    // Special case - loading game from main menu.
    LOAD_SAVE_MODE_FROM_MAIN_MENU,

    // Normal (full-screen) save/load screen.
    LOAD_SAVE_MODE_NORMAL,

    // Quick load/save.
    LOAD_SAVE_MODE_QUICK,
} LoadSaveMode;

void InitLoadSave();
void ResetLoadSave();
int SaveGame(int mode);

// QUICK SAVE: the quick slot, written with no screen, so pressing it twice in a
// row writes one save rather than the second landing beside the first.
int ios_quick_save_auto(void);

// The launcher's AUTO SAVE: the auto slot, written with no screen.
int ios_auto_save(void);

// The recovery save written when the app leaves the foreground, once per
// background session. `loadsave_background_return` starts the next session.
int loadsave_save_background(void);
void loadsave_background_return(void);

// A new game has reached the playable world: its three automatic saves are
// written once, a moment later, and never again for that game. A game opened
// from a save keeps the saves it has.
void loadsave_new_game_started(void);

int LoadGame(int mode);

// Real time played, counted once per game loop pass and written beside each
// save as its own playtime, so the launcher can show it.
void loadsave_play_time_tick(void);

// A picture for every save that has none: the picture is inside the save and
// the palette is the game's own, so the saves written before the launcher
// showed any get one without being written again.
void loadsave_preview_all(void);

// The slot the launcher asked to load as the game starts. The request is kept
// until the game asks for it, so both the boot path and the load path can see
// it; |loadsave_take_pending_slot| answers it once and clears it.
void loadsave_request_slot(int slot);
int loadsave_pending_slot(void);
int loadsave_take_pending_slot(void);
int isLoadingGame();
void KillOldMaps();
int MapDirErase(const char* path, const char* a2);
int MapDirEraseFile(const char* a1, const char* a2);

} // namespace fallout

#endif /* FALLOUT_GAME_LOADSAVE_H_ */
