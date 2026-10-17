import Cocoa

/// File access for the App Store build, which runs in the App Sandbox.
///
/// A sandboxed app may only touch what the user handed it: files picked in an open or
/// save panel, the Downloads folder (an entitlement), and folders it holds a
/// security-scoped bookmark for. TajArchive asks once for the home folder (in the
/// Setup Assistant) and keeps that bookmark, so day-to-day use feels like the direct
/// download version; anything outside it — an external drive, say — is asked for when
/// first needed. In the Developer ID build every call here is a no-op.
enum FolderAccess {

    private static let bookmarksKey = "SecurityScopedBookmarks"
    private static var activeURLs: [URL] = []

    /// True when running under the App Sandbox (the App Store build).
    static let isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Re-opens every folder granted in earlier sessions. Call once at launch.
    static func restore() {
        guard isSandboxed else { return }
        let stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        var keep: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if url.startAccessingSecurityScopedResource() { activeURLs.append(url) }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope],
                                                         includingResourceValuesForKeys: nil, relativeTo: nil) {
                keep.append(fresh)
            } else {
                keep.append(data)
            }
        }
        UserDefaults.standard.set(keep, forKey: bookmarksKey)
    }

    /// The real home folder (inside the sandbox `NSHomeDirectory()` is the container).
    static var homeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// "~/Desktop" against the real home folder (inside the sandbox "~" is the container).
    static func expandTilde(_ path: String) -> String {
        guard isSandboxed else { return (path as NSString).expandingTildeInPath }
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.path + String(path.dropFirst()) }
        return path
    }

    /// Downloads, Desktop or Documents of the real home folder.
    static func userFolder(_ directory: FileManager.SearchPathDirectory) -> String {
        if isSandboxed {
            let name: String
            switch directory {
            case .desktopDirectory: name = "Desktop"
            case .documentDirectory: name = "Documents"
            default: name = "Downloads"
            }
            return homeDirectory.appendingPathComponent(name).path
        }
        return FileManager.default.urls(for: directory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
    }

    static var hasHomeAccess: Bool {
        !isSandboxed || activeURLs.contains { $0.standardizedFileURL.path == homeDirectory.standardizedFileURL.path }
    }

    /// Whether `path` (a file or folder) can be read — and, with `forWriting`, changed.
    static func canAccess(_ path: String, forWriting: Bool = false) -> Bool {
        guard isSandboxed else { return true }
        var probe = path
        var isDirectory: ObjCBool = false
        // Walk up to the nearest existing item; a destination may not exist yet.
        while !FileManager.default.fileExists(atPath: probe, isDirectory: &isDirectory) {
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe || parent.isEmpty { return false }
            probe = parent
        }
        let fm = FileManager.default
        return forWriting ? fm.isWritableFile(atPath: probe) : fm.isReadableFile(atPath: probe)
    }

    /// Asks the user for `folder` through an open panel and remembers the grant.
    /// Returns true when the folder is accessible afterwards.
    @discardableResult
    @MainActor
    static func requestAccess(to folder: URL, message: String? = nil) -> Bool {
        guard isSandboxed else { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = L("Allow Access")
        panel.message = message ?? L("TajArchive needs your permission to work with files in “%@”. Click Allow Access.",
                                     FileManager.default.displayName(atPath: folder.path))
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        remember(url)
        return canAccess(folder.path)
    }

    /// The Setup Assistant's request: the whole home folder in one step.
    @discardableResult
    @MainActor
    static func requestHomeAccess() -> Bool {
        requestAccess(to: homeDirectory,
                      message: L("Select your home folder and click Allow Access, so TajArchive can open archives and save files next to them."))
    }

    /// Makes sure every path can be used; asks for the folder that holds them when not.
    @MainActor
    static func ensureAccess(to paths: [String], forWriting: Bool) -> Bool {
        guard isSandboxed else { return true }
        let missing = paths.filter { !canAccess($0, forWriting: forWriting) }
        guard let first = missing.first else { return true }
        let folder = commonFolder(of: missing) ?? (first as NSString).deletingLastPathComponent
        return requestAccess(to: URL(fileURLWithPath: folder, isDirectory: true))
            && missing.allSatisfy { canAccess($0, forWriting: forWriting) }
    }

    private static func remember(_ url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope],
                                               includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        var stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        stored.append(data)
        UserDefaults.standard.set(stored, forKey: bookmarksKey)
        if url.startAccessingSecurityScopedResource() { activeURLs.append(url) }
    }

    private static func commonFolder(of paths: [String]) -> String? {
        var components = (paths.first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
            .split(separator: "/").map(String.init)
        for path in paths.dropFirst() {
            let other = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            var shared = 0
            while shared < min(components.count, other.count) && components[shared] == other[shared] { shared += 1 }
            components = Array(components.prefix(shared))
        }
        return components.isEmpty ? nil : "/" + components.joined(separator: "/")
    }
}
