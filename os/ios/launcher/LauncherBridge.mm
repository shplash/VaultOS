#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cmath>

#include "game/combat.h"
#include "game/gmouse.h"
#include "game/intface.h"
#include "launcher/launcher.h"
#include "plib/gnw/kb.h"
#include "plib/gnw/mouse.h"
#include "plib/gnw/svga.h"

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

extern "C" void fallout_ios_camera_pan(double x, double y)
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width <= 1 || height <= 1) {
        return;
    }

    // The engine scrolls only when the cursor touches a screen edge, so turn
    // the joystick into a directional edge target instead of a free cursor.
    const double deadzone = 0.30;
    const int dx = x < -deadzone ? -1 : (x > deadzone ? 1 : 0);
    const int dy = y < -deadzone ? -1 : (y > deadzone ? 1 : 0);

    int targetX = width / 2;
    int targetY = height / 2;
    if (dx < 0) {
        targetX = 0;
    } else if (dx > 0) {
        targetX = width - 1;
    }
    if (dy < 0) {
        targetY = 0;
    } else if (dy > 0) {
        targetY = height - 1;
    }

    fallout::mouse_set_position(targetX, targetY);
}

extern "C" void fallout_ios_camera_stop(void)
{
    const int width = fallout::screenGetWidth();
    const int height = fallout::screenGetHeight();
    if (width > 0 && height > 0) {
        fallout::mouse_set_position(width / 2, height / 2);
    }
}

extern "C" void fallout_ios_right_click(void)
{
    fallout::mouse_ios_right_click();
}

