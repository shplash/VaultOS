# Fallout Community Edition

Fallout Community Edition is a fully working re-implementation of Fallout, with the same original gameplay, engine bugfixes, and some quality of life improvements, that works (mostly) hassle-free on multiple platforms.

There is also [Fallout 2 Community Edition](https://github.com/alexbatalov/fallout2-ce).

## Installation

You must own the game to play. Purchase your copy on [GOG](https://www.gog.com/game/fallout) or [Steam](https://store.steampowered.com/app/38400). Download latest [release](https://github.com/alexbatalov/fallout1-ce/releases) or build from source. You can also check latest [debug](https://github.com/alexbatalov/fallout1-ce/actions) build intended for testers.

### Windows

Download and copy `fallout-ce.exe` to your `Fallout` folder. It serves as a drop-in replacement for `falloutw.exe`.

### Linux

- Use Windows installation as a base - it contains data assets needed to play. Copy `Fallout` folder somewhere, for example `/home/john/Desktop/Fallout`.

- Alternatively you can extract the needed files from the GoG installer:

```console
$ sudo apt install innoextract
$ innoextract ~/Downloads/setup_fallout_2.1.0.18.exe -I app
$ mv app Fallout
```

- Download and copy `fallout-ce` to this folder.

- Install [SDL2](https://libsdl.org/download-2.0.php):

```console
$ sudo apt install libsdl2-2.0-0
```

- Run `./fallout-ce`.

### macOS

> **NOTE**: macOS 10.11 (El Capitan) or higher is required. Runs natively on Intel-based Macs and Apple Silicon.

- Use Windows installation as a base - it contains data assets needed to play. Copy `Fallout` folder somewhere, for example `/Applications/Fallout`.

- Alternatively you can use Fallout from MacPlay/The Omni Group as a base - you need to extract game assets from the original bundle. Mount CD/DMG, right click `Fallout` -> `Show Package Contents`, navigate to `Contents/Resources`. Copy `GameData` folder somewhere, for example `/Applications/Fallout`.

- Or if you're a Terminal user and have Homebrew installed you can extract the needed files from the GoG installer:

```console
$ brew install innoextract
$ innoextract ~/Downloads/setup_fallout_2.1.0.18.exe -I app
$ mv app /Applications/Fallout
```

- Download and copy `fallout-ce.app` to this folder.

- Run `fallout-ce.app`.

### Android

> **NOTE**: Fallout was designed with mouse in mind. There are many controls that require precise cursor positioning, which is not possible with fingers. Current control scheme resembles trackpad usage:
> - One finger moves mouse cursor around.
> - Tap one finger for left mouse click.
> - Tap two fingers for right mouse click (switches mouse cursor mode).
> - Move two fingers to scroll current view (map view, worldmap view, inventory scrollers).

> **NOTE**: From Android standpoint release and debug builds are different apps. Both apps require their own copy of game assets and have their own savegames. This is intentional. As a gamer just stick with release version and check for updates.

- Use Windows installation as a base - it contains data assets needed to play. Copy `Fallout` folder to your device, for example to `Downloads`. You need `master.dat`, `critter.dat`, and `data` folder. Watch for file names - keep (or make) them lowercased (see [Configuration](#configuration)).

- Download `fallout-ce.apk` and copy it to your device. Open it with file explorer, follow instructions (install from unknown source).

- When you run the game for the first time it will immediately present file picker. Select the folder from the first step. Wait until this data is copied. A loading dialog will appear, just wait for about 30 seconds. The game will start automatically.

### iOS

> **NOTE**: iOS 14 (or later) is required.

> **NOTE**: See Android note on controls.

- Download `fallout-ce.ipa`. Use sideloading applications ([AltStore](https://altstore.io/) or [Sideloadly](https://sideloadly.io/)) to install it to your device. Alternatively you can always build from source with your own signing certificate.

- The app contains both engines. Pick Fallout or Fallout 2 at the top of the launcher; only the selected engine is started. Each game has its own installation, configuration and `SAVEGAME` folder: Fallout 1 keeps using the app's Documents folder, Fallout 2 uses `Documents/Fallout2`. Switching games means relaunching the app.

- Prepare a ZIP of your installation, either at the top level or inside a single folder (for example `Fallout/` or `Fallout2/`):
    - Fallout 1: `master.dat`, `critter.dat` and the `data` folder.
    - Fallout 2: `master.dat`, `critter.dat`, `patch000.dat` and the `data` folder.

  On Windows, right-click the game folder and choose **Send to > Compressed (zipped) folder**; on macOS, right-click it and choose **Compress**.

- Run the app. The launcher starts instead of the game. The left rail switches game and page, and Play sits at its foot; nothing in the launcher scrolls:
    - **HOME**: the selected game, its artwork, the installation state and **IMPORT GAME ZIP**. **PLAY** stays in the bottom right corner on every page.
    - **DISPLAY**: the FULL/HALF resolution presets, or a custom width and height.
    - **AUDIO**: the master, music, effects and speech volumes, for the game, plus the launcher's own music switch.
    - **GAME**: language (for the game, the launcher and the controls), subtitles and running (the character runs instead of walking, unless Shift is held).
    - **CONTROLS**: joystick and button size, control opacity, white buttons and **EDIT CONTROL LAYOUT**.
    - **TIPS**: touch, survival and launcher notes, with links to the Fallout and Fallout 2 wikis.
    - **CREDITS**: what the app is built on, whose work it contains and the trademark notice.
    - Each page with settings has **RESET**, which puts that page back to its defaults.
    - Every option is stored per game. Importing a ZIP again replaces the game data and keeps your savegames.
    - The GAME page's language applies to the whole app: the launcher's text and the on-screen control labels switch at once, and the game's own text and voice switch the next time you tap Play. A language your installation does not contain stays English, so an English copy set to French still plays in English.
    - The game's text and voice always come from your own installation, which carries the languages it shipped with in `master.dat`. A language pack placed as loose files in `data/text/<language>/` (`Documents/data/text/<language>/` for Fallout, `Documents/Fallout2/data/text/<language>/` for Fallout 2) is used as well, because the game reads the `data` folder before the archive.
    - **LANGUAGE FILES** on HOME adds such a pack: zip the game's own `data/text` folder (at the root, inside one folder or inside `data/`) and pick it. It is unpacked into the selected game's installation only, so the two games keep their own, and the app itself still ships no game data. A pack that names its folders in its own language (`text/FRANCAIS`, `text/DEUTSCH`) is stored under the name the game asks for, and the GAME page switches to the language the pack carried.
    - Music: the launcher looks for `maybe.mp3` for Fallout and `blue moon.mp3` for Fallout 2, and falls back to `intro music.mp3` for any game without a theme of its own. Any MP3 in the repository root is bundled automatically, so a track is added by dropping the file in; the AUDIO page shows which theme is in use.
    - Home shows the selected game's own still: `IMG_3570.webp` for Fallout, `IMG_3579.jpeg` for Fallout 2. Both are bundled from the repository root, so the launcher needs no network.

- Imported Fallout 1 data lives in the app's Documents folder, together with `fallout.cfg`, `f1_res.ini` and `SAVEGAME`. Imported Fallout 2 data lives in `Documents/Fallout2` with its own `fallout2.cfg`, `f2_res.ini` and `SAVEGAME`. File Sharing remains enabled, so you can still copy the files manually with Finder or iTunes ([how-to](https://support.apple.com/HT210598)) - the launcher detects them.

- Pushing to `main`, or running **Actions > Build iOS IPA > Run workflow**, builds an unsigned IPA and uploads it as the `fallout-ce-ios-unsigned` artifact. Use AltStore or Sideloadly to sign it with your own Apple ID before installing. The iOS build fetches Fallout 2 CE from `alexbatalov/fallout2-ce` at the revision pinned in `CMakeLists.txt` and embeds it as `Fallout2Engine.framework`; the workflow verifies both engines, their entry points, the ARM64/iOS architecture and the framework's SDL linkage before uploading.

## Configuration

The main configuration file is `fallout.cfg`. There are several important settings you might need to adjust for your installation. Depending on your Fallout distribution main game assets `master.dat`, `critter.dat`, and `data` folder might be either all lowercased, or all uppercased. You can either update `master_dat`, `critter_dat`, `master_patches` and `critter_patches` settings to match your file names, or rename files to match entries in your `fallout.cfg`.

The `sound` folder (with `music` folder inside) might be located either in `data` folder, or be in the Fallout folder. Update `music_path1` setting to match your hierarchy, usually it's `data/sound/music/` or `sound/music/`. Make sure it match your path exactly (so it might be `SOUND/MUSIC/` if you've installed Fallout from CD). Music files themselves (with `ACM` extension) should be all uppercased, regardless of `sound` and `music` folders.

The second configuration file is `f1_res.ini`. Use it to change game window size and enable/disable fullscreen mode.

```ini
[MAIN]
SCR_WIDTH=1280
SCR_HEIGHT=720
WINDOWED=1
```

Recommendations:
- **Desktops**: Use any size you see fit.
- **Tablets**: Set these values to logical resolution of your device, for example iPad Pro 11 is 1668x2388 (pixels), but it's logical resolution is 834x1194 (points).
- **Mobile phones**: Set height to 480, calculate width according to your device screen (aspect) ratio, for example Samsung S21 is 20:9 device, so the width should be 480 * 20 / 9 = 1067.

On iOS all of these settings are available in the launcher, which writes `fallout.cfg` and `f1_res.ini` for you. On desktop you have to edit the files manually for now.

## Contributing

Here is a couple of current goals. Open up an issue if you have suggestion or feature request.

- **Update to v1.2**. This project is based on Reference Edition which implements v1.1 released in November 1997. There is a newer v1.2 released in March 1998 which at least contains important multilingual support.

- **Backport some Fallout 2 features**. Fallout 2 (with some Sfall additions) added many great improvements and quality of life enhancements to the original Fallout engine. Many deserve to be backported to Fallout 1. Keep in mind this is a different game, with slightly different gameplay balance (which is a fragile thing on its own).

## License

The source code is this repository is available under the [Sustainable Use License](LICENSE.md).
