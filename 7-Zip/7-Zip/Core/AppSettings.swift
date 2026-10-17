import Foundation
import UniformTypeIdentifiers

// MARK: - Option enums

/// How the `com.apple.quarantine` extended attribute of an archive is passed on to the
/// files unpacked out of it.
///
/// This is the macOS counterpart of the Windows 7-Zip option "Propagate Zone.Id stream"
/// (Options ▸ 7-Zip). On Windows the mark of the web lives in an NTFS alternate data
/// stream named `Zone.Identifier`; on macOS it lives in the `com.apple.quarantine`
/// extended attribute and is what makes Gatekeeper vet a downloaded app before it runs.
/// Dropping it silently — which every archiver that ignores xattrs does — turns an archive
/// into a laundering tool for downloaded executables, so the default matches 7-Zip's:
/// propagate for the file kinds that actually execute or carry macros.
enum QuarantinePropagation: String, CaseIterable, Codable {
    /// Extracted files never inherit the archive's quarantine mark.
    case never
    /// Default. Only files that can execute or carry macros inherit the mark
    /// (7-Zip calls this "For Office files").
    case documentsAndExecutables
    /// Every extracted item inherits the mark, which is what Archive Utility does.
    case always

    var displayName: String {
        switch self {
        case .never: return L("Never")
        case .documentsAndExecutables: return L("Only for documents and executables")
        case .always: return L("Always")
        }
    }

    /// One-line explanation shown under the control in Preferences.
    var explanation: String {
        switch self {
        case .never:
            return L("Unpacked files lose the download mark. Gatekeeper will not check them.")
        case .documentsAndExecutables:
            return L("Programs, scripts, Office documents and nested archives stay marked as downloaded.")
        case .always:
            return L("Everything unpacked stays marked as downloaded, like Archive Utility does.")
        }
    }
}

/// Where temporary files are created while an archive is opened, tested or updated.
/// Mirrors the "Working folder" radio group of Windows 7-Zip (Options ▸ Folders).
enum WorkingFolderMode: String, CaseIterable, Codable {
    /// Default: whatever `FileManager.temporaryDirectory` hands out.
    case systemTemp
    /// Next to the archive — keeps big temporary files on the same volume, so moving
    /// the finished archive into place is a rename instead of a copy.
    case sameAsArchive
    /// A folder the user picked, see `AppSettings.workingFolder`.
    case specified

    var displayName: String {
        switch self {
        case .systemTemp: return L("System temp folder")
        case .sameAsArchive: return L("Same folder as the archive")
        case .specified: return L("Specified folder:")
        }
    }
}

// MARK: - AppSettings

/// Every application-wide preference that is not tied to one compression job.
/// (Per-format compression options live in `CompressionSettings`.)
///
/// Each property reads and writes `UserDefaults` on access, so a control can write back
/// the moment it changes and any other part of the app sees the new value immediately.
enum AppSettings {

    /// Backing store. A settable seam so tests can point the whole type at a throwaway
    /// suite; the app never changes it. If the Finder extension ever needs to read these
    /// values, this is the single place to swap in an app-group suite.
    static var defaults: UserDefaults = .standard

    // MARK: - Keys

    /// Every `UserDefaults` key the app owns, in one place.
    enum Key {
        // Extraction
        static let quarantinePropagation = "taj.extraction.quarantinePropagation"

        // Folders
        static let workingFolderMode = "taj.folders.workingFolderMode"
        static let workingFolderPath = "taj.folders.workingFolderPath"
        static let workingFolderRemovableOnly = "taj.folders.useForRemovableDrivesOnly"

        // External programs
        static let viewerApplicationPath = "taj.programs.viewerPath"
        static let editorApplicationPath = "taj.programs.editorPath"
        static let diffApplicationPath = "taj.programs.diffPath"

        // File list behaviour
        static let showRealFileIcons = "taj.list.showRealFileIcons"
        static let showGridLines = "taj.list.showGridLines"
        static let singleClickToOpen = "taj.list.singleClickToOpen"

