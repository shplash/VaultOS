#ifndef FALLOUT_IOS_ENGINE_GLUE_H_
#define FALLOUT_IOS_ENGINE_GLUE_H_

// Small helpers shared by the Fallout 1 and Fallout 2 engine adapters. The file
// is compiled once for the engine in the application (Fallout 1) and once for
// the engine in Fallout2Engine.framework (Fallout 2); each image gets its own
// copy, so the two never share install paths or host callbacks.

#include "fallout_engine.h"

// Stores the install directory the launcher selected for this engine.
void fallout_engine_set_install_dir(const char* path);

// The install directory, always with a trailing slash, or an empty string.
const char* fallout_engine_install_dir();

void fallout_engine_set_host(const FalloutEngineHost* host);
const FalloutEngineHost* fallout_engine_host();

// Forwards to the host. Safe to call when no host is attached.
void fallout_engine_install_controls();
void fallout_engine_menu_music_start();
void fallout_engine_menu_music_stop();

// Asks the host to refresh the touch controls, at most a few times a second.
// The engine calls it from its own input loop, which is the only safe place:
// the main thread, between frames, never from a timer interrupting the engine.
void fallout_engine_refresh_controls(void);

// The same refresh without the rate limit. Used at the moment a movie ends:
// the overlay has to drop the skip button before the engine blocks on the
// loading screen that follows, and the last few frames of the movie have
// already used up the limited call.
void fallout_engine_refresh_controls_now(void);

void fallout_engine_hide_keyboard(void);

int fallout_engine_auto_save_minutes(void);
void fallout_engine_auto_save(void);

void fallout_engine_note_mode_request(void);
int fallout_engine_mode_requests(void);

#endif /* FALLOUT_IOS_ENGINE_GLUE_H_ */
