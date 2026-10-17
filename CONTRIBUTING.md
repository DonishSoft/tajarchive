# Contributing to TajArchive

Thank you for helping! Bug reports, translations, documentation and code are all welcome.
You can write issues and pull requests in English, Russian or Tajik.

## Reporting a problem

Open an [issue](https://github.com/DonishSoft/tajarchive/issues/new/choose) and include:

- your macOS version and Mac (Apple silicon or Intel);
- the TajArchive version (TajArchive → About TajArchive) and where you got it
  (Mac App Store or the disk image);
- what you did, what you expected and what happened;
- for a problem with one archive: its format and size, and whether 7-Zip opens it.

Logs are in *Help → Show Log Files*. Check them for private file names before attaching.

## Building

Requirements: macOS 12 or later and Xcode 16 or later.

```bash
git clone https://github.com/DonishSoft/tajarchive.git
cd tajarchive
open 7-Zip/7-Zip.xcodeproj      # then Product → Run
```

Running from Xcode needs no Apple developer account: choose your own team, or none, in
*Signing & Capabilities*. `./deploy.sh` builds Release and installs it into
`/Applications` (it uses the DonishSoft team; change `DEVELOPMENT_TEAM` for your own).

Build configurations:

| Configuration | Used for |
| --- | --- |
| Debug | development |
| Release | the disk image (Developer ID, not sandboxed) — `Scripts/release.sh` |
| AppStore | the Mac App Store build (App Sandbox, `APPSTORE` compilation flag) |

The 7-Zip engine is the prebuilt universal `7-Zip/7-Zip/Resources/7zz`. To rebuild it from
the unmodified source in `Vendor/`, run `Scripts/build_7zz.sh`.

## Code

- Swift and AppKit, no third-party dependencies. Match the style of the file you edit.
- Every string shown to people goes through `L("English text")`; the English text is the
  key. Run `python3 Scripts/localize_literals.py <file>` to find strings you missed.
- Passwords never go on a command line: pass them to `7zz` through stdin as
  `SevenZipWrapper` does.
- Anything that writes to disk from the App Store build must go through
  `FolderAccess` (the sandbox only allows folders the user granted).
- Keep pull requests focused: one fix or feature per pull request, with a short
  description of how you tested it.

## Translations

`7-Zip/7-Zip/Resources/en.lproj/Localizable.strings` lists every string. Copy it to
`<language>.lproj/Localizable.strings`, translate the right-hand side of each line and keep
`%@` and `%d` placeholders. The Finder menu and the Quick Look preview have their own small
catalogs in `7-Zip Finder Extension/` and `7-Zip/7-Zip Quick Look/`. Russian and Tajik are
maintained by hand; most other languages are generated from the 7-Zip translations by
`Scripts/build_localizations.py`, so hand-written improvements there are welcome too.

## License

By contributing you agree that your contribution is licensed under the
[GNU LGPL 2.1 or later](LICENSE), like the rest of TajArchive.
