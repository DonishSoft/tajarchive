import Cocoa
import FinderSync
import UserNotifications

/// Menu titles come from this extension's own Localizable.strings.
private func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
private func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}

class FinderSync: FIFinderSync {

    // Archive file extensions — keep in sync with ArchiveTypes.openableExtensions in the app.
    static let archiveExtensions: Set<String> = [
        "taj", "7z", "zip", "zipx", "rar", "r00", "001",
        "tar", "gz", "gzip", "tgz", "tpz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "lzma", "z", "taz",
        "zst", "zstd", "tzst", "lz4", "tlz4", "aar", "yaa",
        "cab", "arj", "lzh", "lha", "wim", "swm", "esd", "cpio", "rpm", "deb", "xar", "msi", "chm",
        "iso", "dmg", "vhd", "vhdx", "vmdk", "qcow2", "squashfs", "cramfs"
    ]

    // Hash algorithms shown in the "CRC SHA" submenu.
    // Menu item tags index into this array (representedObject does not
    // survive the FinderSync menu serialization, tags do).
    static let hashAlgorithms: [(title: String, algo: String)] = [
        ("CRC-32", "CRC32"),
        ("CRC-64", "CRC64"),
        ("SHA-1", "SHA1"),
        ("SHA-256", "SHA256"),
        ("SHA-512", "SHA512"),
        ("BLAKE2sp", "BLAKE2sp"),
        ("*", "ALL")
    ]

    private var volumeObservers: [NSObjectProtocol] = []

