// Global state normally defined by src/win32.cc, which also contains that
// engine's process entry point. The framework provides the global so the rest
// of Fallout 2 CE links without the executable main.

#include "win32.h"

namespace fallout {

bool gProgramIsActive = false;

} // namespace fallout
