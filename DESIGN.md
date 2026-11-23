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
- **Label**: SF Mono semibold or bold, 9–12pt, tracking 0.2–1.3, upper case.
  Row details, button faces, chips and footnotes sit at 9–10pt; the rail items
  are 12pt. Nothing is drawn below 9pt.
- **Body**: SF regular, 12–14pt. Taglines and sentences the player reads.
- **Numbers**: SF Mono only, so a value never shifts as it changes.

## Shape

- Plain rounded rectangles. Sheets and the launcher cards 20pt, dialogs 18pt,
  tiles and PLAY 12pt, on-screen controls 10pt, chips, fields and small
  buttons 8pt.
- A plate is a fill, a 1pt hairline outline and a 1pt light line along its top
  edge. No cut corners, no stripes, no gradients, no shadows.

## Metrics

One set of numbers, `Metrics` in `LauncherView`, is used everywhere: `outer` 16
is the margin around the rail and every card, `sheetInset` 22 the padding
inside a card, `rowMinHeight` 46, `controlHeight` 32, `controlRadius` 8 and
`gap` 8.

## Components

- **Primary action** (`PrimaryButtonStyle`): accent plate, ink label in the
  display face, 82% while pressed.
- **Secondary action** (`SmallButtonStyle`): translucent grey plate (white 4%),
  hairline outline and accent mono label, 32pt minimum height; pressed fills
  with 18% accent. An optional tint gives a quiet action such as CANCEL the dim
  text colour, and a square variant makes the small stepper buttons.
- **Row**: title and detail on the left, control on the right, 46pt minimum and
  the same 8pt above and below whether or not it carries a detail line; hairline
  under, except on the last row of a page.
- **Chip** (`ChipStyle`): the one pill behind a preset, a scaling mode, a frame
  rate, a tip group, a page link and the update check. Mono 10pt with 0.8
  tracking, 12pt side padding, 32pt high, 8pt radius. Selected and primary are
  an accent fill with ink text, unselected is a 4% plate with a hairline and
  faint text, and a quiet one is the same in dim text.
- **Toggle** (`PillToggle`): accent when on with an ink knob, near-black when
  off.
- **Touch control** (`LabeledControlButton`): a dark plate at 80% with a faint
  top-down shade, one 1.25pt charcoal outline, a thin lit line along its top
  edge and a small shadow, a glyph above a mono label, both in the player's
  control colour; QUICK SAVE centres its glyph and label together. A held
  control brightens its plate and outline and washes with that colour, a
  selected one keeps the wash, and one that cannot be used fades to 35%. Every
  custom in-game button is one of these, so the item screens, the trading
  screens and the dialogues wear the same face as the HUD. The control editor
  draws these faces at the size the game draws them.
- **Rail**: a 152pt bar of page items over PLAY, the whole group centred
  between the same 16pt margins the cards use. Each item is a 44pt row with a
  16pt glyph in a 20pt box, a 12pt mono label, a 3 by 18 accent bar and, when
  selected, a 10pt rounded highlight.
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