    override init() {
        super.init()

        NSLog("TajArchive FinderSync: Initializing...")

        // Monitor the root volume plus every mounted (visible) volume.
        refreshDirectoryURLs()

        // Refresh coverage whenever volumes come and go.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshDirectoryURLs()
            }
            volumeObservers.append(observer)
        }

        NSLog("TajArchive FinderSync: Ready")
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers {
            center.removeObserver(observer)
        }
    }

    private func refreshDirectoryURLs() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        if let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            urls.formUnion(volumes)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - Menu Construction

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let controller = FIFinderSyncController.default()

        // Selection, or the targeted folder when right-clicking the folder
        // background with nothing selected.
        let items: [URL]
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            items = selected
        } else if let target = controller.targetedURL() {
            items = [target]
        } else {
            // Nothing to act on - no dead root item.
            return NSMenu()
        }

        // macOS requires the returned menu to contain the root items.
        // We create one root item "TajArchive" and give it a submenu.
        let rootMenu = NSMenu(title: "")
        let rootItem = NSMenuItem(title: "TajArchive", action: nil, keyEquivalent: "")

        // The app's own icon, at menu size
        if let appURL = getMainAppURL() {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            rootItem.image = icon
        }

        let subMenu = NSMenu(title: "TajArchive")
        rootItem.submenu = subMenu
        rootMenu.addItem(rootItem)

        // Check if selected items are archives or regular files/folders
        let hasArchives = items.contains { isArchive(url: $0) }
        let hasNonArchives = items.contains { !isArchive(url: $0) }

        if hasNonArchives {
            // ===== Compression Menu (for files/folders) =====
            buildCompressionMenu(menu: subMenu, items: items)
        }

        if hasArchives {
            if hasNonArchives {
                subMenu.addItem(NSMenuItem.separator())
            }
            // ===== Extraction Menu (for archives) =====
            buildExtractionMenu(menu: subMenu, items: items)
        }

        // ===== CRC SHA submenu (any selection) =====
        subMenu.addItem(NSMenuItem.separator())
        buildHashMenu(menu: subMenu)

        return rootMenu
    }

    // MARK: - Compression Menu

    private func buildCompressionMenu(menu: NSMenu, items: [URL]) {
        let archiveName = getArchiveName(from: items)

        // 1. Add to archive... (opens dialog)
        let addToArchiveItem = NSMenuItem(
            title: L("Add to Archive…"),
            action: #selector(addToArchiveAction(_:)),
            keyEquivalent: ""
        )
        addToArchiveItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        addToArchiveItem.target = self
        menu.addItem(addToArchiveItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Add to "archiveName.7z"
        let compressTo7zItem = NSMenuItem(
            title: L("Add to “%@”", archiveName + ".7z"),
            action: #selector(compressTo7zAction(_:)),
            keyEquivalent: ""
        )
        compressTo7zItem.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        compressTo7zItem.target = self
        menu.addItem(compressTo7zItem)

        // 3. Add to "archiveName.zip"
        let compressToZipItem = NSMenuItem(
            title: L("Add to “%@”", archiveName + ".zip"),
            action: #selector(compressToZipAction(_:)),
            keyEquivalent: ""
        )
        compressToZipItem.image = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        compressToZipItem.target = self
        menu.addItem(compressToZipItem)

        // 4. Add to "archiveName.taj" (TajCompress)
        let compressToTajItem = NSMenuItem(
            title: L("Add to “%@” (Adaptive)", archiveName + ".taj"),
            action: #selector(compressToTajAction(_:)),
            keyEquivalent: ""
        )
        compressToTajItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        compressToTajItem.target = self
        menu.addItem(compressToTajItem)
    }

    // MARK: - Extraction Menu

    private func buildExtractionMenu(menu: NSMenu, items: [URL]) {
        let archives = items.filter { isArchive(url: $0) }

        // 1. Open archive (in 7-Zip app)
        let openItem = NSMenuItem(
            title: L("Open Archive"),
            action: #selector(openArchiveAction(_:)),
            keyEquivalent: ""
        )
        openItem.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Extract files... (choose destination)
        let extractToItem = NSMenuItem(
            title: L("Extract Files…"),
            action: #selector(extractToAction(_:)),
            keyEquivalent: ""
        )
        extractToItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        extractToItem.target = self
        menu.addItem(extractToItem)

        // 3. Extract Here
        let extractHereItem = NSMenuItem(
            title: L("Extract Here"),
            action: #selector(extractHereAction(_:)),
            keyEquivalent: ""
        )
        extractHereItem.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        extractHereItem.target = self
        menu.addItem(extractHereItem)

        // 4. Extract to "folderName/"
        // For multiple archives each one extracts into its own folder,
        // so mirror 7-Zip's honest "*/" label.
        let extractToFolderTitle: String
        if archives.count == 1, let onlyArchive = archives.first {
            extractToFolderTitle = L("Extract to “%@”", onlyArchive.deletingPathExtension().lastPathComponent + "/")
        } else {
            extractToFolderTitle = L("Extract to “%@”", "*/")
        }
        let extractToFolderItem = NSMenuItem(
            title: extractToFolderTitle,
            action: #selector(extractToFolderAction(_:)),
            keyEquivalent: ""
        )
        extractToFolderItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        extractToFolderItem.target = self
        menu.addItem(extractToFolderItem)

        menu.addItem(NSMenuItem.separator())

        // 5. Test archive
        let testItem = NSMenuItem(
            title: L("Test Archive"),
            action: #selector(testArchiveAction(_:)),
            keyEquivalent: ""
        )
        testItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        testItem.target = self
        menu.addItem(testItem)
    }

    // MARK: - Hash Menu

    private func buildHashMenu(menu: NSMenu) {
        let hashItem = NSMenuItem(title: "CRC SHA", action: nil, keyEquivalent: "")
        hashItem.image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)

        let hashMenu = NSMenu(title: "CRC SHA")
        for (index, algorithm) in FinderSync.hashAlgorithms.enumerated() {
            let item = NSMenuItem(
                title: algorithm.title,
                action: #selector(hashAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            hashMenu.addItem(item)
        }

        hashItem.submenu = hashMenu
        menu.addItem(hashItem)
    }

    // MARK: - Helpers

    private func isArchive(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return FinderSync.archiveExtensions.contains(ext)
    }

    private func getArchiveName(from items: [URL]) -> String {
        if items.count == 1 {
            // Single item - use its name
            return items[0].deletingPathExtension().lastPathComponent
        } else {
            // Multiple items - use parent folder name
            if let firstItem = items.first {
                return firstItem.deletingLastPathComponent().lastPathComponent
            }
            return "archive"
        }
    }

    // MARK: - Compression Actions

    @IBAction func addToArchiveAction(_ sender: AnyObject?) {
        NSLog("TajArchive: addToArchiveAction triggered")
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "compress", urls: urls)
    }

    private func getSelectedURLs() -> [URL]? {
        let items = FIFinderSyncController.default().selectedItemURLs()
        if items == nil || items!.isEmpty {
            NSLog("TajArchive: No URLs found in FinderSync Controller")

            // Fallback for right click on empty space (targets the directory itself)
            if let target = FIFinderSyncController.default().targetedURL() {
                return [target]
            }
            return nil
        }
        return items
    }

    private func sendToMainApp(action: String, urls: [URL], extraQueryItems: [(name: String, value: String)] = []) {
        NSLog("TajArchive: sendToMainApp called with action: \(action), URLs count: \(urls.count)")
        let paths = urls.map { $0.path }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: paths) else {
            NSLog("TajArchive: Failed to serialize paths to JSON")
            showNotification(title: L("TajArchive could not be opened"), message: L("The selected items could not be passed to the app."))
            return
        }

        let base64Paths = jsonData.base64EncodedString()
        var queryParts = extraQueryItems.map { "\($0.name)=\($0.value)" }
        queryParts.append("paths=\(base64Paths)")
        let urlString = "tajarchive://\(action)?" + queryParts.joined(separator: "&")
        NSLog("TajArchive: Constructed URL scheme: \(urlString)")

        if let schemeURL = URL(string: urlString), let appURL = getMainAppURL() {
            NSLog("TajArchive: Attempting to launch main app via NSWorkspace at \(appURL.path)")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            NSWorkspace.shared.open([schemeURL], withApplicationAt: appURL, configuration: config) { (app, error) in
                if let error = error {
                    NSLog("TajArchive: NSWorkspace Launch Error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.showNotification(title: L("TajArchive could not be opened"), message: error.localizedDescription)
                    }
                } else {
                    NSLog("TajArchive: NSWorkspace successfully dispatched to main app")
                }
            }
        } else {
            NSLog("TajArchive: Failed to create scheme URL or locate main App URL")
            showNotification(title: L("TajArchive could not be opened"), message: L("The app was not found next to its Finder extension. Reinstall TajArchive."))
        }
    }

    @IBAction func compressTo7zAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "compressTo7z", urls: urls)
    }

    @IBAction func compressToZipAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "compressToZip", urls: urls)
    }

    @IBAction func compressToTajAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "compressToTaj", urls: urls)
    }

    // MARK: - Extraction Actions

    @IBAction func openArchiveAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "open", urls: urls)
    }

    @IBAction func extractHereAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "extractHere", urls: urls)
    }

    @IBAction func extractToFolderAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "extractToFolder", urls: urls)
    }

    @IBAction func extractToAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "extractTo", urls: urls)
    }

    @IBAction func testArchiveAction(_ sender: AnyObject?) {
        guard let urls = getSelectedURLs() else { return }
        sendToMainApp(action: "test", urls: urls)
    }

    // MARK: - Hash Action

    @IBAction func hashAction(_ sender: AnyObject?) {
        guard let item = sender as? NSMenuItem,
              item.tag >= 0, item.tag < FinderSync.hashAlgorithms.count else {
            NSLog("TajArchive: hashAction triggered with unknown algorithm tag")
            return
        }
        guard let urls = getSelectedURLs() else { return }
        let algo = FinderSync.hashAlgorithms[item.tag].algo
        sendToMainApp(action: "hash", urls: urls, extraQueryItems: [(name: "algo", value: algo)])
    }

    // MARK: - Utilities

    private func getMainAppURL() -> URL? {
        // Extension is inside: TajArchive.app/Contents/PlugIns/FinderExtension.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // TajArchive.app

        if appURL.pathExtension == "app" {
            return appURL
        }
        return nil
    }

    // MARK: - Notifications

    private static let didRequestNotificationAuthKey = "DidRequestNotificationAuthorization"

    private func showNotification(title: String, message: String) {
        let center = UNUserNotificationCenter.current()

        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error = error {
                    NSLog("TajArchive: Failed to deliver notification: \(error.localizedDescription)")
                }
            }
        }

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: FinderSync.didRequestNotificationAuthKey) {
            // First time: request authorization, then deliver if granted.
            defaults.set(true, forKey: FinderSync.didRequestNotificationAuthKey)
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    NSLog("TajArchive: Notification authorization error: \(error.localizedDescription)")
                }
                if granted {
                    deliver()
                } else {
                    NSLog("TajArchive: Notifications not authorized. \(title): \(message)")
                }
            }
        } else {
            center.getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    deliver()
                default:
                    NSLog("TajArchive: Notifications not authorized. \(title): \(message)")
                }
            }
        }
    }
}
