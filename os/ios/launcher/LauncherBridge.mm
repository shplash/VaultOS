#include <CoreFoundation/CoreFoundation.h>

#include "launcher/launcher.h"

// Set by the Swift launcher when the user taps Play. `main` checks it after the
// launcher closes; keeping it false lets the app return without booting the
// engine (currently only reachable if the launcher is dismissed programmatically).
static bool g_should_launch_game = true;

extern "C" void fallout_ios_run_launcher_loop(void)
{
    CFRunLoopRun();
}

extern "C" void fallout_launcher_finish(int launch_game)
{
    g_should_launch_game = launch_game != 0;
    CFRunLoopStop(CFRunLoopGetMain());
}

extern "C" int fallout_ios_should_launch_game(void)
{
    return g_should_launch_game ? 1 : 0;
}
