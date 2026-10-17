import Cocoa

/// Operations a pane cannot perform on its own because they need window-level UI
/// (dialogs, sheets) or coordination with the other pane.
protocol BrowserPaneDelegate: AnyObject {
    func paneDidBecomeActive(_ pane: BrowserPaneController)
    func paneDidChangeLocation(_ pane: BrowserPaneController)
    func paneDidChangeSelection(_ pane: BrowserPaneController)
    func pane(_ pane: BrowserPaneController, needsPasswordFor archive: String, message: String, completion: @escaping (String?) -> Void)
    func pane(_ pane: BrowserPaneController, didFail error: Error)
    /// The pane wants to open a file that is not an archive.
    func pane(_ pane: BrowserPaneController, openExternally url: URL)
    /// Files were dropped onto this pane from outside the app.
    func pane(_ pane: BrowserPaneController, didAcceptDrop urls: [URL])
}

/// One browsing surface: address bar, file list and status line, with its own
/// location, navigation history and archive state. Two of these make the
/// commander-style dual-pane layout.
final class BrowserPaneController: NSViewController {

    weak var delegate: BrowserPaneDelegate?

    // MARK: - Location state

    private(set) var currentPath: String
    private(set) var archivePath: String?
    private(set) var currentArchiveFolder: String = ""
    private(set) var allArchiveEntries: [ArchiveEntry] = []
    private(set) var visibleEntries: [ArchiveEntry] = []
    var archivePassword: String?

    /// Shows every file of the whole subtree in one list instead of folder by folder.
    private(set) var isFlatView = false

    private var searchQuery = ""
    private var loadGeneration = 0

    var isActive = false {
        didSet { updateActiveAppearance() }
    }

    var isInsideArchive: Bool { archivePath != nil }

    /// Absolute paths of the selected rows — only meaningful outside archives.
    var selectedFilesystemPaths: [String] {
        guard archivePath == nil else { return [] }
        return fileList.selectedPaths.map { (currentPath as NSString).appendingPathComponent($0) }
    }

    var selectedEntries: [ArchiveEntry] { fileList.selectedEntries }
    var selectedInArchivePaths: [String] { fileList.selectedPaths }

    // MARK: - Views

    private var fileList: FileListViewController!
    private var pathField: NSTextField!
    private var statusLabel: NSTextField!
    private var headerView: NSView!

    // MARK: - History

    private enum Location {
        case filesystem(path: String)
        case archive(path: String, folder: String, password: String?)
    }
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []
    private var navigatingViaHistory = false

    // MARK: - Init

    init(startPath: String) {
        self.currentPath = startPath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        setupUI()
        loadDirectory(at: currentPath)
    }

    private func setupUI() {
        headerView = NSView()
        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: L("Enclosing Folder")) ?? NSImage(),
                                target: self, action: #selector(goUp))
        upButton.bezelStyle = .texturedRounded
        upButton.toolTip = L("Enclosing Folder")
        upButton.translatesAutoresizingMaskIntoConstraints = false

        pathField = NSTextField()
        pathField.stringValue = currentPath
        pathField.isEditable = true
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false
        pathField.lineBreakMode = .byTruncatingHead
        pathField.placeholderString = L("Folder or archive path")

        headerView.addSubview(upButton)
        headerView.addSubview(pathField)

