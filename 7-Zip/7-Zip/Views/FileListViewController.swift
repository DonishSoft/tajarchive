import Cocoa
import UniformTypeIdentifiers

protocol FileListViewControllerDelegate: AnyObject {
    func fileListDidDoubleClick(entry: ArchiveEntry)
    func fileListDidAcceptDrop(urls: [URL])
    func fileListDidDragOut(entry: ArchiveEntry, to destinationURL: URL, completion: @escaping (Error?) -> Void)
    func fileListSelectionDidChange(entries: [ArchiveEntry])
}

/// NSTableView that selects the clicked row before showing the context menu,
/// matching Finder behavior (menu applies to the row under the cursor).
final class ContextAwareTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

/// Table view controller for displaying files/folders or archive contents
class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Properties

    weak var delegate: FileListViewControllerDelegate?

    /// Set when browsing the real filesystem (drag-out then uses real file URLs);
    /// nil while browsing inside an archive (drag-out uses file promises).
    var currentDirectoryPath: String? {
        didSet { updateColumnsForLocation() }
    }

    /// Packed size and CRC only mean something inside an archive.
    private func updateColumnsForLocation() {
        guard isViewLoaded else { return }
        let inArchive = currentDirectoryPath == nil
        for id in [Column.packed, Column.crc] {
            tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id.rawValue))?.isHidden = !inArchive
        }
    }

    /// Exposed so the owning pane can take keyboard focus for it.
    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var entries: [ArchiveEntry] = []

    var selectedPaths: [String] {
        return tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0].path : nil }
    }

    var selectedEntries: [ArchiveEntry] {
        return tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    // MARK: - Column Identifiers

    private enum Column: String {
        case name = "Name"
        case size = "Size"
        case packed = "Packed Size"
        case modified = "Modified"
        case crc = "CRC"
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupTableView()
    }

    // MARK: - Setup

    private func setupTableView() {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        tableView = ContextAwareTableView()
        tableView.style = .automatic
        // The name column takes whatever width the window gives the list.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(doubleClickAction)
        tableView.target = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        addColumn(id: .name, title: L("column.name"), width: 420, minWidth: 160)
        addColumn(id: .size, title: L("column.size"), width: 90, minWidth: 60)
        addColumn(id: .packed, title: L("column.packed"), width: 90, minWidth: 60)
        addColumn(id: .modified, title: L("column.modified"), width: 135, minWidth: 100)
        addColumn(id: .crc, title: L("column.crc"), width: 80, minWidth: 60)
        // Restores the widths the user dragged last time (set after the columns exist).
        tableView.autosaveName = "FileList"
        tableView.autosaveTableColumns = true
        updateColumnsForLocation()

        scrollView.documentView = tableView
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func addColumn(id: Column, title: String, width: CGFloat, minWidth: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id.rawValue))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true)
        column.headerToolTip = title
        if id == .size || id == .packed { column.headerCell.alignment = .right }
        tableView.addTableColumn(column)
    }

    // MARK: - Data

    func reloadData(with entries: [ArchiveEntry]) {
        self.entries = entries
        applyListPreferences()
        tableView.reloadData()
    }

    /// Settings → General → File list. Read on every reload, so a change shows up the
    /// next time a folder or archive is opened.
    private func applyListPreferences() {
        tableView.gridStyleMask = AppSettings.showGridLines
            ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask] : []
        tableView.usesAlternatingRowBackgroundColors = !AppSettings.showGridLines
        tableView.action = AppSettings.singleClickToOpen ? #selector(singleClickAction) : nil
    }

    func setContextMenu(_ menu: NSMenu) {
        tableView.menu = menu
    }

    /// Adds or removes rows whose name matches a glob, for the select-by-mask command.
    func applySelectionMask(_ pattern: String, select: Bool) -> Int {
        var indexes = tableView.selectedRowIndexes
        var affected = 0
        for (index, entry) in entries.enumerated()
        where SelectByMaskController.matches(name: entry.name, pattern: pattern) {
            affected += 1
            if select { indexes.insert(index) } else { indexes.remove(index) }
        }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        return affected
    }

    // MARK: - Actions

    @objc private func doubleClickAction() {
        let row = tableView.clickedRow
        guard row >= 0 && row < entries.count else { return }
        delegate?.fileListDidDoubleClick(entry: entries[row])
    }

    /// Single-click opening: a plain click opens; ⌘ and ⇧ clicks still extend the selection.
    @objc private func singleClickAction() {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift]) ?? []
        guard modifiers.isEmpty else { return }
        doubleClickAction()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Ignore drags that originate from this very table (drag-out reordering makes no sense here)
        if info.draggingSource as? NSTableView === tableView { return [] }
        let types = info.draggingPasteboard.types ?? []
        if types.contains(.fileURL) {
            return .copy
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            delegate?.fileListDidAcceptDrop(urls: urls)
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        // Filesystem mode: put the real file URL on the pasteboard — Finder copies it directly.
        if let dir = currentDirectoryPath {
            let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(entry.path))
            return url as NSURL
        }

        // Archive mode: promise-based extraction on drop
        let typeIdentifier = UTType(filenameExtension: entry.fileExtension)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: typeIdentifier, delegate: self)
        provider.userInfo = entry
        return provider
    }

    // MARK: - NSTableViewDelegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        delegate?.fileListSelectionDidChange(entries: selectedEntries)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn,
              let columnId = Column(rawValue: column.identifier.rawValue),
              row < entries.count else {
            return nil
        }

        let entry = entries[row]
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView)
            ?? makeCell(for: columnId, identifier: column.identifier)

        switch columnId {
        case .name:
            cell.textField?.stringValue = entry.name
            cell.textField?.textColor = entry.encrypted ? .systemOrange : .labelColor
            cell.imageView?.image = icon(for: entry)
        case .size:
            cell.textField?.stringValue = entry.isDirectory ? "" : entry.formattedSize
        case .packed:
            // In a solid block only the first file carries the packed size; 7-Zip leaves
            // the others blank rather than claiming they take no space.
            let unknown = entry.compressedSize == 0 && entry.size > 0
            cell.textField?.stringValue = (entry.isDirectory || unknown) ? "" : entry.formattedCompressedSize
        case .modified:
            cell.textField?.stringValue = entry.formattedDate
        case .crc:
            cell.textField?.stringValue = entry.crc ?? ""
        }
        return cell
    }

    /// One reusable cell per column, text centred vertically like Finder's list view.
    private func makeCell(for column: Column, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text

        var constraints = [
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        ]
        if column == .name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2))
        }
        switch column {
        case .size, .packed: text.alignment = .right
        case .crc: text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        default: break
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    /// Real Finder icons for files on disk (custom folder icons, app icons) when the
    /// "Show real file icons" setting is on; otherwise icons by file type.
    private func icon(for entry: ArchiveEntry) -> NSImage {
        if let directory = currentDirectoryPath, AppSettings.showRealFileIcons {
            return NSWorkspace.shared.icon(forFile: (directory as NSString).appendingPathComponent(entry.path))
        }
        if entry.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        if !AppSettings.showRealFileIcons {
            return NSWorkspace.shared.icon(for: .data)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: entry.fileExtension) ?? .data)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 22
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key else { return }

        entries.sort { lhs, rhs in
            let ascending = sortDescriptor.ascending

            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }

            let result: ComparisonResult
            switch Column(rawValue: key) {
            case .name:
                result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            case .size:
                result = lhs.size < rhs.size ? .orderedAscending : (lhs.size > rhs.size ? .orderedDescending : .orderedSame)
            case .packed:
                result = lhs.compressedSize < rhs.compressedSize ? .orderedAscending : (lhs.compressedSize > rhs.compressedSize ? .orderedDescending : .orderedSame)
            case .modified:
                let d1 = lhs.modified ?? Date.distantPast
                let d2 = rhs.modified ?? Date.distantPast
                result = d1.compare(d2)
            case .crc:
                result = (lhs.crc ?? "").compare(rhs.crc ?? "")
            case .none:
                result = .orderedSame
            }

            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        tableView.reloadData()
    }
}

// MARK: - NSFilePromiseProviderDelegate

extension FileListViewController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let entry = filePromiseProvider.userInfo as? ArchiveEntry else { return "file" }
        return (entry.path as NSString).lastPathComponent
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let entry = filePromiseProvider.userInfo as? ArchiveEntry else {
            completionHandler(NSError(domain: "TajArchive", code: -1, userInfo: nil))
            return
        }

        delegate?.fileListDidDragOut(entry: entry, to: url, completion: completionHandler)
    }
}
