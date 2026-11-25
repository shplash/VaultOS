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

  <a href="https://raw.githubusercontent.com/shplash/shplash-repo/main/apps.json">
    <img src="https://img.shields.io/badge/AltSource-Get-729864?style=for-the-badge">
  </a>

  <br>

  <a href="https://github.com/shplash/vaultos/releases">
    <img src="https://img.shields.io/github/v/release/shplash/vaultos?style=for-the-badge&label=release&color=0A84FF">
  </a>

  <a href="https://github.com/shplash/vaultos/releases">
    <img src="https://img.shields.io/badge/Download-IPA-0A84FF?style=for-the-badge">
  </a>

  <br>

  <a href="https://github.com/shplash/vaultos/issues">
    <img src="https://img.shields.io/github/issues/shplash/vaultos?style=for-the-badge&label=open%20issues&color=6E7681">
  </a>
</p>

<p align="center">
If you found VaultOS useful, a GitHub star is always appreciated.
</p>

## Features

- Fallout and Fallout 2 in one app
- Runs natively: no JIT or entitlements.
- Launcher with everything you'd need
- Your own game ZIP per game, with separate installs and saves
- Touch controls with move, resize and opacity editing
- Language pack imports and savegame backups handled in the launcher

## Install

1. Grab the latest [release](https://github.com/shplash/vaultos/releases).
2. Sideload it with LiveContainer, SideStore, Feather, AltStore, TrollStore etc.

## Requirements

- iOS 14 or newer
- Your own copy of Fallout and/or Fallout 2. Nothing is included or downloaded.

## Game files

Zip the game once, then import that ZIP in the launcher. Either the game folder itself, or one folder around it (`Fallout/`, `Fallout2/`).

| Game | The ZIP needs |
| --- | --- |
| **Fallout** | `master.dat` `critter.dat` `data/` |
| **Fallout 2** | `master.dat` `critter.dat` `patch000.dat` `data/` |

Each game keeps its own files and saves: `Documents/` for Fallout, `Documents/Fallout2/` for Fallout 2, both show up in the Files app. Saves live in `data/SAVEGAME` inside that folder, one `SLOT01`, `SLOT02`… per save.

## In the launcher

- **LANGUAGE FILES** adds a translation pack you supply
- **BACK UP** writes `fo(1/2)-save-backup-(date).zip` into the game's folder. **IMPORT** replaces the saves

## Notes & Licensing

Unofficial. Fallout is a trademark of Bethesda Softworks, not affiliated with Bethesda or Interplay.

Engines by Alexander Batalov ([Fallout CE](https://github.com/alexbatalov/fallout1-ce), [Fallout 2 CE](https://github.com/alexbatalov/fallout2-ce)); everything here is under the [Sustainable Use License](LICENSE.md).

## <a href="https://ko-fi.com/shplash"><img src="https://img.shields.io/badge/Support-ko--fi-FF5E5B?style=for-the-badge" alt="Support"></a>

If VaultOS has been useful to you, you can support its development as well as future projects.
