<p align="center">
  <img src="assets/appicon.png" width="187" alt="VaultOS Icon">
</p>

<h1 align="center">VaultOS</h1>

<p align="center">
  Fallout and Fallout 2, on iOS
</p>

<p align="center">
  <a href="https://github.com/shplash/fallout1-ce-iosimproved/stargazers">
    <img src="https://img.shields.io/github/stars/shplash/fallout1-ce-iosimproved?style=for-the-badge&label=stars&color=729864">
  </a>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/actions/workflows/build.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/shplash/fallout1-ce-iosimproved/build.yml?style=for-the-badge&label=build&color=729864">
  </a>

  <br>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/actions/workflows/build.yml">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>

  <a href="https://github.com/shplash/fallout1-ce-iosimproved/issues">
    <img src="https://img.shields.io/github/issues/shplash/fallout1-ce-iosimproved?style=for-the-badge&label=open%20issues&color=6E7681">
  </a>
</p>

<p align="center">
If you found VaultOS useful, a GitHub star is always appreciated.
</p>

## Features

- Fallout and Fallout 2 in one app
- Runs natively: no JIT or entitlements.
- Launcher with everything you’d need
- Your own game ZIP per game, with separate installs and saves
- Touch controls you can; move, resize and tweak opacity to your liking
- Language pack imports and savegame backups handled in the launcher

## Install

1. Grab `VaultOS.ipa` from the latest [release](https://github.com/shplash/fallout1-ce-iosimproved/releases).
2. Sideload it with LiveContainer, SideStore, Feather, AltStore, TrollStore etc.

Installed through **LiveContainer**, turn on **Fix File Picker** in the app's settings, or the ZIP picker will not open.

## Requirements

- iOS 14 or newer
- Your own Fallout and/or Fallout 2 files. No game data is included or downloaded.

## Game files

Zip each game on its own, at the top level or inside one folder (`Fallout/`, `Fallout2/`):

```
Fallout      master.dat, critter.dat, data/
Fallout 2    master.dat, critter.dat, patch000.dat, data/
```

`Documents/` holds Fallout, `Documents/Fallout2/` holds Fallout 2: game data, config and `SAVEGAME`. File Sharing is on, so both show up in the Files app. Switching games relaunches the app.

## In the launcher

- **HOME** installs the game, **LANGUAGE FILES** adds a translation you supply, **GAME** has language, subtitles, running and save backups, **CONTROLS** sizes and fades the on-screen buttons
- Every settings page has **RESET**, and every option is stored per game
- A language your installation does not have stays English
- **BACK UP** writes `fo1-save-backup-….zip` beside the game data; **IMPORT** replaces the saves after a five second warning

## Notes & Licensing

Fallout is a trademark of Bethesda Softworks. Unofficial fan project, not affiliated with Bethesda or Interplay; you must own the games to play.

Engines: [Fallout CE](https://github.com/alexbatalov/fallout1-ce) and [Fallout 2 CE](https://github.com/alexbatalov/fallout2-ce) by Alexander Batalov, under the Sustainable Use License, plus SDL 2.0 (zlib), zlib and fpattern. This repository is under the [Sustainable Use License](LICENSE.md).

## <a href="https://ko-fi.com/shplash"><img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge" alt="Support"></a>

If VaultOS has been useful, you can support its development too.
