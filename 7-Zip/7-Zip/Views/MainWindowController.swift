import Cocoa
import UniformTypeIdentifiers

/// Hosts one or two browser panes and owns every operation that needs window-level
/// UI: dialogs, sheets, progress windows, and transfers between the two panes.
class MainWindowController: NSWindowController {

    // MARK: - Panes

    private var leftPane: BrowserPaneController!
    private var rightPane: BrowserPaneController?
    private var splitView: NSSplitView!
    private var activePane: BrowserPaneController!

    /// The pane a Copy/Move defaults to — the other one, when two are open.
    private var oppositePane: BrowserPaneController? {
        guard let right = rightPane else { return nil }
        return activePane === leftPane ? right : leftPane
    }

    private(set) var isDualPane = false

    private var searchField: NSSearchField!
    private var activeSheet: NSWindowController?
    private var hashWindows: [HashResultsWindowController] = []
    private var infoWindows: [InfoPanelController] = []

    private static let lastFolderKey = "LastFolder"

    /// Where a new window opens: the last folder browsed (like 7-Zip), else Downloads.
    private static var startPath: String {
        if let last = UserDefaults.standard.string(forKey: lastFolderKey) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: last, isDirectory: &isDirectory), isDirectory.boolValue {
                return last
            }
        }
        return FolderAccess.userFolder(.downloadsDirectory)
    }

    // MARK: - Initialization

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("TajArchive")
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        self.init(window: window)
        setupUI()
        // Remember size and position between launches; extra windows cascade from it.
        window.setFrameAutosaveName("MainWindow")
        window.initialFirstResponder = leftPane.listResponder
    }

    private func setupUI() {
        guard let window = window else { return }

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        leftPane = makePane()
        splitView.addArrangedSubview(leftPane.view)
        activePane = leftPane
        leftPane.isActive = true

        let container = NSView()
        container.addSubview(splitView)
        window.contentView = container

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if UserDefaults.standard.bool(forKey: "DualPaneEnabled") {
            setDualPane(true)
        }
    }

    private func makePane() -> BrowserPaneController {
        let pane = BrowserPaneController(startPath: Self.startPath)
        pane.delegate = self
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        pane.setContextMenu(buildContextMenu())
        return pane
    }

    /// Marks context-menu items that only make sense for files on disk.
    private static let filesystemOnlyTag = 7001

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, filesystemOnly: Bool = false) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if filesystemOnly { item.tag = Self.filesystemOnlyTag }
        }
        add(L("Open"), #selector(contextOpen))
        add(L("Open as Archive"), #selector(contextOpenInside), filesystemOnly: true)
        add(L("Show in Finder"), #selector(contextShowInFinder), filesystemOnly: true)
        menu.addItem(.separator())
        add(L("Add to Archive…"), #selector(contextAddToArchive), filesystemOnly: true)
        add(L("Extract…"), #selector(extractAction(_:)))
        add(L("Test Archive"), #selector(testAction(_:)))
        menu.addItem(.separator())
        add(L("Copy To…"), #selector(copyToOtherPaneAction(_:)))
        add(L("Move To…"), #selector(moveToOtherPaneAction(_:)))
        add(L("Rename…"), #selector(renameAction(_:)))
        add(L("Delete"), #selector(deleteAction(_:)))
        menu.addItem(.separator())

        let hashItem = NSMenuItem(title: L("Checksum"), action: nil, keyEquivalent: "")
        let hashMenu = NSMenu()
        for (index, algo) in HashAlgorithm.allCases.enumerated() {
            let sub = hashMenu.addItem(withTitle: algo.rawValue, action: #selector(hashSelectedAction(_:)), keyEquivalent: "")
            sub.tag = index
            sub.target = self
        }
        let all = hashMenu.addItem(withTitle: L("All at once (*)"), action: #selector(hashSelectedAction(_:)), keyEquivalent: "")
        all.tag = 999
        all.target = self
        hashItem.submenu = hashMenu
        menu.addItem(hashItem)

        add(L("Info"), #selector(infoAction(_:)))
        menu.addItem(.separator())
        add(L("Share…"), #selector(contextShare), filesystemOnly: true)
        add(L("Copy Path"), #selector(contextCopyPath))
        return menu
    }

    // MARK: - Dual pane

    @objc func toggleDualPaneAction(_ sender: Any?) {
        setDualPane(!isDualPane)
    }

    func setDualPane(_ enabled: Bool) {
        guard enabled != isDualPane else { return }
        isDualPane = enabled
        UserDefaults.standard.set(enabled, forKey: "DualPaneEnabled")

        if enabled {
            let pane = makePane()
            rightPane = pane
            splitView.addArrangedSubview(pane.view)
            if let window = window {
                splitView.setPosition(window.frame.width / 2, ofDividerAt: 0)
            }
        } else {
            if let right = rightPane {
                if activePane === right { setActivePane(leftPane) }
                splitView.removeArrangedSubview(right.view)
                right.view.removeFromSuperview()
            }
            rightPane = nil
        }
        updateWindowTitle()
        AppLogger.shared.log(
            message: "🪟 Dual pane \(enabled ? "ON" : "OFF") — panes in split view: \(splitView.arrangedSubviews.count), right pane: \(rightPane == nil ? "nil" : "present")",
            level: .info
        )
    }

    @objc func switchPaneAction(_ sender: Any?) {
        guard let other = oppositePane else { return }
        setActivePane(other)
        other.focusList()
    }

    private func setActivePane(_ pane: BrowserPaneController) {
        guard activePane !== pane else { return }
        activePane.isActive = false
        activePane = pane
        pane.isActive = true
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        window?.title = L("TajArchive — ") + activePane.displayTitle
    }

    // MARK: - Entry points used by AppDelegate

    func loadDirectory(at path: String) {
        activePane.loadDirectory(at: path)
    }

    func openArchive(at path: String, password: String? = nil) {
        activePane.openArchive(at: path, password: password)
    }

    // MARK: - Menu / toolbar actions

    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = SevenZipWrapper.supportedArchiveTypes + [.folder]
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                activePane.loadDirectory(at: url.path)
            } else {
                activePane.openArchive(at: url.path)
            }
        }
    }

    @objc func newArchiveAction(_ sender: Any?) {
        showCompressSheet()
    }

    @objc func extractAction(_ sender: Any?) {
        extractFromArchive()
    }

    @objc func testAction(_ sender: Any?) {
        if let archivePath = activePane.archivePath {
            runArchiveTests(paths: [archivePath])
        } else {
            let selected = activePane.selectedFilesystemPaths.filter { activePane.isArchive(path: $0) }
            guard !selected.isEmpty else {
                activePane.updateStatus(L("Select an archive to test"))
                return
            }
            runArchiveTests(paths: selected)
        }
    }

    @objc func infoAction(_ sender: Any?) {
        showInfo()
    }

    @objc func renameAction(_ sender: Any?) {
        renameSelected()
    }

    @objc func deleteAction(_ sender: Any?) {
        deleteSelected()
    }

    @objc func refreshAction(_ sender: Any?) {
        activePane.reload()
    }

    @objc func goBack() { activePane.goBack() }
    @objc func goForward() { activePane.goForward() }
    @objc func goUp() { activePane.goUp() }

    // Go menu: the standard folders, as in Finder.
    @objc func goHome(_ sender: Any?) { goToStandardFolder(nil) }
    @objc func goDesktop(_ sender: Any?) { goToStandardFolder(.desktopDirectory) }
    @objc func goDocuments(_ sender: Any?) { goToStandardFolder(.documentDirectory) }
    @objc func goDownloads(_ sender: Any?) { goToStandardFolder(.downloadsDirectory) }
    @objc func goApplications(_ sender: Any?) { activePane.loadDirectory(at: "/Applications") }

    /// Puts the cursor in the address bar, ready for a typed path.
    @objc func goToFolder(_ sender: Any?) { activePane.focusPathField() }

    private func goToStandardFolder(_ directory: FileManager.SearchPathDirectory?) {
        let path = directory.map { FolderAccess.userFolder($0) } ?? FolderAccess.homeDirectory.path
        activePane.loadDirectory(at: path)
        activePane.focusList()
    }

    @objc func toggleFlatViewAction(_ sender: Any?) {
        activePane.setFlatView(!activePane.isFlatView)
        if let item = sender as? NSMenuItem {
            item.state = activePane.isFlatView ? .on : .off
        }
    }

    @objc func addFavoriteAction(_ sender: Any?) {
        let path = activePane.archivePath ?? activePane.currentPath
        var favorites = UserDefaults.standard.stringArray(forKey: "Favorites") ?? []
        guard !favorites.contains(path) else {
            activePane.updateStatus(L("Already in favorites"))
            return
        }
        favorites.append(path)
        if favorites.count > 9 { favorites.removeFirst() }
        UserDefaults.standard.set(favorites, forKey: "Favorites")
        MainMenuBuilder.rebuildFavoritesMenu()
        activePane.updateStatus(L("Added to favorites"))
    }

    @objc func openFavoriteAction(_ sender: NSMenuItem) {
        let favorites = UserDefaults.standard.stringArray(forKey: "Favorites") ?? []
        guard sender.tag >= 0, sender.tag < favorites.count else { return }
        let path = favorites[sender.tag]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            showSimpleAlert(title: L("Not found"), text: L("%@\n\nThe favorite no longer exists.", path))
            return
        }
        if isDir.boolValue {
            activePane.loadDirectory(at: path)
        } else {
            activePane.openArchive(at: path)
        }
    }

    @objc func hashSelectedAction(_ sender: NSMenuItem) {
        let algorithms: [HashAlgorithm]
        if sender.tag == 999 {
            algorithms = HashAlgorithm.allCases
        } else if sender.tag >= 0 && sender.tag < HashAlgorithm.allCases.count {
            algorithms = [HashAlgorithm.allCases[sender.tag]]
        } else {
            return
        }

        guard !activePane.isInsideArchive else {
            activePane.updateStatus(L("Checksums work on filesystem files — extract first"))
            return
        }
        let paths = activePane.selectedFilesystemPaths
        guard !paths.isEmpty else {
            activePane.updateStatus(L("Select files to checksum"))
            return
        }
        runHash(paths: paths, algorithms: algorithms)
    }

    @objc func benchmarkAction(_ sender: Any?) {
        BenchmarkWindowController.presentBenchmark()
    }

    @objc func selectByMaskAction(_ sender: Any?) { presentMaskDialog(action: .select) }
    @objc func deselectByMaskAction(_ sender: Any?) { presentMaskDialog(action: .deselect) }

    private func presentMaskDialog(action: SelectionMaskAction) {
        guard let window = window else { return }
        SelectByMaskController.present(on: window, action: action) { [weak self] pattern in
            guard let self = self, let pattern = pattern else { return }
            let count = self.activePane.applySelectionMask(pattern, select: action == .select)
            self.activePane.updateStatus(action == .select
                ? L("Selected %d matching %@", count, pattern)
                : L("Deselected %d matching %@", count, pattern))
        }
    }

    @objc func newFolderInArchiveAction(_ sender: Any?) {
        guard let window = window else { return }
        guard let archivePath = activePane.archivePath else {
            showSimpleAlert(title: L("Open an archive first"),
                            text: L("This command creates a folder inside an open archive."))
            return
        }
        let parentFolder = activePane.currentArchiveFolder
        let password = activePane.archivePassword

        NewFolderController.present(on: window) { [weak self] name in
            guard let self = self, let name = name else { return }
            let token = OperationToken()
            let progress = ProgressWindowController(operationName: L("Creating “%@”…", name), token: token)
            progress.showWindow(self)
            Task {
                do {
                    try await NewFolderController.createFolder(
                        inArchive: archivePath, parentFolder: parentFolder,
                        name: name, password: password, token: token
                    )
                    await MainActor.run {
                        progress.close()
                        self.activePane.reload()
                    }
                } catch {
                    await MainActor.run {
                        progress.close()
                        self.showError(error)
                    }
                }
            }
        }
    }

    @objc func archiveCommentAction(_ sender: Any?) {
        guard let window = window else { return }
        guard let archivePath = activePane.archivePath else {
            showSimpleAlert(title: L("Open an archive first"),
                            text: L("Comments belong to an archive, so open one before editing its comment."))
            return
        }
        Task {
            let current = (try? await ArchiveCommentController.readComment(archivePath: archivePath)) ?? ""
            await MainActor.run {
                ArchiveCommentController.present(on: window, archivePath: archivePath, currentComment: current) { newComment in
                    guard let newComment = newComment else { return }
                    Task {
                        do {
                            try await ArchiveCommentController.writeComment(archivePath: archivePath, comment: newComment)
                            await MainActor.run { self.activePane.updateStatus(L("Comment saved")) }
                        } catch {
                            await MainActor.run { self.showError(error) }
                        }
                    }
                }
            }
        }
    }

    @objc func splitFileAction(_ sender: Any?) {
        guard let window = window else { return }
        guard !activePane.isInsideArchive, let path = activePane.selectedFilesystemPaths.first else {
            showSimpleAlert(title: L("Select a file"), text: L("Choose a single file on disk to split."))
            return
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        guard !isDir.boolValue else {
            showSimpleAlert(title: L("Folders cannot be split"), text: L("Compress the folder first, then split the archive."))
            return
        }
        SplitCombineController.presentSplit(on: window, file: URL(fileURLWithPath: path)) { [weak self] parts in
            guard let self = self else { return }
            if let parts = parts {
                self.activePane.updateStatus(L("Created %d parts", parts.count))
                self.activePane.reload()
            }
        }
    }

    @objc func combineFilesAction(_ sender: Any?) {
        guard let window = window else { return }
        guard !activePane.isInsideArchive, let path = activePane.selectedFilesystemPaths.first else {
            showSimpleAlert(title: L("Select the first part"), text: L("Choose the .001 file of a split set."))
            return
        }
        SplitCombineController.presentCombine(on: window, firstPart: URL(fileURLWithPath: path)) { [weak self] result in
            guard let self = self else { return }
            if let result = result {
                self.activePane.updateStatus(L("Combined into %@", result.lastPathComponent))
                self.activePane.reload()
            }
        }
    }

    // MARK: - Copy / Move between panes

    @objc func copyToOtherPaneAction(_ sender: Any?) {
        transferToOtherPane(move: false)
    }

    @objc func moveToOtherPaneAction(_ sender: Any?) {
        transferToOtherPane(move: true)
    }

    /// Where a Copy/Move lands: the other pane, or a folder the user picked.
    private struct TransferTarget {
        let path: String
        let archivePath: String?
        let archiveFolder: String
        let password: String?
        let pane: BrowserPaneController?
    }

    /// F5/F6 semantics: the destination is the opposite pane's current location, or —
    /// with a single pane, like 7-Zip's "Copy To…" — a folder the user picks.
    /// Copying out of an archive extracts; copying into an archive adds.
    private func transferToOtherPane(move: Bool) {
        if let pane = oppositePane {
            performTransfer(move: move, to: TransferTarget(
                path: pane.currentPath, archivePath: pane.archivePath,
                archiveFolder: pane.currentArchiveFolder, password: pane.archivePassword, pane: pane))
            return
        }

        let hasSelection = activePane.isInsideArchive
            ? !activePane.selectedInArchivePaths.isEmpty
            : !activePane.selectedFilesystemPaths.isEmpty
        guard hasSelection, let window = window else {
            activePane.updateStatus(L("Select the items to copy first"))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = move ? L("Move") : L("Copy")
        panel.message = move ? L("Choose where to move the selected items.") : L("Choose where to copy the selected items.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.performTransfer(move: move, to: TransferTarget(
                path: url.path, archivePath: nil, archiveFolder: "", password: nil, pane: nil), confirmed: true)
        }
    }

    private func performTransfer(move: Bool, to target: TransferTarget, confirmed: Bool = false) {
        // Source inside an archive → extract into the destination folder
        if let sourceArchive = activePane.archivePath {
            guard target.archivePath == nil else {
                showSimpleAlert(title: L("Not supported"),
                                text: L("Copying directly between two archives is not supported. Extract to a folder first."))
                return
            }
            let entries = activePane.selectedInArchivePaths
            guard !entries.isEmpty else { return }
            if move {
                showSimpleAlert(title: L("Move is not available here"),
                                text: L("Moving files out of an archive would delete them from it. Use Copy, then delete them if you meant to."))
                return
            }
            let destination = target.path
            let token = OperationToken()
            let progress = ProgressWindowController(operationName: L("Extracting to %@…", (destination as NSString).lastPathComponent), token: token)
            progress.showWindow(self)
            let password = activePane.archivePassword
            Task {
                do {
                    try await SevenZipWrapper.extractFiles(
                        from: sourceArchive, files: entries, to: destination,
                        password: password, overwriteMode: .renameExtracting, token: token
                    ) { percent, file in progress.updateProgress(percent: percent, file: file) }
                    await MainActor.run {
                        progress.close()
                        target.pane?.reload()
                        self.activePane.updateStatus(L("Extraction complete"))
                    }
                } catch {
                    await MainActor.run {
                        progress.close()
                        self.showError(error)
                    }
                }
            }
            return
        }

        // Source on disk
        let sources = activePane.selectedFilesystemPaths
        guard !sources.isEmpty else { return }

        // Destination inside an archive → add the files to it
        if let targetArchive = target.archivePath, let targetPane = target.pane {
            if move {
                showSimpleAlert(title: L("Move into archive is not available"),
                                text: L("Use Copy to add files to the archive; delete the originals afterwards if you meant to move them."))
                return
            }
            addPaths(sources, toArchive: targetArchive, folder: target.archiveFolder,
                     password: target.password, reloading: targetPane)
            return
        }

        // Plain filesystem copy/move
        let destinationDir = target.path
        guard FolderAccess.ensureAccess(to: [destinationDir], forWriting: true) else { return }
        if !confirmed {
            let alert = NSAlert()
            alert.messageText = move ? L("Move %d item(s)?", sources.count) : L("Copy %d item(s)?", sources.count)
            alert.informativeText = L("Destination:\n%@", destinationDir)
            alert.addButton(withTitle: move ? L("Move") : L("Copy"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let token = OperationToken()
        let folderName = (destinationDir as NSString).lastPathComponent
        let progress = ProgressWindowController(
            operationName: move ? L("Moving to %@…", folderName) : L("Copying to %@…", folderName), token: token)
        progress.showWindow(self)
        let sourcePane = activePane!

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Self.transferItems(sources, into: destinationDir, move: move, token: token) { fraction, name in
                    progress.updateProgress(percent: fraction * 100, file: name)
                }
            }.value
            progress.close()
            target.pane?.reload()
            if move || sourcePane.currentPath == destinationDir { sourcePane.reload() }

            if result.failures.isEmpty {
                sourcePane.updateStatus(move ? L("Moved %d item(s)", result.done) : L("Copied %d item(s)", result.done))
            } else {
                self.showSimpleAlert(title: move ? L("Move finished with errors") : L("Copy finished with errors"),
                                     text: result.failures.joined(separator: "\n"))
            }
        }
    }

    /// Copies or moves files off the main thread. Never overwrites: a clash gets a
    /// numeric suffix ("report_1.pdf"), as in the original single-threaded version.
    nonisolated private static func transferItems(
        _ sources: [String], into destinationDir: String, move: Bool, token: OperationToken,
        progress: @Sendable (Double, String) -> Void
    ) -> (done: Int, failures: [String]) {
        let fm = FileManager()
        var failures: [String] = []
        var done = 0
        for (index, source) in sources.enumerated() {
            while token.isPaused && !token.isCancelled { Thread.sleep(forTimeInterval: 0.2) }
            if token.isCancelled { break }
            let sourceURL = URL(fileURLWithPath: source)
            progress(Double(index) / Double(sources.count), sourceURL.lastPathComponent)

            var destURL = URL(fileURLWithPath: destinationDir).appendingPathComponent(sourceURL.lastPathComponent)
            if destURL.standardizedFileURL == sourceURL.standardizedFileURL && move { continue }
            var counter = 1
            let base = destURL.deletingPathExtension().lastPathComponent
            let ext = destURL.pathExtension
            while fm.fileExists(atPath: destURL.path) {
                let candidate = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
                destURL = URL(fileURLWithPath: destinationDir).appendingPathComponent(candidate)
                counter += 1
            }
            do {
                if move {
                    try fm.moveItem(at: sourceURL, to: destURL)
                } else {
                    try fm.copyItem(at: sourceURL, to: destURL)
                }
                done += 1
            } catch {
                failures.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        progress(1, "")
        return (done, failures)
    }

    // MARK: - Context menu helpers

    @objc private func contextOpen() {
        if let entry = activePane.selectedEntries.first {
            activePane.fileListDidDoubleClick(entry: entry)
        }
    }

    /// 7-Zip's "Open Inside": browse any file as an archive (.docx, .jar, .apk, .exe…),
    /// whatever its extension says.
    @objc private func contextOpenInside() {
        guard let path = activePane.selectedFilesystemPaths.first else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        activePane.openArchive(at: path)
    }

    @objc private func contextShowInFinder() {
        let urls = activePane.selectedFilesystemPaths.map { URL(fileURLWithPath: $0) }
        if urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: activePane.currentPath)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc private func contextAddToArchive() {
        showCompressSheet()
    }

    /// AirDrop, Mail, Messages… — the system share sheet, anchored at the clicked row.
    @objc private func contextShare() {
        let urls = activePane.selectedFilesystemPaths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = activePane.listResponder
        picker.show(relativeTo: activePane.rectForClickedRow(), of: anchor, preferredEdge: .maxY)
    }

    @objc private func contextCopyPath() {
        let paths = activePane.isInsideArchive
            ? activePane.selectedEntries.map { $0.path }
            : activePane.selectedFilesystemPaths
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        activePane.updateStatus(L("Path copied"))
    }

    // MARK: - Compression

    func showCompressSheet(for files: [String]? = nil) {
        let sheet = CompressSheetController()
        self.activeSheet = sheet
        sheet.sourceFiles = files ?? activePane.selectedFilesystemPaths

        // A second pane makes a natural default destination
        sheet.onCompleted = { [weak self] _ in
            self?.oppositePane?.reload()
            self?.activePane.reload()
        }

        window?.beginSheet(sheet.window!) { [weak self] _ in
            self?.activeSheet = nil
        }
    }

    private func addPaths(_ paths: [String], toArchive archive: String, folder: String,
                          password: String?, reloading pane: BrowserPaneController) {
        guard FolderAccess.ensureAccess(to: paths, forWriting: false),
              FolderAccess.ensureAccess(to: [archive], forWriting: true) else { return }
        let token = OperationToken()
        let progress = ProgressWindowController(operationName: L("Adding files…"), token: token)
        progress.showWindow(self)

        Task {
            do {
                try await SevenZipWrapper.addFiles(
                    to: archive, sourcePaths: paths, inFolder: folder,
                    password: password, token: token
                ) { percent, file in progress.updateProgress(percent: percent, file: file) }
                await MainActor.run {
                    progress.close()
                    pane.reload()
                }
            } catch {
                await MainActor.run {
                    progress.close()
                    self.showError(error)
                }
            }
        }
    }

    // MARK: - Extraction

    private func extractFromArchive() {
        if let archivePath = activePane.archivePath {
            presentExtractDialog(archive: archivePath,
                                 selectedFiles: activePane.selectedInArchivePaths,
                                 entries: activePane.allArchiveEntries,
                                 knownPassword: activePane.archivePassword)
        } else {
            let selectedArchives = activePane.selectedFilesystemPaths.filter { activePane.isArchive(path: $0) }
            guard !selectedArchives.isEmpty else {
                showSimpleAlert(title: L("Nothing to extract"), text: L("Select one or more archives in the list first."))
                return
            }
            if selectedArchives.count == 1 {
                presentExtractDialog(archive: selectedArchives[0], selectedFiles: [], entries: nil, knownPassword: nil)
            } else {
                presentBatchExtractDialog(archives: selectedArchives)
            }
        }
    }

    private func presentExtractDialog(archive: String, selectedFiles: [String], entries: [ArchiveEntry]?, knownPassword: String?) {
        guard let window = window else { return }
        let archiveURL = URL(fileURLWithPath: archive)
        let name = archiveURL.deletingPathExtension().lastPathComponent
        let count = selectedFiles.isEmpty ? (entries?.count ?? 0) : selectedFiles.count

        // With two panes open, the other pane's folder is the natural destination
        let suggested = oppositePane.flatMap { $0.isInsideArchive ? nil : URL(fileURLWithPath: $0.currentPath) }
            ?? archiveURL.deletingLastPathComponent()

        ExtractDialogController.present(
            on: window, archiveName: name, entryCount: count, suggestedDestination: suggested
        ) { [weak self] options in
            guard let self = self, var options = options else { return }
            if options.password == nil { options.password = knownPassword }

            Task {
                let listEntries: [ArchiveEntry]
                if let entries = entries {
                    listEntries = entries
                } else {
                    listEntries = (try? await SevenZipWrapper.listArchive(at: archive, password: options.password)) ?? []
                }

                var destination = options.destination
                if options.createSubfolder {
                    let skipSubfolder = options.eliminateRootDuplication && self.singleRootFolder(of: listEntries) != nil
                    if !skipSubfolder { destination.appendPathComponent(name) }
                }

                var overwrite = options.overwriteMode
                if overwrite == .ask {
                    overwrite = await self.resolveOverwriteByAsking(
                        entries: listEntries, selectedFiles: selectedFiles,
                        destination: destination, flatten: options.flattenPaths
                    ) ?? .ask
                    if overwrite == .ask { return }
                }

                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                await MainActor.run {
                    self.performExtraction(
                        at: archive, selectedFiles: selectedFiles,
                        destination: destination.path, password: options.password,
                        overwriteMode: overwrite, flatten: options.flattenPaths
                    )
                }
            }
        }
    }

    private func singleRootFolder(of entries: [ArchiveEntry]) -> String? {
        var root: String? = nil
        for entry in entries {
            let first = entry.path.split(separator: "/").first.map(String.init) ?? entry.path
            if root == nil { root = first }
            else if root != first { return nil }
            if !entry.path.contains("/") && !entry.isDirectory { return nil }
        }
        return root
    }

    private func resolveOverwriteByAsking(
        entries: [ArchiveEntry], selectedFiles: [String], destination: URL, flatten: Bool
    ) async -> OverwriteMode? {
        let fm = FileManager.default
        let relevant: [ArchiveEntry]
        if selectedFiles.isEmpty {
            relevant = entries.filter { !$0.isDirectory }
        } else {
            let sel = Set(selectedFiles)
            relevant = entries.filter { entry in
                !entry.isDirectory && (sel.contains(entry.path) || sel.contains(where: { entry.path.hasPrefix($0 + "/") }))
            }
        }

        var firstCollision: (ArchiveEntry, URL)? = nil
        var collisionCount = 0
        for entry in relevant {
            let target = flatten
                ? destination.appendingPathComponent((entry.path as NSString).lastPathComponent)
                : destination.appendingPathComponent(entry.path)
            if fm.fileExists(atPath: target.path) {
                collisionCount += 1
                if firstCollision == nil { firstCollision = (entry, target) }
            }
        }

        guard let (entry, target) = firstCollision else { return .overwriteAll }

        let attrs = try? fm.attributesOfItem(atPath: target.path)
        let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let existingDate = attrs?[.modificationDate] as? Date

        let suffix = collisionCount > 1 ? " " + L("(and %d more — your choice applies to all)", collisionCount - 1) : ""
        let decision = await OverwriteDialog.ask(
            on: window,
            fileName: entry.name + suffix,
            existing: (size: existingSize, modified: existingDate),
            incoming: (size: entry.size, modified: entry.modified)
        )
        switch decision {
        case .yes, .yesToAll: return .overwriteAll
        case .no, .noToAll: return .skipExisting
        case .autoRename: return .renameExtracting
        case .cancel: return .ask
        }
    }

    private func presentBatchExtractDialog(archives: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("Extract %d Archives", archives.count)
        panel.message = L("Each archive will be extracted into its own subfolder.")
        if let other = oppositePane, !other.isInsideArchive {
            panel.directoryURL = URL(fileURLWithPath: other.currentPath)
        }

        guard panel.runModal() == .OK, let base = panel.url else { return }
        for archive in archives {
            let name = URL(fileURLWithPath: archive).deletingPathExtension().lastPathComponent
            let dest = base.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            performExtraction(at: archive, selectedFiles: [], destination: dest.path,
                              password: nil, overwriteMode: .renameExtracting, flatten: false)
        }
    }

    private func performExtraction(
        at path: String, selectedFiles: [String], destination: String,
        password: String?, overwriteMode: OverwriteMode = .overwriteAll, flatten: Bool = false
    ) {
        guard FolderAccess.ensureAccess(to: [destination], forWriting: true) else { return }
        let token = OperationToken()
        let progressWindow = ProgressWindowController(operationName: L("Extracting…"), token: token)
        progressWindow.showWindow(self)

        Task {
            do {
                if selectedFiles.isEmpty {
                    try await SevenZipWrapper.extractArchive(
                        at: path, to: destination, password: password,
                        overwriteMode: overwriteMode, flatten: flatten, token: token
                    ) { percent, file in progressWindow.updateProgress(percent: percent, file: file) }
                } else {
                    try await SevenZipWrapper.extractFiles(
                        from: path, files: selectedFiles, to: destination, password: password,
                        overwriteMode: overwriteMode, flatten: flatten, token: token
                    ) { percent, file in progressWindow.updateProgress(percent: percent, file: file) }
                }

                await MainActor.run {
                    progressWindow.close()
                    self.activePane.updateStatus(L("Extraction complete"))
                    self.oppositePane?.reload()
                    NSWorkspace.shared.open(URL(fileURLWithPath: destination))
                }
            } catch SevenZipError.passwordRequired {
                await MainActor.run {
                    progressWindow.close()
                    self.promptForPassword { newPassword in
                        if let np = newPassword {
                            self.performExtraction(at: path, selectedFiles: selectedFiles, destination: destination,
                                                    password: np, overwriteMode: overwriteMode, flatten: flatten)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    progressWindow.close()
                    self.showError(error)
                }
            }
        }
    }

    // MARK: - Testing

    func runArchiveTests(paths: [String]) {
        activePane.updateStatus(L("Testing…"))
        let knownArchive = activePane.archivePath
        let knownPassword = activePane.archivePassword

        Task {
            var lines: [String] = []
            var allPassed = true
            for path in paths {
                let name = (path as NSString).lastPathComponent
                do {
                    let result = try await SevenZipWrapper.testArchive(
                        at: path, password: knownArchive == path ? knownPassword : nil)
                    if result.passed {
                        lines.append(L("✓ %@: OK", name))
                    } else {
                        allPassed = false
                        let tail = result.details.split(separator: "\n").suffix(3).joined(separator: "\n")
                        lines.append(L("✗ %@: failed", name) + "\n" + tail)
                    }
                } catch SevenZipError.passwordRequired {
                    let pw: String? = await withCheckedContinuation { cont in
                        DispatchQueue.main.async {
                            self.promptForPassword(message: L("“%@” is encrypted. Enter the password to test it:", name)) {
                                cont.resume(returning: $0)
                            }
                        }
                    }
                    if let pw = pw {
                        do {
                            let result = try await SevenZipWrapper.testArchive(at: path, password: pw)
                            lines.append(result.passed ? L("✓ %@: OK", name) : L("✗ %@: failed", name))
                            if !result.passed { allPassed = false }
                        } catch {
                            allPassed = false
                            lines.append("✗ \(name): \(error.localizedDescription)")
                        }
                    } else {
                        lines.append(L("– %@: skipped (no password)", name))
                    }
                } catch {
                    allPassed = false
                    lines.append("✗ \(name): \(error.localizedDescription)")
                }
            }

            let summary = lines.joined(separator: "\n")
            await MainActor.run {
                self.activePane.updateStatus(allPassed ? L("Test passed") : L("Test failed"))
                let alert = NSAlert()
                alert.messageText = allPassed ? L("Test Passed") : L("Test Failed")
                alert.informativeText = summary
                alert.alertStyle = allPassed ? .informational : .warning
                alert.runModal()
            }
        }
    }

    // MARK: - Delete / Rename

    private func deleteSelected() {
        if let archivePath = activePane.archivePath {
            let selected = activePane.selectedInArchivePaths
            guard !selected.isEmpty else { return }

            let alert = NSAlert()
            alert.messageText = L("Delete from Archive?")
            alert.informativeText = L("Delete %d item(s) from the archive?", selected.count)
            alert.addButton(withTitle: L("Delete"))
            alert.addButton(withTitle: L("Cancel"))

            if alert.runModal() == .alertFirstButtonReturn {
                let password = activePane.archivePassword
                Task {
                    do {
                        try await SevenZipWrapper.deleteFiles(from: archivePath, files: selected, password: password)
                        await MainActor.run { self.activePane.reload() }
                    } catch {
                        await MainActor.run { self.showError(error) }
                    }
                }
            }
        } else {
            let fullPaths = activePane.selectedFilesystemPaths
            guard !fullPaths.isEmpty else { return }

            let alert = NSAlert()
            alert.messageText = L("Move to Trash?")
            alert.informativeText = L("Move %d item(s) to the Trash?", fullPaths.count)
            alert.addButton(withTitle: L("Move to Trash"))
            alert.addButton(withTitle: L("Cancel"))

            if alert.runModal() == .alertFirstButtonReturn {
                var failed = 0
                for path in fullPaths {
                    do {
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    } catch {
                        failed += 1
                    }
                }
                activePane.updateStatus(failed == 0 ? L("Moved to Trash") : L("Could not move to the Trash: %d", failed))
                activePane.reload()
            }
        }
    }

    private func renameSelected() {
        let selected = activePane.selectedEntries
        guard selected.count == 1, let entry = selected.first else {
            activePane.updateStatus(L("Select a single item to rename"))
            return
        }

        let alert = NSAlert()
        alert.messageText = L("Rename “%@”", entry.name)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = entry.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: L("Rename"))
        alert.addButton(withTitle: L("Cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != entry.name, !newName.contains("/") else { return }

        if let archivePath = activePane.archivePath {
            let parent = (entry.path as NSString).deletingLastPathComponent
            let newPath = parent.isEmpty ? newName : parent + "/" + newName
            let password = activePane.archivePassword
            Task {
                do {
                    try await SevenZipWrapper.renameEntry(in: archivePath, from: entry.path, to: newPath, password: password)
                    await MainActor.run { self.activePane.reload() }
                } catch {
                    await MainActor.run { self.showError(error) }
                }
            }
        } else {
            let oldURL = URL(fileURLWithPath: (activePane.currentPath as NSString).appendingPathComponent(entry.path))
            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
            do {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                activePane.reload()
            } catch {
                showError(error)
            }
        }
    }

    // MARK: - Info

    private func showInfo() {
        if let archivePath = activePane.archivePath {
            let name = (archivePath as NSString).lastPathComponent
            let password = activePane.archivePassword
            Task {
                do {
                    let props = try await SevenZipWrapper.archiveProperties(at: archivePath, password: password)
                    await MainActor.run {
                        let panel = InfoPanelController(title: name, properties: props)
                        self.infoWindows.append(panel)
                        panel.showWindow(self)
                    }
                } catch {
                    await MainActor.run { self.showError(error) }
                }
            }
            return
        }

        guard let first = activePane.selectedFilesystemPaths.first else {
            activePane.updateStatus(L("Select an item to inspect"))
            return
        }

        if activePane.isArchive(path: first) {
            let name = (first as NSString).lastPathComponent
            Task {
                do {
                    let props = try await SevenZipWrapper.archiveProperties(at: first)
                    await MainActor.run {
                        let panel = InfoPanelController(title: name, properties: props)
                        self.infoWindows.append(panel)
                        panel.showWindow(self)
                    }
                } catch {
                    await MainActor.run { self.showError(error) }
                }
            }
        } else {
            let url = URL(fileURLWithPath: first)
            var props: [(String, String)] = []
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey])
            props.append((L("Path"), first))
            if values?.isDirectory == true {
                props.append((L("Kind"), L("Folder")))
            } else if let type = values?.contentType {
                props.append((L("Kind"), type.localizedDescription ?? type.identifier))
            }
            if let size = values?.fileSize { props.append((L("Size"), ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
            if let created = values?.creationDate { props.append((L("Created"), DateFormatter.localizedString(from: created, dateStyle: .medium, timeStyle: .short))) }
            if let modified = values?.contentModificationDate { props.append((L("Modified"), DateFormatter.localizedString(from: modified, dateStyle: .medium, timeStyle: .short))) }
            let panel = InfoPanelController(title: url.lastPathComponent, properties: props)
            infoWindows.append(panel)
            panel.showWindow(self)
        }
    }

    // MARK: - Hashing

    private func runHash(paths: [String], algorithms: [HashAlgorithm]) {
        activePane.updateStatus(L("Calculating checksums…"))
        let token = OperationToken()
        Task {
            var results: [HashResult] = []
            do {
                for algo in algorithms {
                    let result = try await SevenZipWrapper.calculateHash(of: paths, algorithm: algo, token: token)
                    results.append(result)
                }
                let final = results
                await MainActor.run {
                    self.activePane.updateStatus(L("Ready"))
                    let controller = HashResultsWindowController(results: final)
                    self.hashWindows.append(controller)
                    controller.showWindow(self)
                }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    // MARK: - Alerts

    private func showSimpleAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    private func showError(_ error: Error) {
        if case SevenZipError.cancelled = error {
            activePane.updateStatus(L("Cancelled"))
            return
        }
        AppLogger.shared.log(message: "⚠️ Displaying error to user: \(error.localizedDescription)", level: .error)
        NSAlert(error: error).runModal()
    }

    private func promptForPassword(message: String = L("Please enter the password for this archive."),
                                   completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("Password Required")
        alert.informativeText = message

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))

        completion(alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }

    // MARK: - IPC from the Finder extension

    func handleFinderExtensionAction(action: String, paths: [String], algorithm: String? = nil) {
        guard !paths.isEmpty else { return }
        // App Store build: what Finder hands over may lie outside the folders the user
        // granted; actions that write next to the items also need their folders.
        guard FolderAccess.ensureAccess(to: paths, forWriting: false) else { return }
        if ["compressTo7z", "compressToZip", "compressToTaj", "extractHere", "extractToFolder"].contains(action),
           !FolderAccess.ensureAccess(to: paths.map { ($0 as NSString).deletingLastPathComponent }, forWriting: true) {
            return
        }

        switch action {
        case "compress":
            showCompressSheet(for: paths)

        case "compressTo7z", "compressToZip", "compressToTaj":
            let format: ArchiveFormat = action == "compressTo7z" ? .sevenZip : (action == "compressToZip" ? .zip : .taj)
            let target = directCompressionTargetName(paths: paths, format: format)
            confirmFinderAction(title: L("Compress %d item(s)?", paths.count),
                                detail: L("Create “%@” next to the selected files?", target),
                                paths: paths) { [weak self] in
                self?.startDirectCompression(paths: paths, format: format)
            }

        case "extractHere":
            confirmFinderAction(title: L("Extract %d archive(s) here?", paths.count),
                                detail: L("Files will be extracted next to each archive."),
                                paths: paths) { [weak self] in
                guard let self = self else { return }
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    self.startDirectExtraction(archive: path, destination: url.deletingLastPathComponent().path)
                }
            }

        case "extractToFolder":
            confirmFinderAction(title: L("Extract %d archive(s)?", paths.count),
                                detail: L("Each archive will be extracted into its own folder."),
                                paths: paths) { [weak self] in
                guard let self = self else { return }
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    let folderName = url.deletingPathExtension().lastPathComponent
                    let dest = url.deletingLastPathComponent().appendingPathComponent(folderName).path
                    try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true, attributes: nil)
                    self.startDirectExtraction(archive: path, destination: dest)
                }
            }

        case "extractTo":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = L("Extract Here")
            if panel.runModal() == .OK, let destURL = panel.url {
                for path in paths {
                    startDirectExtraction(archive: path, destination: destURL.path)
                }
            }

        case "test":
            runArchiveTests(paths: paths)

        case "open":
            activePane.openArchive(at: paths[0])
            if paths.count > 1 {
                // A second archive fills the other pane instead of opening a new window
                if !isDualPane { setDualPane(true) }
                oppositePane?.openArchive(at: paths[1])
                if paths.count > 2, let delegate = NSApp.delegate as? AppDelegate {
                    for extra in paths.dropFirst(2) {
                        let controller = MainWindowController()
                        delegate.extraWindowControllers.append(controller)
                        controller.showWindow(self)
                        controller.openArchive(at: extra)
                    }
                }
            }

        case "hash":
            let algos: [HashAlgorithm]
            if let algorithm = algorithm, algorithm != "ALL", let algo = HashAlgorithm(rawValue: algorithm) {
                algos = [algo]
            } else {
                algos = HashAlgorithm.allCases
            }
            runHash(paths: paths, algorithms: algos)

        default:
            break
        }
    }

    private func directCompressionTargetName(paths: [String], format: ArchiveFormat) -> String {
        let firstURL = URL(fileURLWithPath: paths[0])
        let name = paths.count == 1
            ? firstURL.deletingPathExtension().lastPathComponent
            : firstURL.deletingLastPathComponent().lastPathComponent
        return "\(name).\(format.extensionString)"
    }

    /// Confirmation gate for operations triggered through the public tajarchive:// scheme.
    private func confirmFinderAction(title: String, detail: String, paths: [String], onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let shown = paths.prefix(6).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n")
        let more = paths.count > 6 ? "\n" + L("…and %d more", paths.count - 6) : ""
        alert.informativeText = "\(detail)\n\n\(shown)\(more)"
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
    }

    private func startDirectCompression(paths: [String], format: ArchiveFormat = .sevenZip) {
        guard !paths.isEmpty else { return }

        let firstURL = URL(fileURLWithPath: paths[0])
        let destDir = firstURL.deletingLastPathComponent()
        let archiveName = paths.count == 1
            ? firstURL.deletingPathExtension().lastPathComponent
            : destDir.lastPathComponent

        var archivePath = destDir.appendingPathComponent("\(archiveName).\(format.extensionString)").path
        var counter = 1
        while FileManager.default.fileExists(atPath: archivePath) {
            archivePath = destDir.appendingPathComponent("\(archiveName)_\(counter).\(format.extensionString)").path
            counter += 1
        }

        let token = OperationToken()
        let progressWindow = ProgressWindowController(
            operationName: L("Compressing to %@…", (archivePath as NSString).lastPathComponent), token: token)
        progressWindow.showWindow(self)

        let finalArchivePath = archivePath
        let settings = CompressionSettings.load(for: format)

        Task {
            do {
                let producedPath = try await SevenZipWrapper.createArchive(
                    at: finalArchivePath, from: paths, workingDirectory: destDir,
                    format: format, settings: settings, token: token,
                    progressHandler: { percent, file in progressWindow.updateProgress(percent: percent, file: file) }
                )
                await MainActor.run {
                    progressWindow.close()
                    NSWorkspace.shared.selectFile(producedPath, inFileViewerRootedAtPath: destDir.path)
                }
            } catch {
                await MainActor.run {
                    progressWindow.close()
                    self.showError(error)
                }
            }
        }
    }

    private func startDirectExtraction(archive: String, destination: String, password: String? = nil) {
        guard FolderAccess.ensureAccess(to: [destination], forWriting: true) else { return }
        let token = OperationToken()
        let progressWindow = ProgressWindowController(operationName: L("Extracting…"), token: token)
        progressWindow.showWindow(self)

        Task {
            do {
                try await SevenZipWrapper.extractArchive(
                    at: archive, to: destination, password: password,
                    overwriteMode: .renameExtracting, token: token
                ) { percent, file in progressWindow.updateProgress(percent: percent, file: file) }

                await MainActor.run {
                    progressWindow.close()
                    NSWorkspace.shared.open(URL(fileURLWithPath: destination))
                }
            } catch SevenZipError.passwordRequired {
                await MainActor.run {
                    progressWindow.close()
                    self.promptForPassword { newPassword in
                        if let np = newPassword {
                            self.startDirectExtraction(archive: archive, destination: destination, password: np)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    progressWindow.close()
                    self.showError(error)
                }
            }
        }
    }

    // MARK: - Preview cache

    private static var previewCacheRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TajArchivePreviewCache")
    }

    static func cleanPreviewCache() {
        try? FileManager.default.removeItem(at: previewCacheRoot)
    }

    /// Extracts an entry to a cached temp location and opens it with its default app.
    fileprivate func openEntryExternally(_ pane: BrowserPaneController, entryPath: String) {
        guard let archivePath = pane.archivePath else {
            NSWorkspace.shared.open(URL(fileURLWithPath: entryPath))
            return
        }

        let entry = pane.allArchiveEntries.first { $0.path == entryPath }

        // Archives inside archives open in the pane itself
        if pane.isArchive(path: entryPath) {
            openNestedArchive(pane, entryPath: entryPath)
            return
        }

        let mtimeTag = entry?.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let cacheDir = Self.previewCacheRoot
            .appendingPathComponent("p_\(abs(archivePath.hashValue))_\(abs(entryPath.hashValue))_\(mtimeTag)")
        let extractedURL = cacheDir.appendingPathComponent(entryPath)

        if FileManager.default.fileExists(atPath: extractedURL.path) {
            beginWatchingForEdits(archivePath: archivePath, entryPath: entryPath,
                                  localURL: extractedURL, password: pane.archivePassword)
            NSWorkspace.shared.open(extractedURL)
            return
        }

        let password = pane.archivePassword
        Task {
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                await MainActor.run { pane.updateStatus(L("Extracting for preview…")) }
                try await SevenZipWrapper.extractFiles(
                    from: archivePath, files: [entryPath], to: cacheDir.path,
                    password: password, overwriteMode: .overwriteAll
                )
                await MainActor.run {
                    pane.updateStatus(L("Ready"))
                    self.beginWatchingForEdits(archivePath: archivePath, entryPath: entryPath,
                                               localURL: extractedURL, password: password)
                    NSWorkspace.shared.open(extractedURL)
                }
            } catch SevenZipError.passwordRequired {
                await MainActor.run {
                    self.promptForPassword { newPassword in
                        guard let np = newPassword else { return }
                        pane.archivePassword = np
                        self.openEntryExternally(pane, entryPath: entryPath)
                    }
                }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }

    // MARK: - Edit inside the archive

    /// Watches the temp copy the user is editing and offers to write it back.
    private func beginWatchingForEdits(archivePath: String, entryPath: String,
                                       localURL: URL, password: String?) {
        EditedFileWatcher.shared.onFileChanged = { [weak self] file in
            self?.promptToUpdateArchive(with: file)
        }
        EditedFileWatcher.shared.watch(
            EditedFileWatcher.WatchedFile(archivePath: archivePath, entryPath: entryPath,
                                          localURL: localURL, password: password)
        )
    }

    private func promptToUpdateArchive(with file: EditedFileWatcher.WatchedFile) {
        let archiveName = (file.archivePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = L("Update “%@”?", archiveName)
        alert.informativeText = L("“%@” was modified. Write the changes back into the archive?", (file.entryPath as NSString).lastPathComponent)
        alert.addButton(withTitle: L("Update Archive"))
        alert.addButton(withTitle: L("Not Now"))
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 7zz stores what it finds under the working directory, so re-adding the file
        // from the cache root reproduces the entry's original path inside the archive.
        let cacheRoot = file.localURL.path.hasSuffix(file.entryPath)
            ? URL(fileURLWithPath: String(file.localURL.path.dropLast(file.entryPath.count)))
            : file.localURL.deletingLastPathComponent()

        let token = OperationToken()
        let progress = ProgressWindowController(operationName: L("Updating %@…", archiveName), token: token)
        progress.showWindow(self)

        Task {
            do {
                try await SevenZipWrapper.updateArchive(
                    at: file.archivePath,
                    with: [file.localURL.path],
                    password: file.password,
                    token: token,
                    workingDirectoryOverride: cacheRoot,
                    storedName: file.entryPath
                )
                await MainActor.run {
                    progress.close()
                    self.activePane.updateStatus(L("Archive updated"))
                    if self.activePane.archivePath == file.archivePath { self.activePane.reload() }
                    if self.oppositePane?.archivePath == file.archivePath { self.oppositePane?.reload() }
                }
            } catch {
                await MainActor.run {
                    progress.close()
                    self.showError(error)
                }
            }
        }
    }

    private func openNestedArchive(_ pane: BrowserPaneController, entryPath: String) {
        guard let outerArchive = pane.archivePath else { return }
        let cacheDir = Self.previewCacheRoot
            .appendingPathComponent("nested_\(abs(outerArchive.hashValue))_\(abs(entryPath.hashValue))")
        let extractedURL = cacheDir.appendingPathComponent((entryPath as NSString).lastPathComponent)

        if FileManager.default.fileExists(atPath: extractedURL.path) {
            pane.openArchive(at: extractedURL.path)
            return
        }

        let password = pane.archivePassword
        Task {
            do {
                await MainActor.run { pane.updateStatus(L("Opening nested archive…")) }
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try await SevenZipWrapper.extractFiles(
                    from: outerArchive, files: [entryPath], to: cacheDir.path,
                    password: password, overwriteMode: .overwriteAll, flatten: true
                )
                await MainActor.run {
                    pane.updateStatus(L("Ready"))
                    pane.openArchive(at: extractedURL.path)
                }
            } catch {
                await MainActor.run { self.showError(error) }
            }
        }
    }
}

// MARK: - BrowserPaneDelegate

extension MainWindowController: BrowserPaneDelegate {

    func paneDidBecomeActive(_ pane: BrowserPaneController) {
        setActivePane(pane)
    }

    func paneDidChangeLocation(_ pane: BrowserPaneController) {
        if pane === activePane { updateWindowTitle() }
        if pane === leftPane && !pane.isInsideArchive {
            UserDefaults.standard.set(pane.currentPath, forKey: Self.lastFolderKey)
        }
    }

    func paneDidChangeSelection(_ pane: BrowserPaneController) {
        setActivePane(pane)
    }

    func pane(_ pane: BrowserPaneController, needsPasswordFor archive: String, message: String,
              completion: @escaping (String?) -> Void) {
        promptForPassword(message: message, completion: completion)
    }

    func pane(_ pane: BrowserPaneController, didFail error: Error) {
        showError(error)
    }

    func pane(_ pane: BrowserPaneController, openExternally url: URL) {
        if pane.isInsideArchive {
            openEntryExternally(pane, entryPath: url.path)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func pane(_ pane: BrowserPaneController, didAcceptDrop urls: [URL]) {
        let paths = urls.map { $0.path }
        if let archivePath = pane.archivePath {
            addPaths(paths, toArchive: archivePath, folder: pane.currentArchiveFolder,
                     password: pane.archivePassword, reloading: pane)
        } else {
            // Dropping onto a filesystem pane copies the files there
            let fm = FileManager.default
            var failures = 0
            for path in paths {
                let sourceURL = URL(fileURLWithPath: path)
                let destURL = URL(fileURLWithPath: pane.currentPath).appendingPathComponent(sourceURL.lastPathComponent)
                guard sourceURL.deletingLastPathComponent().path != pane.currentPath else { continue }
                do { try fm.copyItem(at: sourceURL, to: destURL) } catch { failures += 1 }
            }
            pane.reload()
            if failures > 0 { pane.updateStatus(L("%d item(s) could not be copied", failures)) }
        }
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .init("add"), .init("extract"), .init("test"),
            .flexibleSpace,
            .init("dualPane"), .init("delete"), .init("info"), .init("search")
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [
            .init("add"), .init("extract"), .init("test"), .init("copy"), .init("move"),
            .init("delete"), .init("info"), .init("dualPane"), .init("back"), .init("forward"),
            .init("up"), .init("flatView"), .init("refresh"), .init("benchmark"), .init("search"),
            .flexibleSpace, .space
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier.rawValue {
        case "add":
            item.label = L("toolbar.add")
            item.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: L("toolbar.add"))
            item.action = #selector(addToArchive)
        case "extract":
            item.label = L("toolbar.extract")
            item.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: L("toolbar.extract"))
            item.action = #selector(extractAction(_:))
        case "test":
            item.label = L("toolbar.test")
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: L("toolbar.test"))
            item.action = #selector(testAction(_:))
        case "dualPane":
            item.label = L("Two Panes")
            item.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: L("Two Panes"))
            item.action = #selector(toggleDualPaneAction(_:))
        case "delete":
            item.label = L("toolbar.delete")
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: L("toolbar.delete"))
            item.action = #selector(deleteAction(_:))
        case "info":
            item.label = L("toolbar.info")
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: L("toolbar.info"))
            item.action = #selector(infoAction(_:))
        case "copy":
            item.label = L("Copy")
            item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("Copy To…"))
            item.toolTip = L("Copy To…")
            item.action = #selector(copyToOtherPaneAction(_:))
        case "move":
            item.label = L("Move")
            item.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard", accessibilityDescription: L("Move To…"))
            item.toolTip = L("Move To…")
            item.action = #selector(moveToOtherPaneAction(_:))
        case "back":
            item.label = L("Back")
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Back"))
            item.action = #selector(goBack)
        case "forward":
            item.label = L("Forward")
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Forward"))
            item.action = #selector(goForward)
        case "up":
            item.label = L("Enclosing Folder")
            item.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("Enclosing Folder"))
            item.action = #selector(goUp)
        case "flatView":
            item.label = L("Flat View")
            item.image = NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: L("Flat View"))
            item.action = #selector(toggleFlatViewAction(_:))
        case "refresh":
            item.label = L("Refresh")
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("Refresh"))
            item.action = #selector(refreshAction(_:))
        case "benchmark":
            item.label = L("Benchmark")
            item.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: L("Benchmark"))
            item.action = #selector(benchmarkAction(_:))
        case "search":
            let searchItem = NSToolbarItem(itemIdentifier: itemIdentifier)
            searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            searchField.placeholderString = L("toolbar.search") + "…"
            searchField.sendsSearchStringImmediately = true
            searchField.target = self
            searchField.action = #selector(searchChanged(_:))
            searchItem.view = searchField
            searchItem.label = L("toolbar.search")
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
            return searchItem
        default:
            return nil
        }

        item.target = self
        return item
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        activePane.setSearchQuery(sender.stringValue)
    }

    @objc private func addToArchive() {
        if let archivePath = activePane.archivePath {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = L("Add to Archive")

            if panel.runModal() == .OK {
                addPaths(panel.urls.map { $0.path }, toArchive: archivePath,
                         folder: activePane.currentArchiveFolder,
                         password: activePane.archivePassword, reloading: activePane)
            }
        } else {
            showCompressSheet()
        }
    }
}

// MARK: - Menu and toolbar validation

extension MainWindowController: NSMenuDelegate, NSMenuItemValidation, NSToolbarItemValidation {

    /// Context menu: items that need files on disk are hidden while browsing an archive.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let inArchive = activePane.isInsideArchive
        for item in menu.items where item.tag == Self.filesystemOnlyTag {
            item.isHidden = inArchive
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleDualPaneAction(_:)):
            menuItem.state = isDualPane ? .on : .off
        case #selector(toggleFlatViewAction(_:)):
            menuItem.state = activePane.isFlatView ? .on : .off
        default:
            break
        }
        return isActionEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isActionEnabled(item.action)
    }

    private func isActionEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(switchPaneAction(_:)): return isDualPane
        case #selector(goBack): return activePane.canGoBack
        case #selector(goForward): return activePane.canGoForward
        default: return true
        }
    }
}
