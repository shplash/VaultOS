<p align="center">
  <img src="assets/appicon.png" width="187" alt="VaultOS Icon">
</p>

<h1 align="center">VaultOS</h1>

<p align="center">
  Fallout and Fallout 2, on iOS
</p>

<p align="center">
  <a href="https://github.com/shplash/vaultos/stargazers">
    <img src="https://img.shields.io/github/stars/shplash/vaultos?style=for-the-badge&label=stars&color=729864">
  </a>

  <a href="https://github.com/shplash/vaultos/releases">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>
</p>

## Features

- Fallout and Fallout 2 in one app, each with its own install and saves
- Runs natively: no JIT, no entitlements
- A ZIP of your own game files is all it needs; the app ships no game data
- Touch controls you can move, resize, fade and colour
- Language packs and savegame backups handled in the launcher
- New and tweaked mechanics to accommodate both a small screen and touch controls

## Install

1. Get the latest [release](https://github.com/shplash/vaultos/releases).
2. Sideload the IPA with AltStore, SideStore, Feather, LiveContainer or TrollStore.

If LiveContainer doesn’t let you select the zip, try turning its **Fix File Picker** option on.

## Requirements

- iOS 14 or newer
- Your own copy of Fallout and/or Fallout 2. Nothing is included or downloaded.

## Game files

Zip the game once, then import that ZIP in the launcher. Either the game folder
itself, or one folder around it (`Fallout/`, `Fallout2/`).

| Game | The ZIP needs |
| --- | --- |
| **Fallout** | `master.dat` `critter.dat` `data/` |
| **Fallout 2** | `master.dat` `critter.dat` `patch000.dat` `data/` |

Each game keeps its own files and saves: `Documents/` for Fallout,
`Documents/Fallout2/` for Fallout 2, both show up in the Files app. Saves live in
`data/SAVEGAME` inside that folder, one `SLOT01`, `SLOT02`… per save. Backups go
to `Backups/` in that same folder, `fo1-save-backup-(date).zip` for Fallout and
`fo2-save-backup-(date).zip` for Fallout 2, one file per backup: an older one is
never replaced.

## In the launcher

- **LANGUAGE FILES** adds a translation pack you supply
- **BACK UP** writes `Backups/fo(1/2)-save-backup-(date).zip` into the game's
  folder. **IMPORT** replaces the saves

## Notes

Unofficial. Fallout is a trademark of Bethesda Softworks, not affiliated with
Bethesda or Interplay.

VaultOS is a modified version of Alexander Batalov's Fallout Community Edition
engines ([Fallout CE](https://github.com/alexbatalov/fallout1-ce),
[Fallout 2 CE](https://github.com/alexbatalov/fallout2-ce)).

The code is under the [Sustainable Use License](LICENSE.md), Also see
[third_party](third_party/README.md).

## Support

<p align="left">
  <a href="https://ko-fi.com/shplash">
    <img src="https://img.shields.io/badge/ko--fi-Support-FF5E5B?style=for-the-badge" alt="Support on Ko-fi">
  </a>
</p>

Support this projects development as well as future projects :)
