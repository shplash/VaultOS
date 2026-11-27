// Replaces each engine's own platform/ios/paths.mm, which returns the app's
// Documents directory: right for one game, but the launcher keeps an installation
// per game, so the host provides that directory instead.

#include "engine_glue.h"

// Both engines declare this in src/platform/ios/paths.h with C++ linkage.
// Providing it keeps the engines self-contained.
const char* iOSGetDocumentsPath()
{
    return fallout_engine_install_dir();
}
