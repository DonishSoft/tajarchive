import Cocoa
import os.log

/// A utility to log all application actions and errors to a file and console.
class AppLogger {
    static let shared = AppLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.donishsoft.tajarchive.logger")

    private init() {
        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logsDir = appSupportDir.appendingPathComponent("TajArchive/Logs")

        do {
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create logs directory: \(error)")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())

        fileURL = logsDir.appendingPathComponent("app-\(dateString).log")

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        }

        log(message: "--- App Session Started ---")
    }

    func log(message: String, level: OSLogType = .default) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())

        let logString = "[\(timestamp)] [\(levelName(level))] \(message)\n"

        let customLog = OSLog(subsystem: "com.donishsoft.tajarchive", category: "Application")
        os_log("%{public}@", log: customLog, type: level, logString)

        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                let fileHandle = try FileHandle(forWritingTo: self.fileURL)
                fileHandle.seekToEndOfFile()
                if let data = logString.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } catch {
                print("Failed to write to log file: \(error)")
            }
        }
    }

    private func levelName(_ level: OSLogType) -> String {
        switch level {
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "DEFAULT"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?
    /// Extra windows opened for additional archives (multi-open from Finder)
    var extraWindowControllers: [MainWindowController] = []
    var aboutWindowController: AboutWindowController?
    var preferencesWindowController: PreferencesWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Must exist before finishLaunching or the app has no menu bar at all
        NSApp.mainMenu = MainMenuBuilder.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.shared.log(message: "🚀 applicationDidFinishLaunching called", level: .info)

        restoreTheme()
        FolderAccess.restore()

        // A copy running from the disk image offers to install itself first.
        if AppMover.offerToMoveIfNeeded() { return }
        LegacyInstallCleanup.offerIfNeeded()

        if mainWindowController == nil {
            mainWindowController = MainWindowController()
            mainWindowController?.showWindow(self)
        }

        NSApp.activate(ignoringOtherApps: true)

        if SetupAssistantController.shouldShowAutomatically() {
            // Let the main window settle so the assistant opens on top of it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSetupAssistant()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainWindowController.cleanPreviewCache()
    }

    // MARK: - Setup assistant

    private var setupAssistant: SetupAssistantController?

    /// Finder menu, default app for archives and Quick Look in one window.
    @objc func showSetupAssistant() {
        if setupAssistant == nil {
            setupAssistant = SetupAssistantController()
        }
        setupAssistant?.showWindow(self)
    }

    // MARK: - Menu Actions

    @objc func showAbout() {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(self)
        aboutWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(self)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Project page and support address come from Info.plist (TAJWebsiteURL,
    /// TAJSupportEmail) so a fork or a later release can set them without code changes;
    /// the menu items stay hidden while they are empty.
    static var websiteURL: URL? {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "TAJWebsiteURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
    }

    static var supportEmail: String? {
        guard let email = Bundle.main.object(forInfoDictionaryKey: "TAJSupportEmail") as? String,
              email.contains("@") else { return nil }
        return email
    }

    /// Where "Support TajArchive…" leads (Info.plist TAJDonateURL). Only the disk-image
    /// build shows it: the App Store does not allow links to outside payments.
    static var donateURL: URL? {
        #if APPSTORE
        return nil
        #else
        guard let string = Bundle.main.object(forInfoDictionaryKey: "TAJDonateURL") as? String,
              !string.isEmpty else { return nil }
        return URL(string: string)
        #endif
    }

    @objc func openDonate() {
        if let url = Self.donateURL { NSWorkspace.shared.open(url) }
    }

    @objc func openWebsite() {
        if let url = Self.websiteURL { NSWorkspace.shared.open(url) }
    }

    @objc func contactSupport() {
        guard let email = Self.supportEmail else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TajArchive \(version)"),
            URLQueryItem(name: "body", value: "\n\n—\nTajArchive \(version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc func open7ZipWebsite() {
        if let url = URL(string: "https://www.7-zip.org/") { NSWorkspace.shared.open(url) }
    }

    @objc func showLogFolder() {
        let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TajArchive/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

    private func restoreTheme() {
        let theme = UserDefaults.standard.string(forKey: "appTheme") ?? "system"
        switch theme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - URL / File Opening

    private func isArchiveURL(_ url: URL) -> Bool {
        ArchiveTypes.isArchive(url: url)
    }

    private func ensureMainWindow() -> MainWindowController {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
            mainWindowController?.showWindow(self)
        }
        return mainWindowController!
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppLogger.shared.log(message: "Received request to open \(urls.count) URLs from System/Finder", level: .info)

        let main = ensureMainWindow()

        // Custom URL scheme from the Finder extension
        if let schemeURL = urls.first, schemeURL.scheme == "tajarchive" {
            guard let host = schemeURL.host,
                  let components = URLComponents(url: schemeURL, resolvingAgainstBaseURL: false),
                  let pathsItem = components.queryItems?.first(where: { $0.name == "paths" }),
                  let base64String = pathsItem.value,
                  let jsonData = Data(base64Encoded: base64String),
                  let paths = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String] else { return }

            let algo = components.queryItems?.first(where: { $0.name == "algo" })?.value

            AppLogger.shared.log(message: "Received tajarchive://\(host) scheme for \(paths.count) files", level: .info)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                main.handleFinderExtensionAction(action: host, paths: paths, algorithm: algo)
            }
            return
        }

        let archives = urls.filter { isArchiveURL($0) }
        let directories = urls.filter { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue && !isArchiveURL(url)
        }
        let plainFiles = urls.filter { !isArchiveURL($0) && !directories.contains($0) }

        if !archives.isEmpty && plainFiles.isEmpty {
            // The user opened archives with their default app: OPEN them, never compress.
            main.openArchive(at: archives[0].path)
            for extra in archives.dropFirst() {
                let controller = MainWindowController()
                extraWindowControllers.append(controller)
                controller.showWindow(self)
                controller.openArchive(at: extra.path)
            }
            for dir in directories {
                main.loadDirectory(at: dir.path)
            }
            return
        }

        if urls.count == 1, let only = urls.first {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir)
            if isDir.boolValue {
                main.loadDirectory(at: only.path)
            } else {
                // "Open With → TajArchive" on any file means "show me what is inside":
                // 7-Zip reads many container formats (.docx, .jar, .apk, .epub, .exe)
                // that are not listed as archives. Handing the file back to the
                // workspace instead could loop if TajArchive were its default app.
                main.openArchive(at: only.path)
            }
            return
        }

        // Mixed selection of plain files/folders: explicit compress intent from the extension
        let paths = urls.map { $0.path }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            main.showCompressSheet(for: paths)
        }
    }
}