        fileList = FileListViewController()
        fileList.delegate = self
        let listView = fileList.view
        listView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(headerView)
        view.addSubview(listView)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 32),

            upButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 6),
            upButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 28),

            pathField.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 6),
            pathField.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -6),
            pathField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            listView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            statusLabel.heightAnchor.constraint(equalToConstant: 16)
        ])

        updateActiveAppearance()
    }

    func setContextMenu(_ menu: NSMenu) {
        fileList.setContextMenu(menu)
    }

    @discardableResult
    func applySelectionMask(_ pattern: String, select: Bool) -> Int {
        fileList.applySelectionMask(pattern, select: select)
    }

    /// Highlights the active pane so the user can tell which one commands act on.
    private func updateActiveAppearance() {
        guard isViewLoaded else { return }
        headerView.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : NSColor.windowBackgroundColor.cgColor
        pathField.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    func focusList() {
        view.window?.makeFirstResponder(fileList.tableView)
    }

    /// The view that should have keyboard focus when the window opens.
    var listResponder: NSView { fileList.tableView }

    func focusPathField() {
        view.window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
    }

    /// Where the context menu was opened, for anchoring popovers such as the share sheet.
    func rectForClickedRow() -> NSRect {
        let table = fileList.tableView!
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return row >= 0 ? table.rect(ofRow: row) : table.visibleRect
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: - Navigation history

    private func currentLocation() -> Location {
        if let ap = archivePath {
            return .archive(path: ap, folder: currentArchiveFolder, password: archivePassword)
        }
        return .filesystem(path: currentPath)
    }

    private func pushHistory() {
        guard !navigatingViaHistory else { return }
        backStack.append(currentLocation())
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    private func apply(_ location: Location) {
        navigatingViaHistory = true
        defer { navigatingViaHistory = false }
        switch location {
        case .filesystem(let path):
            loadDirectory(at: path)
        case .archive(let path, let folder, let password):
            if archivePath == path {
                showArchiveFolder(at: folder)
            } else {
                openArchive(at: path, password: password, initialFolder: folder)
            }
        }
    }

    func goBack() {
        guard let loc = backStack.popLast() else { return }
        forwardStack.append(currentLocation())
        apply(loc)
    }

    func goForward() {
        guard let loc = forwardStack.popLast() else { return }
        backStack.append(currentLocation())
        apply(loc)
    }

    @objc func goUp() {
        pushHistory()
        navigatingViaHistory = true
        defer { navigatingViaHistory = false }
        if archivePath != nil {
            if !currentArchiveFolder.isEmpty {
                let parent = (currentArchiveFolder as NSString).deletingLastPathComponent
                showArchiveFolder(at: parent == "" ? "" : parent)
            } else {
                loadDirectory(at: (currentPath as NSString).deletingLastPathComponent)
            }
        } else {
            loadDirectory(at: (currentPath as NSString).deletingLastPathComponent)
        }
    }

    // MARK: - Filesystem

    func loadDirectory(at path: String) {
        if !navigatingViaHistory && (archivePath != nil || path != currentPath) { pushHistory() }

        if archivePath != nil { archivePassword = nil }
        archivePath = nil
        currentArchiveFolder = ""
        allArchiveEntries = []
        currentPath = path
        fileList.currentDirectoryPath = path

        loadGeneration += 1
        let generation = loadGeneration
        let flat = isFlatView
        updateStatus(L("Loading…"))

        Task.detached(priority: .userInitiated) { [weak self] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                  FolderAccess.canAccess(path) else {
                await MainActor.run { [weak self] in
                    guard let self = self, self.loadGeneration == generation else { return }
                    // App Store build: a folder outside what the user granted — ask once.
                    if FolderAccess.isSandboxed, !FolderAccess.canAccess(path),
                       FolderAccess.requestAccess(to: URL(fileURLWithPath: path, isDirectory: true)) {
                        self.loadDirectory(at: path)
                        return
                    }
                    let fallback = FolderAccess.userFolder(.downloadsDirectory)
                    if fallback != path {
                        self.loadDirectory(at: fallback)
                    } else {
                        self.updateStatus(L("Directory not accessible"))
                    }
                }
                return
            }

            let entries = flat
                ? Self.enumerateFlat(root: path)
                : Self.enumerateShallow(path: path)

            await MainActor.run { [weak self] in
                guard let self = self, self.loadGeneration == generation else { return }
                self.allArchiveEntries = entries
                self.applyFilterAndReload()
                self.updatePathField()
                self.delegate?.paneDidChangeLocation(self)
            }
        }
    }

    nonisolated private static func enumerateShallow(path: String) -> [ArchiveEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let dirURL = URL(fileURLWithPath: path)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(items.count)
        for itemURL in items {
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)
            entries.append(ArchiveEntry(
                path: itemURL.lastPathComponent,
                size: size,
                compressedSize: size,
                modified: values?.contentModificationDate,
                isDirectory: isDirectory,
                crc: nil,
                encrypted: false
            ))
        }
        return sorted(entries)
    }

    /// Flat view: every file of the whole subtree, path shown relative to the root.
    nonisolated private static func enumerateFlat(root: String) -> [ArchiveEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let rootURL = URL(fileURLWithPath: root)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [ArchiveEntry] = []
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            entries.append(ArchiveEntry(
                path: relative,
                size: Int64(values?.fileSize ?? 0),
                compressedSize: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                isDirectory: false,
                crc: nil,
                encrypted: false
            ))
            if entries.count >= 50_000 { break }
        }
        return sorted(entries)
    }

    nonisolated private static func sorted(_ entries: [ArchiveEntry]) -> [ArchiveEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Archives

    func openArchive(at path: String, password: String? = nil, initialFolder: String = "") {
        if !navigatingViaHistory { pushHistory() }
        archivePath = path
        currentPath = path
        currentArchiveFolder = initialFolder
        archivePassword = password
        fileList.currentDirectoryPath = nil
        updateStatus(L("Loading archive…"))

        Task {
            do {
                let entries = try await SevenZipWrapper.listArchive(at: path, password: password)
                let hasEncrypted = entries.contains { $0.encrypted }

                await MainActor.run {
                    allArchiveEntries = entries
                    let wasNavigating = navigatingViaHistory
                    navigatingViaHistory = true
                    showArchiveFolder(at: initialFolder)
                    navigatingViaHistory = wasNavigating
                    delegate?.paneDidChangeLocation(self)

                    if hasEncrypted && password == nil {
                        delegate?.pane(self, needsPasswordFor: path,
                                       message: L("This archive contains encrypted files. Enter password to view or extract them:")) { newPassword in
                            if let np = newPassword {
                                self.archivePassword = np
                                self.updateStatus(L("Password accepted"))
                            }
                        }
                    }
                }
            } catch SevenZipError.passwordRequired {
                await MainActor.run {
                    delegate?.pane(self, needsPasswordFor: path,
                                   message: L("Please enter the password for this archive.")) { newPassword in
                        if let np = newPassword {
                            self.openArchive(at: path, password: np, initialFolder: initialFolder)
                        } else {
                            self.updateStatus(L("Ready"))
                        }
                    }
                }
            } catch {
                await MainActor.run { delegate?.pane(self, didFail: error) }
            }
        }
    }

    func showArchiveFolder(at path: String) {
        if !navigatingViaHistory { pushHistory() }
        currentArchiveFolder = path
        applyFilterAndReload()
        updatePathField()
        delegate?.paneDidChangeLocation(self)
    }

    /// Entries of the current archive folder, or every entry in flat view.
    private func archiveFolderEntries() -> [ArchiveEntry] {
        if isFlatView {
            return Self.sorted(allArchiveEntries.filter { !$0.isDirectory })
        }

        let path = currentArchiveFolder
        var result: [String: ArchiveEntry] = [:]
        let prefix = path.isEmpty ? "" : path + "/"

        for entry in allArchiveEntries {
            if entry.path == path && entry.isDirectory { continue }

            if path.isEmpty {
                if !entry.path.contains("/") {
                    result[entry.path] = entry
                } else if let rootFolder = entry.path.split(separator: "/").first.map(String.init) {
                    if result[rootFolder] == nil {
                        result[rootFolder] = ArchiveEntry(path: rootFolder, size: 0, compressedSize: 0,
                                                          modified: nil, isDirectory: true, crc: nil, encrypted: false)
                    }
                }
            } else if entry.path.hasPrefix(prefix) {
                let remainder = String(entry.path.dropFirst(prefix.count))
                if remainder.isEmpty { continue }
                if !remainder.contains("/") {
                    result[entry.path] = entry
                } else if let subFolder = remainder.split(separator: "/").first.map(String.init) {
                    let newFolderPath = prefix + subFolder
                    if result[newFolderPath] == nil {
                        result[newFolderPath] = ArchiveEntry(path: newFolderPath, size: 0, compressedSize: 0,
                                                             modified: nil, isDirectory: true, crc: nil, encrypted: false)
                    }
                }
            }
        }
        return Self.sorted(Array(result.values))
    }

    // MARK: - Filtering & display

    func setSearchQuery(_ query: String) {
        searchQuery = query.trimmingCharacters(in: .whitespaces)
        applyFilterAndReload()
    }

    func setFlatView(_ flat: Bool) {
        guard flat != isFlatView else { return }
        isFlatView = flat
        if archivePath != nil {
            applyFilterAndReload()
        } else {
            navigatingViaHistory = true
            loadDirectory(at: currentPath)
            navigatingViaHistory = false
        }
    }

    private func applyFilterAndReload() {
        let base = archivePath != nil ? archiveFolderEntries() : allArchiveEntries
        // In flat view the query matches the whole relative path, not just the name
        let filtered = searchQuery.isEmpty ? base : base.filter {
            isFlatView ? $0.path.localizedCaseInsensitiveContains(searchQuery)
                       : $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
        visibleEntries = filtered
        fileList.reloadData(with: filtered)

        if searchQuery.isEmpty {
            updateStatus(L("Items: %d", filtered.count))
        } else {
            updateStatus(L("Items: %d of %d (filtered)", filtered.count, base.count))
        }
    }

    func reload() {
        if let ap = archivePath {
            let folder = currentArchiveFolder
            navigatingViaHistory = true
            openArchive(at: ap, password: archivePassword, initialFolder: folder)
            navigatingViaHistory = false
        } else {
            navigatingViaHistory = true
            loadDirectory(at: currentPath)
            navigatingViaHistory = false
        }
    }

    // MARK: - Status & path

    private func updatePathField() {
        if archivePath != nil {
            pathField?.stringValue = currentArchiveFolder.isEmpty ? currentPath : currentPath + "/" + currentArchiveFolder
        } else {
            pathField?.stringValue = currentPath
        }
    }

    func updateStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    /// Title shown by the window when this pane is active.
    var displayTitle: String {
        if archivePath != nil {
            return (currentPath as NSString).lastPathComponent
                + (currentArchiveFolder.isEmpty ? "" : "/" + currentArchiveFolder)
        }
        return (currentPath as NSString).lastPathComponent
    }

    func isArchive(path: String) -> Bool {
        ArchiveTypes.isArchive(path: path)
    }
}

// MARK: - Address bar

extension BrowserPaneController: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard let field = control as? NSTextField else { return true }
        let path = field.stringValue

        if let ap = archivePath, path.hasPrefix(ap) {
            let remainder = String(path.dropFirst(ap.count))
            showArchiveFolder(at: remainder.hasPrefix("/") ? String(remainder.dropFirst()) : remainder)
            return true
        }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue {
                loadDirectory(at: path)
            } else if isArchive(path: path) {
                openArchive(at: path)
            }
        }
        return true
    }
}

