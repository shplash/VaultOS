# VaultOS design system

VaultOS looks like a maintenance deck: cold steel plates, cut corners, stencil
lettering and hazard tape used as a warning, not decoration. The launcher, the
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
| `hazard` | `#F0A32A` | hazard tape, the selected tick, a held control |
| `hazardInk` | `#0B0B0C` | text on top of hazard |
| `amber` | `#E5A935` | Fallout's accent |
| `teal` | `#5FB3A8` | Fallout 2's accent |

The two game accents are identity only: they colour the game's tab, its hero
rule and its primary actions. Hazard amber is the app's own warning colour and
never means a game.

## Type

- **Display**: Black Ops One, bundled (`assets/fonts/`, OFL licence beside it),
  always upper case, tracking 1–2.4. Page titles, the game wordmark, PLAY, the
  editor title and the confirmation dialogs. If the font is missing the same
  style falls back to the heaviest monospaced system face.
- **Label**: SF Mono semibold or bold, 8–10pt, tracking 0.2–1.3, upper case.
  Rail items, button faces, row details, field chips, footnotes.
- **Body**: SF regular, 12–14pt. Taglines and sentences the player reads.
- **Numbers**: SF Mono only, so a value never shifts as it changes.

## Shape

- Corner radius 3–8pt. Nothing rounder except the joystick and the switches.
- Plates carry one chamfered corner: a 7–16pt straight cut on the top-trailing
  corner, plus a 1pt hairline outline and a 1pt light line along the top edge.
  That bevel is the whole "steel" effect; no gradients, no shadows, no glass.
- The rail is a plate, not a card: no rounding, a hairline on its trailing edge.

## Hazard tape

A 45° amber and black band, drawn by `VaultHazard`/`HazardStripView`. Use it
only where something is a warning, a commitment or a selection:

- the selected rail item's tick,
- the rule under a page header,
- the fill of a control that must be held,
- the top edge of the help card and the destructive dialogs,
- faint tape across the PLAY button and behind the rail.

Never as a background for text, never for a whole panel, never in more than one
place in the same block.

## Components

- **Primary action** (`PrimaryButtonStyle`): chamfered accent plate, hazard ink
  label in the display face, faint tape across it, 82% while pressed.
- **Secondary action** (`SmallButtonStyle`): inset plate, accent outline and
  accent mono label; pressed fills with 18% accent.
- **Row**: title and detail on the left, control on the right, hairline under.
- **Toggle** (`PillToggle`): hazard when on with an ink knob, near-black when
  off.
- **Touch control** (`LabeledControlButton`): chamfered plate at the player's
  chosen colour, icon above a mono label; a held control fills with hazard, a
  selected one washes with it.
- **Camera pad** (`CameraJoystickControl`): a thin ring and crosshair over the
  hull, with a plain knob; no glow.
- **Help card**: hull plate, hazard strip along its top, mono body text.

## Checking a change

Read it at the launcher's smallest layout (560×320, which it scales from) and at
tablet landscape. Then check the overlay over both games, in play and in the
inventory, and the editor with the bars shown and hidden.
