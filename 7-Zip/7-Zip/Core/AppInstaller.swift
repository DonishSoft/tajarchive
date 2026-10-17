import Cocoa
import FinderSync
import UniformTypeIdentifiers

// MARK: - Move to Applications

/// Offers to move the app into /Applications when it is launched from somewhere else —
/// typically straight from the downloaded disk image, where macOS runs it from a
/// read-only, randomised "translocation" path. Extensions (Finder menu, Quick Look)
/// only register reliably for a copy that stays put, so this matters more than it looks.
enum AppMover {

    private static let suppressKey = "SuppressMoveToApplications"

    /// Returns true when the app is about to quit because a moved copy is being launched.
    @discardableResult
    static func offerToMoveIfNeeded() -> Bool {
        #if DEBUG || APPSTORE
        return false   // the App Store installs into Applications by itself
        #else
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard !isInApplicationsFolder(bundleURL),
              !UserDefaults.standard.bool(forKey: suppressKey) else { return false }

        let alert = NSAlert()
        alert.messageText = L("Move TajArchive to the Applications folder?")
        alert.informativeText = L("TajArchive works best from the Applications folder: the Finder menu and Quick Look previews only stay registered there. The copy you opened now will be left as it is.")
        alert.addButton(withTitle: L("Move to Applications"))
        alert.addButton(withTitle: L("Not Now"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Don't ask again")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let destination = try install(from: bundleURL)
            relaunch(at: destination, ejectingVolumeOf: bundleURL)
            return true
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = L("Could not move TajArchive")
            failure.informativeText = error.localizedDescription + "\n\n"
                + L("Drag TajArchive into the Applications folder in Finder instead.")
            failure.runModal()
            return false
        }
        #endif
    }

    static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.path
        let roots = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return roots.contains { path.hasPrefix($0) }
    }

    /// Copies the bundle into /Applications (or ~/Applications when the system folder is
    /// not writable), sending any copy already there to the Trash first.
    private static func install(from source: URL) throws -> URL {
        let fileManager = FileManager.default
        let systemFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder: URL
        if fileManager.isWritableFile(atPath: systemFolder.path) {
            folder = systemFolder
        } else {
            folder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let destination = folder.appendingPathComponent("TajArchive.app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .first(where: { $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }) {
                running.terminate()
            }
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Launches the installed copy once this process has exited, then — if the app was
    /// started from a read-only disk image — ejects that image, as drag-installing would.
    private static func relaunch(at destination: URL, ejectingVolumeOf source: URL) {
        var volumeToEject = ""
        if let values = try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey]),
           values.volumeIsReadOnly == true,
           let volume = values.volume, volume.path != "/", volume.path.hasPrefix("/Volumes/") {
            volumeToEject = volume.path
        }

        AppRelauncher.relaunch(at: destination, thenEject: volumeToEject)
    }
}

/// Quits and starts the app at `url` once this process is gone. Opening the bundle of a
/// running app only re-activates it, so the new launch has to wait for the exit.
enum AppRelauncher {
    static func relaunch(at url: URL, thenEject volume: String = "") {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then /usr/bin/hdiutil detach -quiet "$3" || true; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh",
                             String(ProcessInfo.processInfo.processIdentifier),
                             url.path, volume]
        try? process.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Earlier builds

/// Before it was renamed, this app shipped as "7-Zip.app" (bundle id com.donishsoft.7zip).
/// A leftover copy registers a second Finder extension and Quick Look plug-in with the
/// same menu, so the user sees doubled or stale items. This finds such copies and offers
/// to move them to the Trash.
enum LegacyInstallCleanup {

    private static let legacyBundleIdentifier = "com.donishsoft.7zip"
    private static let suppressKey = "SuppressLegacyCleanup"

    static func legacyCopies() -> [URL] {
        let candidates = [
            URL(fileURLWithPath: "/Applications/7-Zip.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/7-Zip.app")
        ]
        return candidates.filter { Bundle(url: $0)?.bundleIdentifier == legacyBundleIdentifier }
    }

