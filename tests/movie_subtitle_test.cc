// The subtitle row is drawn into the window the movie fills, so it has to stay
// inside it: a row reaching past the window wrote over what follows the surface,
// which is what stopped the intro at a large resolution. The sizes below are the
// ones the launcher can hand the games, the largest iPad at FULL included.

#include <cstdio>

#include "int/movie_subtitles.h"

using fallout::MovieSubtitleRect;
using fallout::movieSubtitleRect;

static int failures;

static void check(bool condition, const char* what, int width, int height, int lineHeight)
{
    if (!condition) {
        std::printf("FAIL at %dx%d with a %d line: %s\n", width, height, lineHeight, what);
        failures++;
    }
}

static void checkWindow(int width, int height, int lineHeight)
{
    const MovieSubtitleRect row = movieSubtitleRect(width, height, lineHeight);

    check(row.x >= 0, "the row starts inside the window", width, height, lineHeight);
    check(row.y >= 0, "the row starts inside the window", width, height, lineHeight);
    check(row.width >= 0 && row.x + row.width <= width, "the row fits the window's width", width, height, lineHeight);
    check(row.height >= 0 && row.y + row.height <= height, "the row fits the window's height", width, height, lineHeight);

    if (height >= lineHeight + 4) {
        check(row.height == lineHeight + 4, "the row is one line and its padding", width, height, lineHeight);
        check(row.y == height - row.height, "the row sits on the window's bottom edge", width, height, lineHeight);
    }
}

int main()
{
    // The engine's own floor, a phone at HALF and at FULL, the largest iPad at
    // FULL, and the resolution the intro used to stop at.
    const int windows[][2] = {
        { 640, 480 },
        { 854, 480 },
        { 1040, 480 },
        { 1274, 588 },
        { 1376, 1032 },
        { 2556, 1179 },
    };

    for (const auto& window : windows) {
        for (int lineHeight = 1; lineHeight <= 32; lineHeight++) {
            checkWindow(window[0], window[1], lineHeight);
        }
    }

    // A window with no room for a whole line still gets a row inside it.
    checkWindow(640, 480, 0);
    checkWindow(640, 3, 2);
    checkWindow(1, 1, 1);
    checkWindow(0, 480, 12);

    if (failures != 0) {
        std::printf("%d checks failed\n", failures);
        return 1;
    }

    std::printf("the subtitle row stays inside every window\n");
    return 0;
}
