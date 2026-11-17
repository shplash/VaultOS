// Launcher side of the dual-engine app.
//
// The application executable owns the launcher UI, the installation core, the
// in-game overlay and the Fallout 1 engine. Fallout 2 lives in
// Fallout2Engine.framework and is loaded with dlopen only when the player picks
// Fallout 2, so the two codebases never become one image and never share engine
// globals. Only one engine is started per process; switching games restarts the
// application, which keeps a running engine from having to unwind itself.
//
// The application's SDL is the only SDL in the process: the framework resolves
// its SDL symbols from the executable (see CMakeLists.txt), so the launcher's
// UIKit setup, event pump and video subsystem are reused by whichever engine
// starts.

#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <dlfcn.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

#include "fallout_engine.h"
#include "host/host.h"
#include "launcher/launcher.h"

// Set by the Swift launcher when the user taps Play. `SDL_main` checks it after
// the launcher closes; keeping it false lets the app return without booting an
// engine.
static bool g_should_launch_game = true;

// The engine selected for this run. Null until Play is tapped.
static const FalloutEngineAPI* g_engine = NULL;

// MARK: - Launcher run loop

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

// MARK: - Host callbacks handed to the engine

static void host_install_controls(void)
{
    fallout_ios_install_game_controls();
}

static void host_menu_music_start(void)
{
    fallout_ios_menu_music_start();
}

static void host_menu_music_stop(void)
{
    fallout_ios_menu_music_stop();
}

static const FalloutEngineHost g_host = {
    FALLOUT_ENGINE_ABI_VERSION,
    host_install_controls,
    host_menu_music_start,
    host_menu_music_stop,
};

// MARK: - Engine loading

static NSString* documentsDirectory(void)
{
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths count] > 0 ? [paths objectAtIndex:0] : NSTemporaryDirectory();
}

// Fallout 1 keeps the Documents folder it has always used, so existing
// installations and saves stay where they are. Fallout 2 gets its own folder,
// which gives it a separate working directory, configuration, install data and
// SAVEGAME.
static NSString* installDirectoryForGame(NSString* identifier)
{
    NSString* documents = documentsDirectory();
    if ([identifier isEqualToString:@"fallout2"]) {
        return [documents stringByAppendingPathComponent:@"Fallout2"];
    }
    return documents;
}

static NSString* fallout2FrameworkPath(void)
{
    NSString* frameworks = [[NSBundle mainBundle] privateFrameworksPath];
    return [frameworks stringByAppendingPathComponent:@"Fallout2Engine.framework/Fallout2Engine"];
}

// Fallout 1 is part of this executable. Fallout 2 is loaded from the app
// bundle; RTLD_LOCAL keeps its symbols out of the global namespace.
static const FalloutEngineAPI* load_engine(NSString* identifier, NSString** failure)
{
    if ([identifier isEqualToString:@"fallout1"]) {
        const FalloutEngineAPI* engine = fallout_engine_api();
        if (engine == NULL) {
            *failure = @"The Fallout engine is missing from this build.";
            return NULL;
        }
        return engine;
    }

    NSString* path = fallout2FrameworkPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"Fallout 2 engine not found at %@", path);
        *failure = @"This build does not contain the Fallout 2 engine.";
        return NULL;
    }

    void* handle = dlopen([path fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char* error = dlerror();
        NSString* reason = error != NULL ? [NSString stringWithUTF8String:error] : @"unknown error";
        NSLog(@"Cannot load %@: %@", path, reason);
        *failure = [NSString stringWithFormat:@"The Fallout 2 engine could not be loaded: %@", reason];
        return NULL;
    }

    typedef const FalloutEngineAPI* (*EngineApiFunction)(void);
    EngineApiFunction getApi = (EngineApiFunction)dlsym(handle, "fallout_engine_api");
    if (getApi == NULL) {
        const char* error = dlerror();
        NSString* reason = error != NULL ? [NSString stringWithUTF8String:error] : @"unknown error";
        NSLog(@"%@ does not export fallout_engine_api: %@", path, reason);
        *failure = @"The Fallout 2 engine in this build is not usable.";
        return NULL;
    }

    return getApi();
}

// Shows a blocking alert when no engine can be started. The launcher window is
// already gone at this point, so without this the app would sit on a black
// screen with only a log message.
static void present_engine_failure(NSString* message)
{
    if (![NSThread isMainThread]) {
        return;
    }

    UIWindow* window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.windowLevel = UIWindowLevelAlert + 1;

    UIViewController* controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor blackColor];
    window.rootViewController = controller;
    [window makeKeyAndVisible];

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Cannot start the game"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                                [window setHidden:YES];
                                                CFRunLoopStop(CFRunLoopGetMain());
                                            }]];
    [controller presentViewController:alert animated:NO completion:nil];

    // The launch path runs on the main thread inside SDL's run loop; run it
    // until the alert is dismissed.
    CFRunLoopRun();

    exit(EXIT_FAILURE);
}

