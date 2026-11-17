#include "engine_glue.h"

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
