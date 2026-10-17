# Changelog

## Unreleased

- Help → Support TajArchive… opens the donation page (disk-image version only; the Mac
  App Store version has no donation links).

## 1.0.0 — 2026-10

First public release of TajArchive (previously developed as a 7-Zip port).

### Installation
- Disk image with a drag-to-Applications window.
- Offers to move itself into Applications when started from the disk image, then ejects
  the image.
- Welcome window: turns on the Finder menu with one click, makes TajArchive the app for
  `.7z`, `.rar` and other archives, explains Quick Look.
- Finds the earlier "7-Zip.app" build and offers to move it to the Trash.

### New
- Own icon and version scheme (engine version shown separately in About).
- Complete Russian and Tajik translations; menus and dialogs of 87 more languages from the
  7-Zip translations; "Same as macOS" language choice.
- Go menu with Finder's shortcuts; Help menu with logs and links.
- Context menu: Open as Archive, Show in Finder, Share, Add to Archive, Test Archive.
- Copy To… / Move To… pick a folder when only one pane is open; copying runs in the
  background with progress.
- Pause and resume for long operations; Dock bounce when a job ends in the background.
- Customizable toolbar; window size, list columns and last folder are remembered.
- Opens Zstandard and LZ4 files without any extra tools; recognizes WIM, CAB, ARJ, LHA,
  CPIO, RPM, DEB, XAR, MSI, VHD and more; split `.001` archives open on double-click.
- Thumbnails for more formats, drawn at full Retina resolution.
- Quick Look preview follows light and dark mode and the system language.

### Fixed
- Creating ZIP archives with the default settings failed.
- Modification dates inside archives were never shown.
- The app icon was drawn into a quarter of its canvas at large sizes.
- Thumbnails were drawn into a quarter of their canvas on Retina displays.
- File-list settings (real icons, grid lines, single-click opening) had no effect.
- Settings → File Associations pointed at the old 7-Zip.app and the wrong CAB type.
- Changing the language did not relaunch the app.
- Mixed English and Russian throughout the interface.
