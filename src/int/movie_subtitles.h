#ifndef FALLOUT_INT_MOVIE_SUBTITLES_H_
#define FALLOUT_INT_MOVIE_SUBTITLES_H_

#include <algorithm>

namespace fallout {

/// Where a movie's subtitle row goes in the window the movie draws into.
///
/// The row takes a line of the subtitle font plus its padding, across the full
/// width, on the window's last lines: the movie is fitted above it by its
/// height. Every value is clamped to the window, so no window size can place
/// the row outside the surface it is drawn into; a rect this small is drawn and
/// nothing else, which is what keeps a tall screen from writing past it.
struct MovieSubtitleRect {
    int x;
    int y;
    int width;
    int height;
};

/// The row for a window of `windowWidth` by `windowHeight`, with a line of the
/// subtitle font `lineHeight` pixels tall. A width or height of zero means the
/// window has no room for a row, and the subtitle is skipped.
inline MovieSubtitleRect movieSubtitleRect(int windowWidth, int windowHeight, int lineHeight)
{
    MovieSubtitleRect rect;
    rect.x = 0;
    rect.width = std::max(windowWidth, 0);

    int height = std::max(lineHeight, 0) + 4;
    if (windowHeight < 1 || height > windowHeight) {
        height = windowHeight;
    }

    rect.height = std::max(height, 0);
    rect.y = windowHeight - rect.height;

    return rect;
}

} // namespace fallout

#endif /* FALLOUT_INT_MOVIE_SUBTITLES_H_ */
