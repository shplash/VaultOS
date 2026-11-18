<p align="center">
  <img src="assets/appicon.png" width="187" alt="VaultOS Icon">
</p>

<h1 align="center">VaultOS</h1>

<p align="center">
  Fallout and Fallout 2 in one iOS app, with a launcher built for touch
</p>

<p align="center">
  <a href="https://github.com/shplash/fallout1-ce-iosimproved/stargazers">
    <img src="https://img.shields.io/github/stars/shplash/fallout1-ce-iosimproved?style=for-the-badge&label=stars&color=729864">
  </a>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/actions/workflows/build.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/shplash/fallout1-ce-iosimproved/build.yml?style=for-the-badge&label=build&color=729864">
  </a>

  <br>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/releases/latest">
    <img src="https://img.shields.io/github/v/release/shplash/fallout1-ce-iosimproved?style=for-the-badge&label=release&color=0A84FF">
  </a>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/actions/workflows/build.yml">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>

  <br>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/issues">
    <img src="https://img.shields.io/github/issues/shplash/fallout1-ce-iosimproved?style=for-the-badge&label=open%20issues&color=6E7681">
  </a>
</p>

<p align="center">
If you found VaultOS useful, a GitHub star is always appreciated.
</p>

## Features

- Fallout and Fallout 2 in one app: pick the game in the launcher and only that engine starts
- A launcher built for a phone: fixed pages that never scroll, with PLAY always at the foot of the rail
- Your own game ZIP imported per game, with separate installations, configuration and savegames
- Touch controls with an editable layout, size, opacity, and white or tinted buttons
- One language setting covering the game, the launcher and the on-screen controls
- Language packs and savegame backups, both handled inside the launcher

## Install

1. Download the IPA from the [latest build](https://github.com/shplash/fallout1-ce-iosimproved/actions/workflows/build.yml) (`vaultos-ios-unsigned`) or from a [release](https://github.com/shplash/fallout1-ce-iosimproved/releases/latest).
2. Install it with a sideloading tool that signs for your device.

Use:
- SideStore
- AltStore
- Feather
- LiveContainer
- TrollStore
- etc

## Requirements

- iOS 14 or newer
- Your own copy of Fallout and/or Fallout 2: the app contains no game data, and none is bundled or downloaded. The engines are here, the game is yours.

## Your game files

The launcher takes a ZIP of your installation, either at the top level or inside a single folder (`Fallout/`, `Fallout2/`):

- Fallout: `master.dat`, `critter.dat` and the `data` folder
- Fallout 2: `master.dat`, `critter.dat`, `patch000.dat` and the `data` folder

On Windows, right-click the folder and choose **Send to > Compressed (zipped) folder**; on macOS, right-click and choose **Compress**.

Each game keeps its own installation and savegames:

```
Documents/                 Fallout: game data, fallout.cfg, f1_res.ini, SAVEGAME
Documents/Fallout2/        Fallout 2: game data, fallout2.cfg, f2_res.ini, SAVEGAME
```

Switching games means relaunching the app. File Sharing is enabled, so both folders are also reachable from the Files app.

## The launcher

- **HOME**: the selected game, its artwork, what is installed and what is missing, **IMPORT GAME ZIP** and **LANGUAGE FILES**
- **DISPLAY**: the FULL and HALF resolution presets, or a width and height of your own
- **AUDIO**: master, music, effects and speech volumes, plus the launcher's own music
- **GAME**: language, subtitles, running, and **BACK UP** / **IMPORT** for savegames
- **CONTROLS**: joystick and button size, control opacity, white buttons and **EDIT CONTROL LAYOUT**
- **TIPS**: touch, survival and launcher notes, with links to the Fallout and Fallout 2 wikis
- **CREDITS**: what the app is built on and the trademark notice

Every page with settings has **RESET**, which puts that page back to its defaults, and every option is stored per game.

Language: the GAME page setting applies to the game's own text and voice, the launcher and the on-screen controls at once. Text your installation does not contain stays English. **LANGUAGE FILES** on HOME adds a pack you supply: zip the game's own `data/text` folder and pick it, and the folder is stored under the name the engine asks for.

Savegames: **BACK UP** writes that game's `SAVEGAME` folder to `fo1-save-backup-YYYY-MM-DD-HHMM.zip` (`fo2-` for Fallout 2) beside the game data, so it shows up in Files. **IMPORT** puts a backup back after a five second countdown, because every save in that installation is replaced.

## Notes & Licensing

Fallout is a trademark of Bethesda Softworks. This is an unofficial fan project, not affiliated with Bethesda or Interplay, and you must own the games to play.

The engines are [Fallout Community Edition](https://github.com/alexbatalov/fallout1-ce) and [Fallout 2 Community Edition](https://github.com/alexbatalov/fallout2-ce) by Alexander Batalov, under the Sustainable Use License. The app also bundles SDL 2.0 (zlib licence), zlib and fpattern.

VaultOS installs as `VaultOS`, bundle identifier `com.shplash.vaultos`, version `1.0` (build `109`), for iOS 14 and newer. This repository is licensed under the [Sustainable Use License](LICENSE.md). Pushing to `main`, or running **Actions > Build iOS IPA > Run workflow**, builds an unsigned IPA, verifies both engines, their entry points and the bundled artwork, and uploads it as `vaultos-ios-unsigned`.

## <a href="https://ko-fi.com/shplash"><img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge" alt="Support"></a>

If VaultOS has been useful to you, you can support its development as well as future projects.
