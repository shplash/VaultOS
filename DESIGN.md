# VaultOS design system

VaultOS looks like a deck panel: cold steel plates, stencil lettering and one
accent colour that belongs to the game you are looking at. The launcher, the
in-game touch overlay, the inventory help card and the control editor all draw
from these tokens; nothing takes a colour or a font of its own.

The implementation is `os/ios/launcher/VaultTheme.swift`. Change a token there
and every surface follows.

## Colour

| Token | Value | Used for |
| --- | --- | --- |
| `hull` | `#0A0B0C` | the screen behind everything |
| `plate` | `#14161A` | sheets, cards, the rail |
| `inset` | `#0E1013` | wells: text fields, unchecked buttons |
| `text` | `#E9EDF1` | headings and row titles |
| `dim` | `#9AA1A9` | secondary copy, values |
| `faint` | `#6B727A` | captions, footnotes, inactive icons |
| `hairline` | white 9% | every divider and panel outline |
| `edgeLight` | white 16% | the lit top edge of a plate |
| `ink` | `#0B0B0C` | text sitting on an accent fill |
| `amber` | `#E5A935` | Fallout's accent |
| `teal` | `#5FB3A8` | Fallout 2's accent |

**The accent is the selected game.** The rail bar, the game tabs, the line under
each page header, the switches, the preset tiles, the buttons, the hero copy and
the glow behind the launcher all read `FalloutGame.accent`, so switching game
recolours the whole launcher from amber to teal and back. Nothing is allowed to
hard-code one of the two accents.

The in-game controls are the exception: they use the control colour the player
picked in CONTROLS (white, orange, green or blue) on what a control says - its
glyph and its label - and on the wash of a held or selected button. Their
plates, outlines and shadows are neutral: near-black `#101010`, one charcoal
outline `#555555`, a lighter charcoal for a press. They sit over the game rather
than marking it, so nothing coloured is allowed on their borders.

## Type

- **Display**: Anton, bundled (`assets/fonts/`, OFL licence beside it), always
  upper case, tracking 0.4–2.4. The game names in the rail, page titles, the
  hero wordmark, PLAY, the editor title and the confirmation dialogs. It is the
  closest free match to the condensed caps of the Fallout title card; the games'
  own faces (Univers 59 Condensed, Gothic 821 Condensed) are proprietary and
  cannot ship. If the font is missing the same style falls back to the heaviest
  monospaced system face.
- **Label**: SF Mono semibold or bold, 8–10pt, tracking 0.2–1.3, upper case.
  Rail items, button faces, row details, field chips, footnotes.
- **Body**: SF regular, 12–14pt. Taglines and sentences the player reads.
- **Numbers**: SF Mono only, so a value never shifts as it changes.

## Shape

- Plain rounded rectangles. Sheets and the launcher cards 20pt, dialogs 18pt,
  tiles and PLAY 12pt, on-screen controls 10pt, small buttons 8pt.
- A plate is a fill, a 1pt hairline outline and a 1pt light line along its top
  edge. No cut corners, no stripes, no gradients, no shadows.

## Components

- **Primary action** (`PrimaryButtonStyle`): accent plate, ink label in the
  display face, 82% while pressed.
- **Secondary action** (`SmallButtonStyle`): translucent grey plate (white 4%),
  hairline outline and accent mono label; pressed fills with 18% accent.
- **Row**: title and detail on the left, control on the right, hairline under,
  except on the last row of a page.
- **Toggle** (`PillToggle`): accent when on with an ink knob, near-black when
  off.
- **Game selector**: the two game names at the top of the rail, centred in the
  display face at 30pt with no plate behind them: the selected game in its own
  accent, the other faint. The gap above the first name, between the two and
  below the last are the same, and each label is framed on its capitals rather
  than on its line box, so the space above and below the letters is equal too.
- **Touch control** (`LabeledControlButton`): a dark plate at 80% with a faint
  top-down shade, one 1.25pt charcoal outline, a thin lit line along its top
  edge and a small shadow, a glyph above a mono label, both in the player's
  control colour; QUICK SAVE centres its glyph and label together. A held
  control brightens its plate and outline and washes with that colour, a
  selected one keeps the wash, and one that cannot be used fades to 35%. Every
  custom in-game button is one of these, so the item screens, the trading
  screens and the dialogues wear the same face as the HUD. The control editor
  draws these faces at the size the game draws them.
- **Save assembly**: QUICK SAVE and its chevron are two halves of one control.
  A single plate, outline and top highlight sit under both (`drawsOwnPlate` is
  off for the halves), the two sit flush, and a short 62% divider at 70% of the
  outline colour separates them. QUICK SAVE takes 73% of the width, the chevron
  the rest; each keeps its own action, press state and touch area. The chevron
  snaps to either side of QUICK SAVE, and its glyph and the divider turn with
  it. The chevron opens a tray with LOAD and SAVE, closed by default.
- **Camera pad** (`CameraJoystickControl`): a thin ring and crosshair over the
  hull, with a plain knob; no glow.
- **Help card**: hull plate with a hairline edge and mono body text.

## Checking a change

Read it at the launcher's smallest layout (560×320, which it scales from) and at
tablet landscape. Then check the overlay over both games, in play and in the
inventory, and the editor with the bars shown and hidden. Switch games on every
page and confirm nothing keeps the other game's accent.