    static func offerIfNeeded() {
        #if APPSTORE
        return   // a sandboxed app may not touch other apps
        #else
        guard !UserDefaults.standard.bool(forKey: suppressKey) else { return }
        let copies = legacyCopies()
        guard !copies.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = L("An older build of this app is still installed")
        alert.informativeText = L("“%@” is an earlier version of TajArchive. It adds a second, outdated menu to Finder. Move it to the Trash?",
                                  copies.map { $0.path }.joined(separator: ", "))
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Keep"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: suppressKey)
            return
        }
        NSWorkspace.shared.recycle(copies) { _, error in
            if let error = error {
                AppLogger.shared.log(message: "Legacy cleanup failed: \(error.localizedDescription)", level: .error)
            }
        }
        #endif
    }
}

// MARK: - Finder extension

/// The Finder context menu lives in an app extension that macOS keeps switched off until
/// the user turns it on. Turning it on here does exactly what the checkbox in
/// System Settings does, and is only ever triggered by the user's click.
enum FinderExtensionControl {

    static let bundleIdentifier = "com.donishsoft.tajarchive.FinderExtension"

    static var isEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func enable(completion: @escaping (Bool) -> Void) {
        #if APPSTORE
        // A sandboxed app cannot run pluginkit: System Settings is the way in.
        openSystemSettings()
        completion(isEnabled)
        #else
        DispatchQueue.global(qos: .userInitiated).async {
            if let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderExtension.appex"),
               FileManager.default.fileExists(atPath: appex.path) {
                run("/usr/bin/pluginkit", ["-a", appex.path])
            }
            run("/usr/bin/pluginkit", ["-e", "use", "-i", bundleIdentifier])

            // pluginkit returns before Finder notices; give it a few seconds.
            var enabled = false
            for _ in 0..<20 {
                enabled = DispatchQueue.main.sync { FIFinderSyncController.isExtensionEnabled }
                if enabled { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async { completion(enabled) }
        }
        #endif
    }

    static func openSystemSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

// MARK: - Default app for archives

/// Makes TajArchive the app that opens archive formats on double-click. Formats macOS
/// already opens itself (ZIP, TAR, GZip, disk images) are left alone unless the user
/// picks them in Settings → File Associations.
enum DefaultArchiveApp {

    static let recommendedTypes: [String] = [
        "com.donishsoft.taj-archive",
        "org.7-zip.7-zip-archive",
        "com.rarlab.rar-archive",
        "com.donishsoft.split-archive-volume",
        "com.facebook.zstandard-archive",
        "org.lz4.lz4-archive",
        "com.microsoft.cab",
        "com.microsoft.windows-imaging-format",
        "cx.c3.arj-archive",
        "cx.c3.lha-archive",
    ]

    /// The copy that should own the associations: the installed one when it exists.
    static var applicationURL: URL {
        let running = Bundle.main.bundleURL
        if AppMover.isInApplicationsFolder(running) { return running }
        let installed = URL(fileURLWithPath: "/Applications/TajArchive.app")
        if Bundle(url: installed)?.bundleIdentifier == Bundle.main.bundleIdentifier { return installed }
        return running
    }

    static var isDefaultForRecommendedTypes: Bool {
        let own = (Bundle.main.bundleIdentifier ?? "").lowercased()
        return recommendedTypes.prefix(3).allSatisfy { identifier in
            guard let type = UTType(identifier),
                  let handler = NSWorkspace.shared.urlForApplication(toOpen: type),
                  let handlerID = Bundle(url: handler)?.bundleIdentifier else { return false }
            return handlerID.lowercased() == own
        }
    }

    static func claimRecommendedTypes() async -> Int {
        let appURL = applicationURL
        var claimed = 0
        for identifier in recommendedTypes {
            guard let type = UTType(identifier) else { continue }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
                claimed += 1
            } catch {
                AppLogger.shared.log(message: "Could not claim \(identifier): \(error.localizedDescription)", level: .error)
            }
        }
        return claimed
    }
}
