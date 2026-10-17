# TajArchive

[![Build](https://github.com/DonishSoft/tajarchive/actions/workflows/build.yml/badge.svg)](https://github.com/DonishSoft/tajarchive/actions/workflows/build.yml)
[![License: LGPL v2.1](https://img.shields.io/badge/license-LGPL%202.1-blue.svg)](LICENSE)
[![Patreon](https://img.shields.io/badge/Patreon-support-F96854?logo=patreon&logoColor=white)](https://www.patreon.com/c/TajArchive)

**Website:** <https://donishsoft.github.io/tajarchive/> ·
**Download:** [latest release](https://github.com/DonishSoft/tajarchive/releases/latest) ·
[Русский сайт](https://donishsoft.github.io/tajarchive/ru/)

A free, native archiver for macOS: a full file-manager window, a Finder context menu,
Quick Look previews and archive thumbnails. Universal app for Apple silicon and Intel,
macOS 12 Monterey or later.

TajArchive is an independent application by DonishSoft, built on the **7-Zip compression
engine by Igor Pavlov** (<https://www.7-zip.org/>). It is not affiliated with, endorsed by,
or supported by the 7-Zip project. The engine ships unmodified as a separate `7zz`
executable inside the app, so it can be replaced with any compatible build — see
[License](#license).

## Install

1. Download `TajArchive-1.0.0.dmg` and open it.
2. Drag **TajArchive** onto **Applications**.
3. Open TajArchive from Applications. The welcome window turns on the Finder menu with one
   click and can make TajArchive the app that opens `.7z`, `.rar` and other archives.

If you start TajArchive straight from the disk image, it offers to move itself into
Applications. The welcome window is always available again from the TajArchive menu →
Setup Assistant.

### Установка (по-русски)

1. Скачайте `TajArchive-1.0.0.dmg` и откройте его.
2. Перетащите **TajArchive** в папку **Программы**.
3. Запустите TajArchive из «Программ». В окне приветствия одной кнопкой включается меню
   в Finder, а второй — TajArchive становится программой для архивов `.7z`, `.rar` и других.

Если запустить TajArchive прямо из образа диска, программа сама предложит перенести себя
в «Программы». Окно приветствия всегда можно открыть снова: меню TajArchive → «Ассистент
настройки…».

## Features

- 📦 **Opens 40+ formats**: 7z, ZIP, RAR, TAR, GZip, BZip2, XZ, Zstandard, LZ4, Apple
  Archive, CAB, ARJ, LHA, WIM, ISO, DMG, CPIO, RPM, DEB, XAR, MSI, VHD/VMDK and more;
  any other container (.docx, .jar, .apk…) with *Open as Archive*
- ✍️ **Creates** 7z, ZIP, TAR, GZip, BZip2, XZ, TAR + Zstandard, TAR + LZ4, Apple Archive and
  the own `.taj` format, with split volumes and self-extracting `.command` archives
- 🎛️ **Full compression control**: level, method, dictionary and word size, solid blocks,
  threads, path and update modes, with a live memory estimate
- 🔗 **Finder menu**: compress, extract here / to a folder, test, checksums — turned on with
  one click in the welcome window
- 👁️ **Quick Look and thumbnails**: press Space on an archive to see its contents; archives
  get format thumbnails with the number of files inside
- 🗂 **Two panes**: commander-style layout; F5/F6 copy or move between panes, between an
  archive and a folder, or — with one pane — to any folder you pick
- 🔐 **Encryption**: AES-256, optional encrypted file names for 7z; passwords never appear
  in process arguments
- ⏸ **Pause and resume** long operations; the Dock icon bounces when a job finishes in the
  background
- 🧭 **Finder shortcuts**: Go menu (⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A, ⇧⌘G), Show in Finder, Share
  (AirDrop, Mail, Messages), favorites (⌘1…⌘9)
- 📊 **Benchmark**, checksums (CRC-32/64, SHA-1/256/512, BLAKE2sp), split and combine files
- 🌍 **Languages**: English, Russian and Tajik in full; menus and dialogs of 87 more languages
  from the 7-Zip translations
- 🆓 **Free and open source**: GNU LGPL

## Building

Requirements: macOS 12 or later, Xcode 16 or later.

```bash
./deploy.sh            # Release build, installed as /Applications/TajArchive.app
./Scripts/release.sh   # signed, notarized disk image in build/release/ (and on the Desktop)
./Scripts/appstore.sh  # sandboxed Mac App Store build, uploaded to App Store Connect
```

`deploy.sh` leaves exactly one registered copy of the app, so macOS never picks the Finder
menu or Quick Look plug-in from a stale build folder.

`release.sh` archives, exports with Developer ID, notarizes and staples the app, builds the
disk image with its drag-to-Applications layout, then notarizes and staples the image too.
Notarization needs a keychain profile, created once; run the script in Terminal and it
offers to create it (you paste an app-specific password from
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific
Passwords). Without it the script still builds a test image named `…-UNNOTARIZED.dmg`,
which other Macs refuse to open.

`appstore.sh` archives the sandboxed `AppStore` configuration, exports it signed for the
Mac App Store and uploads it with the Apple ID signed in to Xcode (`--export` only writes
the `.pkg`). Raise the build number in the Xcode project before every new upload.

The bundled engine is prebuilt; to rebuild it from the vendored source:

```bash
./Scripts/build_7zz.sh
```

### Other scripts

| Script | Purpose |
| --- | --- |
| `Scripts/make_icon.swift` | Renders the app icon at every size |
| `Scripts/make_dmg_background.swift` | Renders the disk-image background |
| `Scripts/dmg_settings.py` | Disk-image window layout for dmgbuild |
| `Scripts/build_localizations.py` | Builds the 87 extra languages from the 7-Zip translations |
| `Scripts/localize_literals.py` | Finds interface strings not yet wrapped in `L(…)` |

## Translating

Interface strings are looked up by their English text: `L("Extract Here")`.
`7-Zip/7-Zip/Resources/en.lproj/Localizable.strings` is the complete catalog — copy it to
`<language>.lproj/Localizable.strings` and change only the right-hand sides. The Finder
menu and the Quick Look preview have small catalogs of their own in
`7-Zip Finder Extension/` and `7-Zip/7-Zip Quick Look/`.

## Project structure

```
TajArchive/
├── 7-Zip/                         Xcode project
│   ├── 7-Zip/                     the app
│   │   ├── App/                   AppDelegate, main menu
│   │   ├── Core/                  7zz wrapper, extra formats, .taj codec, installer, settings
│   │   ├── Models/
│   │   ├── Views/                 windows, sheets, setup assistant
│   │   └── Resources/             7zz engine, translations
│   └── 7-Zip Quick Look/          Quick Look preview (native parsers)
├── 7-Zip Finder Extension/        Finder context menu
├── TajArchive Thumbnails/         Finder thumbnails
├── Scripts/                       build, release, icon and translation tools
├── Tests/Fixtures/                sample archives
├── docs/                          website (GitHub Pages): privacy policy, support
└── Vendor/                        7-Zip 25.01 source and language files
```

## Architecture notes

The interface is Swift/AppKit over the genuine upstream `7zz` command-line engine.

**Passwords never appear in `argv`.** Passing `-p<password>` would expose it to any local
process via `ps`. Instead the app passes a bare `-p` (or lets 7zz prompt) and writes the
password to the process's stdin.

**The main app is not sandboxed; the extensions are.** This is the Developer ID model
(the same one Keka uses outside the App Store): the sandboxed Finder extension forwards
commands to the app through the `tajarchive://` URL scheme, and the app — which must read
and write wherever the user points it — runs unsandboxed with the hardened runtime. Every
scheme-initiated operation that writes to disk asks for confirmation first, because any
local app can open a URL.

**Formats macOS cannot read.** Raw `.zst` streams are unpacked by the bundled 7zz; raw
`.lz4` frames by a small in-process decoder; `.tar.zst`, `.tar.lz4` and `.aar` by the
`tar` and `aa` tools that ship with macOS.

## License

TajArchive is free software: © 2026 DonishSoft, released under the
[GNU Lesser General Public License 2.1 or later](LICENSE).

The bundled 7-Zip engine is © 1999–2025 Igor Pavlov, GNU LGPL, with the unRAR license
restriction for the RAR decoder ([LICENSE-7-Zip.txt](LICENSE-7-Zip.txt),
[unRarLicense.txt](unRarLicense.txt)). It is built from unmodified 7-Zip 25.01 sources,
vendored in `Vendor/` (`7z2501-src.tar.xz`, SHA-256
`ed087f83ee789c1ea5f39c464c55a5c9d4008deb0efe900814f2df262b82c36e`, from
<https://www.7-zip.org/a/7z2501-src.tar.xz>), so anyone receiving the app can obtain and
rebuild the exact engine, as the LGPL requires.

## Contributing

Bug reports, translations and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately as described
in [SECURITY.md](SECURITY.md).

## Supporting the project

TajArchive is free and stays free. If it is useful to you, you can support its development
on **[Patreon](https://www.patreon.com/c/TajArchive)** (or with the **Sponsor** button of this repository). Donations pay
for new versions, translations and the yearly Apple developer membership needed to sign
and publish the app.

Starring the project, reporting bugs and helping with code and translations
([CONTRIBUTING.md](CONTRIBUTING.md)) help just as much. The Mac App Store version contains
no donation links, as App Store rules require.

## Credits

- **7-Zip** — the compression engine — by Igor Pavlov, <https://www.7-zip.org/>
- **libarchive** and **Apple Archive** (part of macOS) for Zstandard, LZ4 and `.aar` creation
- Translations of the 87 extra languages derived from the 7-Zip language files
- TajArchive application, Russian and Tajik translations and the `.taj` format by DonishSoft
