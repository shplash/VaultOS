#ifndef FALLOUT_ENGINE_IOS_SAVES_H_
#define FALLOUT_ENGINE_IOS_SAVES_H_

// What the launcher asks of Fallout 2's saves.
//
// Upstream's own loadsave header is left as it is, so the entry points the
// launcher needs live here instead, in the engine's own namespace: both the
// engine adapter and the Fallout 2 main override see them, and neither has to
// change an upstream header to do it.

namespace fallout {

// The slot the launcher asked to open as the game starts, numbered as the
// launcher numbers it: one is the first slot. The request is kept until the
// game asks for it, so both the boot path and the load path can see it;
// |loadsave_take_pending_slot| answers it once, from zero, and clears it.
void loadsave_request_slot(int slot);
int loadsave_pending_slot(void);
int loadsave_take_pending_slot(void);

// A picture for every save that has none: the picture is inside the save and
// the palette is the game's own, so the saves written before the launcher
// showed any get one without being written again.
void loadsave_preview_all(void);

// Real time played, counted once per game loop pass and written beside each
// save as its own playtime, so the launcher can show it.
void loadsave_play_time_tick(void);

} // namespace fallout

#endif /* FALLOUT_ENGINE_IOS_SAVES_H_ */