        /// Keys that predate this type. They are deliberately left unprefixed: renaming
        /// them would silently reset preferences on machines that already run the app.
        enum Legacy {
            static let appTheme = "appTheme"
            static let selectedLanguage = "selectedLanguage"
            /// `[utiIdentifier: bundleID]` of the handler that owned each UTI before we claimed it.
            static let previousHandlers = "PreviousHandlers"
            /// Apple's own key, not ours — written alongside `selectedLanguage` so the
            /// next launch comes up in the chosen language. Listed here only so that
            /// this enum really is every key the app writes.
            static let appleLanguages = "AppleLanguages"
        }
    }

    // MARK: - Typed accessors over UserDefaults

    /// `UserDefaults.bool(forKey:)` cannot tell "false" from "never set", which makes
    /// defaulting to `true` impossible. This can.
    private static func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let stored = defaults.object(forKey: key) as? Bool else { return fallback }
        return stored
    }

    private static func enumValue<T: RawRepresentable>(_ key: String, default fallback: T) -> T
    where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }

    private static func path(_ key: String) -> URL? {
        guard let stored = defaults.string(forKey: key), !stored.isEmpty else { return nil }
        return URL(fileURLWithPath: stored)
    }

    /// Stores a plain POSIX path. The app is not sandboxed (Developer ID, no entitlement
    /// for user-selected files), so no security-scoped bookmark is needed or wanted —
    /// a bookmark would only add a resolve step and a failure mode.
    private static func setPath(_ url: URL?, _ key: String) {
        if let url = url {
            defaults.set(url.path, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Extraction

    /// Default `.documentsAndExecutables`, matching 7-Zip's "For Office files".
    static var quarantinePropagation: QuarantinePropagation {
        get { enumValue(Key.quarantinePropagation, default: .documentsAndExecutables) }
        set { defaults.set(newValue.rawValue, forKey: Key.quarantinePropagation) }
    }

    // MARK: - Folders

    /// Default `.systemTemp`, matching 7-Zip.
    static var workingFolderMode: WorkingFolderMode {
        get { enumValue(Key.workingFolderMode, default: .systemTemp) }
        set { defaults.set(newValue.rawValue, forKey: Key.workingFolderMode) }
    }

    /// The folder backing `WorkingFolderMode.specified`. `nil` until the user picks one,
    /// in which case `temporaryDirectory(for:)` falls back to the system temp folder.
    static var workingFolder: URL? {
        get { path(Key.workingFolderPath) }
        set { setPath(newValue, Key.workingFolderPath) }
    }

    /// 7-Zip's "Use for removable drives only": when on, the working-folder choice applies
    /// only to archives sitting on a removable / external volume; everything else keeps
    /// using the system temp folder. Default off, matching 7-Zip.
    static var useWorkingFolderForRemovableDrivesOnly: Bool {
        get { bool(Key.workingFolderRemovableOnly, default: false) }
        set { defaults.set(newValue, forKey: Key.workingFolderRemovableOnly) }
    }

    // MARK: - External programs

    /// App used to view a file extracted out of an archive. `nil` means "whatever
    /// Launch Services considers the default for that file".
    static var viewerApplication: URL? {
        get { path(Key.viewerApplicationPath) }
        set { setPath(newValue, Key.viewerApplicationPath) }
    }

    /// App used for "Edit" on an archive member. `nil` means the Launch Services default.
    static var editorApplication: URL? {
        get { path(Key.editorApplicationPath) }
        set { setPath(newValue, Key.editorApplicationPath) }
    }

    /// App used to compare two files. `nil` means no diff tool is configured, and the
    /// menu item that uses it should stay disabled.
    static var diffApplication: URL? {
        get { path(Key.diffApplicationPath) }
        set { setPath(newValue, Key.diffApplicationPath) }
    }

    // MARK: - File list behaviour

    /// Real per-file icons instead of one generic icon per kind. 7-Zip defaults this off
    /// because Windows shell icon extraction is slow; `NSWorkspace.icon(forFile:)` is
    /// cheap and Finder-like, so on macOS it is on.
    static var showRealFileIcons: Bool {
        get { bool(Key.showRealFileIcons, default: true) }
        set { defaults.set(newValue, forKey: Key.showRealFileIcons) }
    }

    /// Draw the table's grid. Off by default, like 7-Zip.
    static var showGridLines: Bool {
        get { bool(Key.showGridLines, default: false) }
        set { defaults.set(newValue, forKey: Key.showGridLines) }
    }

    /// Open an item on a single click instead of a double click. Off by default,
    /// like 7-Zip and like Finder.
    static var singleClickToOpen: Bool {
        get { bool(Key.singleClickToOpen, default: false) }
        set { defaults.set(newValue, forKey: Key.singleClickToOpen) }
    }

    // MARK: - Working folder resolution

    /// The directory temporary files for `archiveURL` belong in, honouring
    /// `workingFolderMode` and `useWorkingFolderForRemovableDrivesOnly`.
    ///
    /// Falls back to the system temp folder whenever the configured folder cannot be
    /// used — no such folder, not a folder, or read-only (a mounted disk image, say).
    /// The returned directory exists and is writable.
    static func temporaryDirectory(for archiveURL: URL) -> URL {
        let systemTemp = FileManager.default.temporaryDirectory
        let mode = workingFolderMode
        guard mode != .systemTemp else { return systemTemp }

        if useWorkingFolderForRemovableDrivesOnly && !isOnRemovableVolume(archiveURL) {
            return systemTemp
        }

        let candidate: URL?
        switch mode {
        case .systemTemp: candidate = nil
        case .sameAsArchive: candidate = archiveURL.deletingLastPathComponent()
        case .specified: candidate = workingFolder
        }

        guard let folder = candidate, isWritableDirectory(folder) else { return systemTemp }
        return folder.standardizedFileURL
    }

    /// Creates and returns a fresh, empty, uniquely named directory inside
    /// `temporaryDirectory(for:)`. Callers are responsible for removing it.
    static func makeTemporaryWorkDirectory(for archiveURL: URL, prefix: String = "taj-") throws -> URL {
        let directory = temporaryDirectory(for: archiveURL)
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Whether `url` lives on a removable, ejectable or otherwise non-internal volume.
    /// Falls back to the parent directory when `url` itself does not exist yet, so it
    /// also answers for an archive that is about to be created.
    static func isOnRemovableVolume(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let probe = fileManager.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey
        ]
        guard let values = try? probe.resourceValues(forKeys: keys) else { return false }
        if values.volumeIsRemovable == true || values.volumeIsEjectable == true { return true }
        if let isInternal = values.volumeIsInternal { return !isInternal }
        return false
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return fileManager.isWritableFile(atPath: url.path)
    }

    // MARK: - Quarantine propagation

    static let quarantineAttributeName = "com.apple.quarantine"

    /// File kinds that inherit the quarantine mark in `.documentsAndExecutables` mode:
    /// anything that runs code, anything that can carry a macro, and nested archives —
    /// so unpacking one more level does not launder the mark away.
    ///
    /// Identifiers that this system does not declare are skipped silently.
    static let quarantineSensitiveTypeIdentifiers: [String] = [
        "public.executable",        // Mach-O binaries, .app bundles, .command files
        "public.script",            // shell, python, perl, AppleScript, …
        "public.archive",           // zip / 7z / tar / dmg …
        "com.microsoft.word.doc",   // the Office family: legacy binary formats …
        "com.microsoft.excel.xls",
        "com.microsoft.powerpoint.ppt",
        "org.openxmlformats.wordprocessingml.document",   // … and their OOXML successors
        "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.presentationml.presentation",
    ]

    /// Copies the archive's `com.apple.quarantine` attribute onto the files unpacked from
    /// it, as far as `quarantinePropagation` allows.
    ///
    /// Does nothing when the setting is `.never`, when the archive carries no quarantine
    /// mark (it was not downloaded), or when the extracted tree is gone. Existing marks are
    /// never overwritten: a file that already carries one may have been approved by the
    /// user already, and replacing that with the archive's copy could hand back an approval
    /// the user never gave. Symbolic links are skipped — they hold no content to vet.
    ///
    /// - Returns: how many items were newly marked, for logging and tests.
    @discardableResult
    static func propagateQuarantineIfNeeded(from archiveURL: URL, to extractedRoot: URL) -> Int {
        let mode = quarantinePropagation
        guard mode != .never else { return 0 }

        guard let mark = extendedAttribute(named: quarantineAttributeName, at: archiveURL),
              !mark.isEmpty else { return 0 }

        var marked = 0
        walk(extractedRoot) { url in
            guard let itemMode = fileMode(at: url) else { return }
            guard !isSymbolicLink(itemMode) else { return }

            let shouldMark: Bool
            switch mode {
            case .never: shouldMark = false
            case .always: shouldMark = true
            case .documentsAndExecutables: shouldMark = isQuarantineSensitive(url, mode: itemMode)
            }
            guard shouldMark else { return }

            if setExtendedAttribute(mark, named: quarantineAttributeName, at: url,
                                    overwriteExisting: false) {
                marked += 1
            }
        }
        return marked
    }

    /// Whether this item is one of the kinds that inherit the mark in
    /// `.documentsAndExecutables` mode: it carries an executable permission bit, or its
    /// type is one of `quarantineSensitiveTypeIdentifiers`.
    /// - Parameter mode: the item's `st_mode`, already read by the caller.
    static func isQuarantineSensitive(_ url: URL, mode: mode_t) -> Bool {
        if isRegularFile(mode) && (UInt32(mode) & 0o111) != 0 { return true }

        guard let type = contentType(of: url) else { return false }
        for identifier in quarantineSensitiveTypeIdentifiers {
            guard let sensitive = UTType(identifier) else { continue }
            if type == sensitive || type.conforms(to: sensitive) { return true }
        }
        return false
    }

    private static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    /// Visits `root` and, if it is a directory, everything below it. Symbolic links are
    /// handed to `body` but never followed.
    private static func walk(_ root: URL, _ body: (URL) -> Void) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }

        body(root)
        guard isDirectory.boolValue else { return }
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [], errorHandler: nil
        ) else { return }

        for case let url as URL in enumerator {
            body(url)
        }
    }

    // MARK: - Extended attribute primitives

    /// Reads an extended attribute without following symbolic links.
    /// Returns `nil` when the file has no such attribute, or is unreadable — a missing
    /// attribute is the normal case, not an error.
    static func extendedAttribute(named name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { pathPointer -> Data? in
            guard let pathPointer = pathPointer else { return nil }

            let length = getxattr(pathPointer, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { return nil }   // ENOATTR, ENOENT, EPERM …
            guard length > 0 else { return Data() }

            var buffer = Data(count: length)
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return getxattr(pathPointer, name, base, length, 0, XATTR_NOFOLLOW)
            }
            guard read >= 0 else { return nil }
            // The attribute can shrink between the sizing call and the read.
            if read < length { buffer.removeSubrange(read..<length) }
            return buffer
        }
    }

    /// Writes an extended attribute without following symbolic links.
    /// - Parameter overwriteExisting: when `false` the write uses `XATTR_CREATE`, so an
    ///   attribute already on the file is left untouched and `false` is returned.
    /// - Returns: whether the attribute was written.
    @discardableResult
    static func setExtendedAttribute(
        _ data: Data, named name: String, at url: URL, overwriteExisting: Bool
    ) -> Bool {
        let options = XATTR_NOFOLLOW | (overwriteExisting ? 0 : XATTR_CREATE)
        return url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
            guard let pathPointer = pathPointer else { return false }
            return data.withUnsafeBytes { raw -> Bool in
                setxattr(pathPointer, name, raw.baseAddress, data.count, 0, options) == 0
            }
        }
    }

    /// `st_mode` of the item itself (never of a symlink's target), or `nil` if it is gone.
    private static func fileMode(at url: URL) -> mode_t? {
        var info = stat()
        let ok = url.withUnsafeFileSystemRepresentation { pathPointer -> Bool in
            guard let pathPointer = pathPointer else { return false }
            return lstat(pathPointer, &info) == 0
        }
        return ok ? info.st_mode : nil
    }

    private static func isSymbolicLink(_ mode: mode_t) -> Bool {
        (UInt32(mode) & UInt32(S_IFMT)) == UInt32(S_IFLNK)
    }

    private static func isRegularFile(_ mode: mode_t) -> Bool {
        (UInt32(mode) & UInt32(S_IFMT)) == UInt32(S_IFREG)
    }
}
