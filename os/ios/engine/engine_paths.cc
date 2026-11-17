// Replaces each engine's own platform/ios/paths.mm.
//
// The upstream implementations return the app's Documents directory, which is
// correct for a single-game app. The launcher now keeps one installation per
// game, so the directory is provided by the host instead. Returning the
// selected installation keeps configuration, saves and data separate without
// patching the engine's own path handling.

#include "engine_glue.h"

// Both engines declare this in src/platform/ios/paths.h with C++ linkage.
// Only their standalone win32 entry points (not compiled here) call it, but
// providing it keeps the engines self-contained.
const char* iOSGetDocumentsPath()
{
    return fallout_engine_install_dir();
}
