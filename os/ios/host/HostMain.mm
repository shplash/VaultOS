// The application's SDL entry point.
//
// SDL2main (linked into the app) calls SDL_UIKitRunApp, which sets up the
// UIKit application and calls SDL_main on the main thread. This replaces the
// Fallout 1 engine's own main from winmain.cc: the launcher runs first, then
// the engine selected in the launcher is started - Fallout 1 from this
// executable, Fallout 2 from the embedded framework.
//
// SDL_main is provided here and winmain.cc is not compiled on iOS, so exactly
// one entry point exists in the application.

#include <SDL.h>

#import <Foundation/Foundation.h>

#include <unistd.h>

#include "host/host.h"
#include "launcher/launcher.h"

// Implemented in Swift (LauncherHost.swift). Declared here rather than in the
// Swift bridging header because it is only needed by this entry point.
extern "C" void fallout_ios_present_launcher(void);

extern "C" int SDL_main(int argc, char** argv)
{
    SDL_SetHint(SDL_HINT_MOUSE_TOUCH_EVENTS, "0");
    SDL_SetHint(SDL_HINT_TOUCH_MOUSE_EVENTS, "0");

    @autoreleasepool {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if ([paths count] > 0) {
            chdir([[paths objectAtIndex:0] fileSystemRepresentation]);
        }

        // Blocks until the player taps Play, then hides the launcher window.
        fallout_ios_present_launcher();

        if (!fallout_ios_should_launch_game()) {
            return 0;
        }

        return fallout_ios_launch_selected_engine(argc, argv);
    }
}