int fallout_ios_launch_selected_engine(int argc, char** argv)
{
    NSString* identifier = [[NSUserDefaults standardUserDefaults] stringForKey:@"launcher.game"];
    if (![identifier isEqualToString:@"fallout2"]) {
        identifier = @"fallout1";
    }

    NSString* failure = nil;
    const FalloutEngineAPI* engine = load_engine(identifier, &failure);
    if (engine == NULL
        || engine->abi_version != FALLOUT_ENGINE_ABI_VERSION
        || engine->identifier == NULL
        || engine->run == NULL
        || engine->set_install_dir == NULL
        || engine->set_host == NULL
        || strcmp(engine->identifier, [identifier UTF8String]) != 0) {
        NSLog(@"The %@ engine does not match the launcher's engine ABI", identifier);
        present_engine_failure(failure != nil
                ? failure
                : @"The selected engine does not match this launcher version.");
        return 1;
    }

    g_engine = engine;

    NSString* installDirectory = installDirectoryForGame(identifier);
    [[NSFileManager defaultManager] createDirectoryAtPath:installDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    engine->set_host(&g_host);
    engine->set_install_dir([installDirectory fileSystemRepresentation]);

    // The overlay lives in its own window above the engine's SDL window, so it
    // can be created before the engine starts and does not depend on the
    // engine's window hierarchy. Installing it again from the engine (as the
    // Fallout 1 adapter does) is a no-op.
    host_install_controls();

    return engine->run(argc, argv);
}

// MARK: - In-game controls

// These are called by the Swift overlay. They forward to the loaded engine and
// stay harmless before the engine starts.

extern "C" void fallout_ios_camera_pan(double x, double y)
{
    if (g_engine != NULL && g_engine->camera_pan != NULL) {
        g_engine->camera_pan(x, y);
    }
}

extern "C" void fallout_ios_camera_stop(void)
{
    if (g_engine != NULL && g_engine->camera_stop != NULL) {
        g_engine->camera_stop();
    }
}

extern "C" void fallout_ios_right_click(void)
{
    if (g_engine != NULL && g_engine->right_click != NULL) {
        g_engine->right_click();
    }
}

extern "C" void fallout_ios_back(void)
{
    if (g_engine != NULL && g_engine->back != NULL) {
        g_engine->back();
    }
}

extern "C" void fallout_ios_set_cursor_speed(double value)
{
    if (g_engine != NULL && g_engine->set_cursor_speed != NULL) {
        g_engine->set_cursor_speed(value);
    }
}

extern "C" int fallout_ios_cursor_mode(void)
{
    return g_engine != NULL && g_engine->cursor_mode != NULL
        ? g_engine->cursor_mode()
        : 0;
}

extern "C" void fallout_ios_screen_size(int* width, int* height)
{
    if (g_engine != NULL && g_engine->screen_size != NULL) {
        g_engine->screen_size(width, height);
        return;
    }
    if (width != NULL) {
        *width = 0;
    }
    if (height != NULL) {
        *height = 0;
    }
}

// 0 inventory, 1 map, 2 character, 3 pip-boy, 4 skilldex, 5 end combat,
// 6 skip turn, 7 swap the active hand/weapon, 8 reload, 9 fire mode.
extern "C" int fallout_ios_action_available(int action)
{
    return g_engine != NULL && g_engine->action_available != NULL
        ? g_engine->action_available(action)
        : 0;
}

extern "C" void fallout_ios_press_action(int action)
{
    if (g_engine != NULL && g_engine->press_action != NULL) {
        g_engine->press_action(action);
    }
}

extern "C" int fallout_ios_fire_mode(void)
{
    return g_engine != NULL && g_engine->fire_mode != NULL
        ? g_engine->fire_mode()
        : -1;
}

// Pause the game's SDL audio stream when the app leaves the foreground. SDL's
// device is shared by music and sound effects, so this silences both without
// closing the device or losing playback positions.
extern "C" void fallout_ios_pause_game_audio(void)
{
    if (g_engine != NULL && g_engine->pause_audio != NULL) {
        g_engine->pause_audio();
    }
}

extern "C" void fallout_ios_resume_game_audio(void)
{
    if (g_engine != NULL && g_engine->resume_audio != NULL) {
        g_engine->resume_audio();
    }
}
