#ifndef FALLOUT_GAME_PALETTE_H_
#define FALLOUT_GAME_PALETTE_H_

namespace fallout {

extern unsigned char white_palette[256 * 3];
extern unsigned char black_palette[256 * 3];

void palette_init();
void palette_reset();
void palette_exit();
void palette_fade_to(unsigned char* palette);
void palette_set_to(unsigned char* palette);
void palette_set_entries(unsigned char* palette, int start, int end);

// The palette the game is drawing with, 256 RGB triplets of 6 bits each.
const unsigned char* palette_current(void);

} // namespace fallout

#endif /* FALLOUT_GAME_PALETTE_H_ */