extern "C" void fallout_ios_back(void)
{
    fallout::KeyboardData key = {};
    key.key = SDL_SCANCODE_ESCAPE;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

extern "C" void fallout_ios_set_cursor_speed(double value)
{
    fallout::mouse_set_ios_touch_sensitivity(value);
}

extern "C" int fallout_ios_cursor_mode(void)
{
    const int mode = fallout::gmouse_3d_get_mode();
    if (mode == fallout::GAME_MOUSE_MODE_MOVE) {
        return 0;
    }
    if (mode == fallout::GAME_MOUSE_MODE_CROSSHAIR) {
        return 2;
    }
    return 1;
}

extern "C" void fallout_ios_screen_size(int* width, int* height)
{
    if (width != NULL) {
        *width = fallout::screenGetWidth();
    }
    if (height != NULL) {
        *height = fallout::screenGetHeight();
    }
}

// 0 inventory, 1 map, 2 character, 3 pip-boy, 4 skilldex, 5 end combat,
// 6 skip turn.
extern "C" int fallout_ios_action_available(int action)
{
    if (!fallout::intface_is_enabled()) {
        return 0;
    }

    switch (action) {
    case 3:
        return fallout::isInCombat() ? 0 : 1;
    case 5:
        return fallout::isInCombat() ? 1 : 0;
    case 6:
        return fallout::combat_can_skip_turn() ? 1 : 0;
    default:
        return 1;
    }
}

static void ios_send_scan_code(SDL_Scancode scanCode)
{
    fallout::KeyboardData key = {};
    key.key = scanCode;
    key.down = 1;
    fallout::kb_simulate_key(&key);
    key.down = 0;
    fallout::kb_simulate_key(&key);
}

extern "C" void fallout_ios_press_action(int action)
{
    switch (action) {
    case 0:
        ios_send_scan_code(SDL_SCANCODE_I);
        break;
    case 1:
        ios_send_scan_code(SDL_SCANCODE_TAB);
        break;
    case 2:
        ios_send_scan_code(SDL_SCANCODE_C);
        break;
    case 3:
        ios_send_scan_code(SDL_SCANCODE_P);
        break;
    case 4:
        ios_send_scan_code(SDL_SCANCODE_S);
        break;
    case 5:
        ios_send_scan_code(SDL_SCANCODE_RETURN);
        break;
    case 6:
        ios_send_scan_code(SDL_SCANCODE_SPACE);
        break;
    default:
        break;
    }
}

// MARK: - Launcher music decoding

#include "launcher/launcher.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "adecode/adecode.h"

namespace fs = std::filesystem;

namespace {

std::string lower_ascii(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string find_child(const fs::path& directory, const std::string& wanted, bool want_directory)
{
    std::error_code ec;
    fs::directory_iterator iterator(directory, ec);
    if (ec) {
        return "";
    }

    const std::string wanted_lower = lower_ascii(wanted);
    for (const fs::directory_entry& entry : iterator) {
        std::string name = entry.path().filename().string();
        if (lower_ascii(name) != wanted_lower) {
            continue;
        }

        std::error_code type_ec;
        if (entry.is_directory(type_ec) == want_directory) {
            return name;
        }
    }

    return "";
}

fs::path find_music_directory(const fs::path& install_directory)
{
    const std::string data = find_child(install_directory, "data", true);
    if (!data.empty()) {
        const fs::path data_path = install_directory / data;
        const std::string sound = find_child(data_path, "sound", true);
        if (!sound.empty()) {
            const std::string music = find_child(data_path / sound, "music", true);
            if (!music.empty()) {
                return data_path / sound / music;
            }
        }
    }

    const std::string sound = find_child(install_directory, "sound", true);
    if (!sound.empty()) {
        const fs::path sound_path = install_directory / sound;
        const std::string music = find_child(sound_path, "music", true);
        if (!music.empty()) {
            return sound_path / music;
        }
    }

    return {};
}

unsigned int read_acm(void* data, void* buffer, unsigned int size)
{
    std::ifstream* stream = static_cast<std::ifstream*>(data);
    stream->read(static_cast<char*>(buffer), static_cast<std::streamsize>(size));
    return static_cast<unsigned int>(stream->gcount());
}

void write_u32(std::ofstream& stream, uint32_t value)
{
    char bytes[4] = {
        static_cast<char>(value & 0xFF),
        static_cast<char>((value >> 8) & 0xFF),
        static_cast<char>((value >> 16) & 0xFF),
        static_cast<char>((value >> 24) & 0xFF),
    };
    stream.write(bytes, sizeof(bytes));
}

bool write_wav(const fs::path& path, const std::vector<int16_t>& samples, int channels, int rate)
{
    if (channels <= 0 || rate <= 0 || samples.empty()) {
        return false;
    }

    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    if (!stream) {
        return false;
    }

    const uint32_t data_size = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
    const uint32_t byte_rate = static_cast<uint32_t>(rate * channels * sizeof(int16_t));
    const uint16_t block_align = static_cast<uint16_t>(channels * sizeof(int16_t));

    stream.write("RIFF", 4);
    write_u32(stream, 36 + data_size);
    stream.write("WAVEfmt ", 8);
    write_u32(stream, 16);
    stream.write("\x01\x00", 2); // PCM
    stream.write(reinterpret_cast<const char*>(&channels), 2);
    write_u32(stream, static_cast<uint32_t>(rate));
    write_u32(stream, byte_rate);
    stream.write(reinterpret_cast<const char*>(&block_align), 2);
    stream.write("\x10\x00", 2); // 16-bit samples
    stream.write("data", 4);
    write_u32(stream, data_size);
    stream.write(reinterpret_cast<const char*>(samples.data()), data_size);
    return stream.good();
}

} // namespace

extern "C" int launcher_prepare_music(const char* install_dir, const char* output_path)
{
    if (install_dir == NULL || install_dir[0] == '\0' || output_path == NULL || output_path[0] == '\0') {
        return LAUNCHER_ERROR;
    }

    const fs::path music_directory = find_music_directory(fs::path(install_dir));
    if (music_directory.empty()) {
        return LAUNCHER_ERROR;
    }

    const std::string name = find_child(music_directory, "07desert.acm", false);
    if (name.empty()) {
        return LAUNCHER_ERROR;
    }

    std::ifstream source(music_directory / name, std::ios::binary);
    if (!source) {
        return LAUNCHER_ERROR;
    }

    int channels = 0;
    int rate = 0;
    int sample_count = 0;
    AudioDecoder* decoder = Create_AudioDecoder(read_acm, &source, &channels, &rate, &sample_count);
    if (decoder == NULL) {
        return LAUNCHER_ERROR;
    }

    std::vector<int16_t> samples;
    if (sample_count > 0) {
        samples.reserve(static_cast<size_t>(sample_count) * static_cast<size_t>(std::max(channels, 1)));
    }

    int16_t buffer[4096];
    while (true) {
        const unsigned int read = AudioDecoder_Read(decoder, buffer, sizeof(buffer));
        if (read == 0) {
            break;
        }
        samples.insert(samples.end(), buffer, buffer + read / sizeof(int16_t));
    }

    AudioDecoder_Close(decoder);

    if (!write_wav(fs::path(output_path), samples, channels, rate)) {
        std::remove(output_path);
        return LAUNCHER_ERROR;
    }

    return LAUNCHER_OK;
}
