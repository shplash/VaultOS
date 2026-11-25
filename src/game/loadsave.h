#ifndef FALLOUT_GAME_LOADSAVE_H_
#define FALLOUT_GAME_LOADSAVE_H_

#include "game/art.h"
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
int ios_quick_save_auto();
int LoadGame(int mode);

// Real time played, counted once per game loop pass and written beside each
// save as its own playtime, so the launcher can show it.
void loadsave_play_time_tick(void);

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
