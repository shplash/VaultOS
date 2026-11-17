// Global state normally defined by src/plib/gnw/winmain.cc. That file also
// contains the process entry point, which belongs to the launcher application
// now, so the framework provides the globals the rest of the engine expects.

#include "plib/gnw/winmain.h"

namespace fallout {

bool GNW95_isActive = false;
char GNW95_title[256];

} // namespace fallout
