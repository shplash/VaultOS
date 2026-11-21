#include "engine_glue.h"

#include <SDL.h>

#include <cstdio>
#include <cstring>

namespace {

const FalloutEngineHost* g_host = nullptr;
char g_install_dir[4096] = { 0 };

} // namespace

void fallout_engine_set_install_dir(const char* path)
{
    if (path == nullptr || path[0] == '\0') {
        g_install_dir[0] = '\0';
        return;
    }

    size_t length = std::strlen(path);
    bool needs_slash = path[length - 1] != '/';

    std::snprintf(g_install_dir, sizeof(g_install_dir), "%s%s", path, needs_slash ? "/" : "");
}

const char* fallout_engine_install_dir()
{
    return g_install_dir;
}

void fallout_engine_set_host(const FalloutEngineHost* host)
{
    g_host = host;
}

const FalloutEngineHost* fallout_engine_host()
{
    return g_host;
}

void fallout_engine_install_controls()
{
    if (g_host != nullptr && g_host->install_controls != nullptr) {
        g_host->install_controls();
    }
}

void fallout_engine_menu_music_start()
{
    if (g_host != nullptr && g_host->menu_music_start != nullptr) {
        g_host->menu_music_start();
    }
}

void fallout_engine_menu_music_stop()
{
    if (g_host != nullptr && g_host->menu_music_stop != nullptr) {
        g_host->menu_music_stop();
    }
}

void fallout_engine_refresh_controls(void)
{
    if (g_host == nullptr || g_host->refresh_controls == nullptr) {
        return;
    }

    // The engine reaches this from its input loop, which runs many times a
    // frame in some screens. The overlay only needs a handful of updates a
    // second, and each one is UIKit work, so most calls do nothing. Fifty
    // milliseconds is quick enough that a menu opening is noticed at once.
    static Uint32 lastRefresh = 0;
    Uint32 now = SDL_GetTicks();
    if (lastRefresh != 0 && now - lastRefresh < 50) {
        return;
    }

    lastRefresh = now;
    g_host->refresh_controls();
}

void fallout_engine_refresh_controls_now(void)
{
    if (g_host == nullptr || g_host->refresh_controls == nullptr) {
        return;
    }

    g_host->refresh_controls();
}

void fallout_engine_hide_keyboard(void)
{
    if (g_host == nullptr || g_host->hide_keyboard == nullptr) {
        return;
    }

    g_host->hide_keyboard();
}

int fallout_engine_auto_save_minutes(void)
{
    if (g_host == nullptr || g_host->auto_save_minutes == nullptr) {
        return 0;
    }

    const int minutes = g_host->auto_save_minutes();
    return minutes < 0 ? 0 : minutes;
}