// MARK: - File list

extension BrowserPaneController: FileListViewControllerDelegate {

    func fileListDidDoubleClick(entry: ArchiveEntry) {
        delegate?.paneDidBecomeActive(self)

        if archivePath != nil {
            if entry.isDirectory {
                showArchiveFolder(at: entry.path)
            } else {
                delegate?.pane(self, openExternally: URL(fileURLWithPath: entry.path))
            }
            return
        }

        let fullPath = (currentPath as NSString).appendingPathComponent(entry.path)
        if entry.isDirectory {
            loadDirectory(at: fullPath)
        } else if isArchive(path: fullPath) {
            openArchive(at: fullPath)
        } else {
            delegate?.pane(self, openExternally: URL(fileURLWithPath: fullPath))
        }
    }

    func fileListSelectionDidChange(entries: [ArchiveEntry]) {
        delegate?.paneDidChangeSelection(self)
        guard !entries.isEmpty else {
            updateStatus(L("Items: %d", visibleEntries.count))
            return
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        updateStatus(L("Selected: %d of %d — %@", entries.count, visibleEntries.count, ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
    }

    func fileListDidAcceptDrop(urls: [URL]) {
        delegate?.paneDidBecomeActive(self)
        delegate?.pane(self, didAcceptDrop: urls)
    }

    func fileListDidDragOut(entry: ArchiveEntry, to destinationURL: URL, completion: @escaping (Error?) -> Void) {
        guard let path = archivePath else {
            completion(NSError(domain: "TajArchive", code: -1, userInfo: [NSLocalizedDescriptionKey: L("No archive open")]))
            return
        }
        let destTargetDir = destinationURL.deletingLastPathComponent().path
        Task {
            do {
                try await SevenZipWrapper.extractFiles(
                    from: path, files: [entry.path], to: destTargetDir,
                    password: archivePassword, overwriteMode: .renameExtracting,
                    flatten: !entry.isDirectory
                )
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}
