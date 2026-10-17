import Cocoa

// MARK: - SplitCombineError

/// Failures raised while splitting a file into numbered volumes or joining
/// them back together. Messages are user-facing: they are shown verbatim in the
/// alert presented by `SplitCombineController`.
enum SplitCombineError: LocalizedError {
    case sourceNotFound(URL)
    case sourceIsDirectory(URL)
    case sourceEmpty(URL)
    case invalidVolumeSize
    case volumeSizeTooLarge(volumeSize: Int64, fileSize: Int64)
    case tooManyParts(count: Int64, limit: Int)
    case notFirstVolume(URL)
    case missingPart(name: String)
    case unreadablePart(URL)
    case truncatedSource(URL)
    case destinationExists(URL)
    case destinationDirectoryMissing(URL)
    case cannotCreateFile(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceNotFound(let url):
            return L("“%@” could not be found in %@.", url.lastPathComponent, url.deletingLastPathComponent().path)
        case .sourceIsDirectory(let url):
            return L("“%@” is a folder. Only files can be split.", url.lastPathComponent)
        case .sourceEmpty(let url):
            return L("“%@” is empty, so there is nothing to split.", url.lastPathComponent)
        case .invalidVolumeSize:
            return L("The volume size must be a whole number of bytes greater than zero, for example 100m, 1g, 500k or 1457664.")
        case .volumeSizeTooLarge(let volumeSize, let fileSize):
            return L("The volume size (%@) is not smaller than the file (%@), so splitting would produce a single part.", formatBytes(volumeSize), formatBytes(fileSize))
        case .tooManyParts(let count, let limit):
            return L("That volume size would create %d parts, more than the limit of %d. Choose a larger volume size.", Int(count), limit)
        case .notFirstVolume(let url):
            return L("“%@” is not the first volume of a split file. Select the part ending in “.001”.", url.lastPathComponent)
        case .missingPart(let name):
            return L("The part “%@” is missing. All parts from .001 onwards must be in the same folder before they can be combined.", name)
        case .unreadablePart(let url):
            return L("“%@” could not be read. Check that the file exists and that you have permission to open it.", url.lastPathComponent)
        case .truncatedSource(let url):
            return L("“%@” ended sooner than expected. The file may have been modified or removed while it was being split.", url.lastPathComponent)
        case .destinationExists(let url):
            return L("“%@” already exists in %@. Choose another name or remove the existing file first.", url.lastPathComponent, url.deletingLastPathComponent().path)
        case .destinationDirectoryMissing(let url):
            return L("The destination folder does not exist:\n%@", url.path)
        case .cannotCreateFile(let url):
            return L("“%@” could not be created in %@. Check the available space and your permission to write there.", url.lastPathComponent, url.deletingLastPathComponent().path)
        case .cancelled:
            return L("The operation was cancelled.")
        }
    }
}

/// Shared, file-local byte formatting so errors and labels read the same way.
private func formatBytes(_ value: Int64) -> String {
    return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

// MARK: - FileSplitter

/// The file-level half of Windows 7-Zip's "Split file…" / "Combine files…"
/// commands: it slices any file into `<name>.001`, `<name>.002`, … volumes and
/// concatenates such a set back into the original.
///
/// All I/O streams through a fixed-size buffer, so a multi-gigabyte file never
/// lands in memory, and every operation cleans up after itself when it fails or
/// is cancelled.
enum FileSplitter {

    /// Bytes moved per read/write. Large enough to keep the syscall overhead
    /// negligible, small enough that cancellation still feels immediate.
    static let chunkSize = 4 * 1024 * 1024

    /// Refuses to create a runaway number of files from a tiny volume size.
    static let maximumPartCount = 100_000

    // MARK: Naming

    /// `movie.mkv` + 7 -> `movie.mkv.007`. Indices past 999 simply grow another
    /// digit (`.1000`), matching 7-Zip.
    static func partName(base: String, index: Int) -> String {
        return base + "." + String(format: "%03d", index)
    }

    static func partURLs(base: String, in directory: URL, count: Int) -> [URL] {
        guard count > 0 else { return [] }
        return (1...count).map { directory.appendingPathComponent(partName(base: base, index: $0)) }
    }

    /// True when `url` looks like the first volume of a split set.
    static func isFirstVolume(_ url: URL) -> Bool {
        return url.pathExtension == "001" && !url.deletingPathExtension().lastPathComponent.isEmpty
    }

    /// Number of volumes `fileSize` bytes occupy at `volumeSize` bytes each.
    /// Returns 0 for a non-positive volume size.
    static func partCount(fileSize: Int64, volumeSize: Int64) -> Int64 {
        guard volumeSize > 0, fileSize > 0 else { return 0 }
        // Written without an intermediate sum so a huge fileSize cannot overflow.
        return fileSize / volumeSize + (fileSize % volumeSize == 0 ? 0 : 1)
    }

    // MARK: Size parsing

    /// Parses a volume size written the way 7-Zip accepts it: `1g`, `250m`,
    /// `500k` or a plain byte count such as `1457664`. Case-insensitive, spaces
    /// are ignored and a trailing `b` (as in `100mb`) is allowed. Returns nil
    /// for anything else — including negative or non-numeric text.
    static func parseSize(_ text: String) -> Int64? {
        var normalized = text.lowercased().filter { !$0.isWhitespace }
        guard !normalized.isEmpty else { return nil }

        if normalized.hasSuffix("b") {
            normalized.removeLast()
        }

        var multiplier: Int64 = 1
        switch normalized.last {
        case "k": multiplier = 1024
        case "m": multiplier = 1024 * 1024
        case "g": multiplier = 1024 * 1024 * 1024
        default: break
        }
        if multiplier != 1 {
            normalized.removeLast()
        }

        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int64(normalized) else { return nil }

        let (product, overflowed) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflowed else { return nil }
        return product
    }

    // MARK: Inspection

    /// Size of `url` in bytes.
    static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else {
            throw SplitCombineError.unreadablePart(url)
        }
        return size
    }

    /// Collects `<base>.001`, `<base>.002`, … starting at `firstPart` and
    /// stopping at the first missing index.
    ///
    /// Throws `.missingPart` when a higher-numbered volume still sits in the
    /// folder past that gap: that means the set is incomplete rather than
    /// merely short, and combining it would silently produce a corrupt file.
    static func discoverParts(firstPart: URL) throws -> [URL] {
        guard isFirstVolume(firstPart) else { throw SplitCombineError.notFirstVolume(firstPart) }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: firstPart.path) else {
            throw SplitCombineError.sourceNotFound(firstPart)
        }

        let directory = firstPart.deletingLastPathComponent()
        let base = firstPart.deletingPathExtension().lastPathComponent

        var parts: [URL] = []
        var index = 1
        while index <= maximumPartCount {
            let candidate = directory.appendingPathComponent(partName(base: base, index: index))
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { break }
            parts.append(candidate)
            index += 1
        }
        guard !parts.isEmpty else { throw SplitCombineError.sourceNotFound(firstPart) }

        // A sibling numbered beyond the end of the run means parts are missing
        // in the middle. A directory listing we cannot read is not fatal — the
        // consecutive run above is still a valid, if possibly short, set.
        if let siblings = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let prefix = base + "."
            var highest = parts.count
            for sibling in siblings {
                let name = sibling.lastPathComponent
                guard name.hasPrefix(prefix) else { continue }
                let suffix = String(name.dropFirst(prefix.count))
                // Only accept the exact shape we produce: three digits, or more
                // than three without extra zero padding.
                guard suffix.count >= 3,
                      suffix.count == 3 || !suffix.hasPrefix("0"),
                      suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = Int(suffix) else { continue }
                highest = max(highest, number)
            }
            if highest > parts.count {
                throw SplitCombineError.missingPart(name: partName(base: base, index: parts.count + 1))
            }
        }

        return parts
    }

    // MARK: Split

    /// Splits `file` into `<name>.001`, `<name>.002`, … inside
    /// `destinationDirectory`. Every part is exactly `volumeSize` bytes except
    /// the last one.
    ///
    /// `progress` is called with a percentage in 0...100 from a background
    /// thread. Cancellation is checked between chunks; when it fires, the parts
    /// written so far are deleted and `.cancelled` is thrown, so the folder is
    /// never left holding a partial set.
    ///
    /// - Returns: the created part URLs, in order.
    static func split(
        file: URL,
        volumeSize: Int64,
        destinationDirectory: URL,
        token: OperationToken?,
        progress: @escaping (Double) -> Void
    ) async throws -> [URL] {

        let fileManager = FileManager.default

        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &sourceIsDirectory) else {
            throw SplitCombineError.sourceNotFound(file)
        }
        guard !sourceIsDirectory.boolValue else { throw SplitCombineError.sourceIsDirectory(file) }

        let totalSize = try fileSize(of: file)
        guard totalSize > 0 else { throw SplitCombineError.sourceEmpty(file) }
        guard volumeSize > 0 else { throw SplitCombineError.invalidVolumeSize }
        guard volumeSize < totalSize else {
            throw SplitCombineError.volumeSizeTooLarge(volumeSize: volumeSize, fileSize: totalSize)
        }

        let count = partCount(fileSize: totalSize, volumeSize: volumeSize)
        guard count <= Int64(maximumPartCount) else {
            throw SplitCombineError.tooManyParts(count: count, limit: maximumPartCount)
        }

        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &destinationIsDirectory),
              destinationIsDirectory.boolValue else {
            throw SplitCombineError.destinationDirectoryMissing(destinationDirectory)
        }

        let targets = partURLs(base: file.lastPathComponent, in: destinationDirectory, count: Int(count))
        if let clash = targets.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            throw SplitCombineError.destinationExists(clash)
        }

        var created: [URL] = []
        do {
            let input = try openForReading(file)
            defer { try? input.close() }

            var written: Int64 = 0
            var lastReported = -1.0
            func report() {
                let percent = min(100.0, Double(written) / Double(totalSize) * 100.0)
                guard percent - lastReported >= 0.5 else { return }
                lastReported = percent
                progress(percent)
            }

            for target in targets {
                if isCancelled(token) { throw SplitCombineError.cancelled }

                guard fileManager.createFile(atPath: target.path, contents: nil) else {
                    throw SplitCombineError.cannotCreateFile(target)
                }
                created.append(target)

                let output = try openForWriting(target)
                defer { try? output.close() }

                var remaining = min(volumeSize, totalSize - written)
                while remaining > 0 {
                    if isCancelled(token) { throw SplitCombineError.cancelled }
                    let wanted = Int(min(remaining, Int64(chunkSize)))
                    guard let chunk = try input.read(upToCount: wanted), !chunk.isEmpty else {
                        throw SplitCombineError.truncatedSource(file)
                    }
                    try output.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                    written += Int64(chunk.count)
                    report()
                }
            }

            progress(100)
            return created
        } catch {
            for url in created { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    // MARK: Combine

    /// Concatenates `firstPart` and its consecutive `.002`, `.003`, … siblings
    /// into `destination`, which must not already exist.
    ///
    /// `progress` is called with a percentage in 0...100, measured against the
    /// combined size of every discovered part. A failure or cancellation removes
    /// the half-written destination before rethrowing.
    ///
    /// - Returns: `destination`, for convenience at the call site.
    @discardableResult
    static func combine(
        firstPart: URL,
        destination: URL,
        token: OperationToken?,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {

        let fileManager = FileManager.default
        let parts = try discoverParts(firstPart: firstPart)

        var totalSize: Int64 = 0
        for part in parts {
            totalSize += try fileSize(of: part)
        }

        let parent = destination.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw SplitCombineError.destinationDirectoryMissing(parent)
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SplitCombineError.destinationExists(destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw SplitCombineError.cannotCreateFile(destination)
        }

        do {
            let output = try openForWriting(destination)
            defer { try? output.close() }

            var written: Int64 = 0
            var lastReported = -1.0
            func report() {
                guard totalSize > 0 else { return }
                let percent = min(100.0, Double(written) / Double(totalSize) * 100.0)
                guard percent - lastReported >= 0.5 else { return }
                lastReported = percent
                progress(percent)
            }

            for part in parts {
                if isCancelled(token) { throw SplitCombineError.cancelled }

                let input = try openForReading(part)
                defer { try? input.close() }

                while true {
                    if isCancelled(token) { throw SplitCombineError.cancelled }
                    guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                    try output.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    report()
                }
            }

            progress(100)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Private helpers

    private static func isCancelled(_ token: OperationToken?) -> Bool {
        return token?.isCancelled == true || Task.isCancelled
    }

    private static func openForReading(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw SplitCombineError.unreadablePart(url)
        }
    }

    private static func openForWriting(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forWritingTo: url)
        } catch {
            throw SplitCombineError.cannotCreateFile(url)
        }
    }
}

// MARK: - SplitCombineController

/// Sheet-based dialogs for the two file-level commands from Windows 7-Zip's
/// File menu: "Split file…" and "Combine files…". Both gather their settings on
/// a sheet, then run the work off the main thread behind a
/// `ProgressWindowController` with a working Cancel button.
final class SplitCombineController: NSWindowController, NSTextFieldDelegate, NSComboBoxDelegate {

    // MARK: Constants

    private static let labelColumnWidth = fittingLabelWidth([L("Split to volumes:"), L("Save parts to:"), L("Combine to:")], minimum: 110)

    /// Keeps controllers alive while their sheet is on screen.
    private static var activeControllers: [SplitCombineController] = []

    /// Volume presets from the Windows dialog. The combo box shows `label`,
    /// but the field is rewritten to `value` on selection so what the user sees
    /// is exactly what gets parsed.
    private static let volumePresets: [(label: String, value: String)] = [
        (L("1457664 — 1.44 MB floppy"), "1457664"),
        ("100M", "100M"),
        (L("650M — CD"), "650M"),
        (L("700M — CD"), "700M"),
        ("4092M — FAT32", "4092M"),
        (L("4480M — DVD"), "4480M")
    ]

    // MARK: Types

    private enum Mode {
        case split(file: URL, fileSize: Int64)
        case combine(firstPart: URL, parts: [URL], totalSize: Int64)
    }

    private struct SplitRequest {
        let file: URL
        let volumeSize: Int64
        let destinationDirectory: URL
    }

    private struct CombineRequest {
        let firstPart: URL
        let destination: URL
    }

    // MARK: Properties

    private let mode: Mode

    private var volumeCombo: NSComboBox!
    private var destinationField: NSTextField!
    private var estimateLabel: NSTextField!
    private var confirmButton: NSButton!

    /// Set just before the sheet ends with `.OK`.
    private var confirmedSplit: SplitRequest?
    private var confirmedCombine: CombineRequest?

    // MARK: Shared size parser

    /// Parses `1g`, `250m`, `500k` or a plain byte count such as `1457664`
    /// (case-insensitive, spaces ignored). Returns nil for anything else.
    static func parseSize(_ text: String) -> Int64? {
        return FileSplitter.parseSize(text)
    }

    // MARK: Presentation

    /// Presents the split dialog as a sheet on `parent`. Calls `completion`
    /// exactly once: with the created part URLs when the split finishes, or
    /// `nil` on cancel or failure (the failure is reported to the user first).
    static func presentSplit(
        on parent: NSWindow,
        file: URL,
        completion: @escaping ([URL]?) -> Void
    ) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory) else {
            presentAlert(title: L("Cannot Split File"), error: SplitCombineError.sourceNotFound(file), on: parent)
            completion(nil)
            return
        }
        guard !isDirectory.boolValue else {
            presentAlert(title: L("Cannot Split File"), error: SplitCombineError.sourceIsDirectory(file), on: parent)
            completion(nil)
            return
        }

        let fileSize: Int64
        do {
            fileSize = try FileSplitter.fileSize(of: file)
        } catch {
            presentAlert(title: L("Cannot Split File"), error: error, on: parent)
            completion(nil)
            return
        }
        guard fileSize > 0 else {
            presentAlert(title: L("Cannot Split File"), error: SplitCombineError.sourceEmpty(file), on: parent)
            completion(nil)
            return
        }

        let controller = SplitCombineController(mode: .split(file: file, fileSize: fileSize))
        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let request = (response == .OK) ? controller.confirmedSplit : nil
            sheetWindow.orderOut(nil)
            activeControllers.removeAll { $0 === controller }

            guard let request = request else {
                completion(nil)
                return
            }
            runSplit(request: request, parent: parent, completion: completion)
        }
    }

    /// Presents the combine dialog as a sheet on `parent`. Calls `completion`
    /// exactly once: with the recombined file URL on success, or `nil` on
    /// cancel or failure. Refuses up front, with an alert, when `firstPart` is
    /// not a `.001` volume or when a part is missing from the middle of the set.
    static func presentCombine(
        on parent: NSWindow,
        firstPart: URL,
        completion: @escaping (URL?) -> Void
    ) {
        let parts: [URL]
        let totalSize: Int64
        do {
            parts = try FileSplitter.discoverParts(firstPart: firstPart)
            var sum: Int64 = 0
            for part in parts { sum += try FileSplitter.fileSize(of: part) }
            totalSize = sum
        } catch {
            presentAlert(title: L("Cannot Combine Files"), error: error, on: parent)
            completion(nil)
            return
        }

        let controller = SplitCombineController(
            mode: .combine(firstPart: firstPart, parts: parts, totalSize: totalSize)
        )
        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let request = (response == .OK) ? controller.confirmedCombine : nil
            sheetWindow.orderOut(nil)
            activeControllers.removeAll { $0 === controller }

            guard let request = request else {
                completion(nil)
                return
            }
            runCombine(request: request, parent: parent, completion: completion)
        }
    }

    // MARK: Initialization

    private init(mode: Mode) {
        self.mode = mode

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        switch mode {
        case .split: window.title = L("Split File")
        case .combine: window.title = L("Combine Files")
        }

        super.init(window: window)
        setupUI()
        // Size the sheet to its content instead of stretching the stack's spacing.
        if let content = window.contentView {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        contentView.addSubview(stackView)

        stackView.addArrangedSubview(makeHeader())

        switch mode {
        case .split(let file, let fileSize):
            setupSplitRows(in: stackView, file: file, fileSize: fileSize)
        case .combine(let firstPart, _, _):
            setupCombineRows(in: stackView, firstPart: firstPart)
        }

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.spacing = 12

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        confirmButton = NSButton(title: confirmButtonTitle, target: self, action: #selector(confirm))
        confirmButton.keyEquivalent = "\r" // Return
        confirmButton.bezelColor = .controlAccentColor

        buttonRow.addArrangedSubview(NSView()) // Spacer
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(confirmButton)
        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        if case .split = mode {
            updateSplitEstimate()
            window.initialFirstResponder = volumeCombo
        } else {
            window.initialFirstResponder = destinationField
        }
    }

    private var confirmButtonTitle: String {
        switch mode {
        case .split: return L("Split")
        case .combine: return L("Combine")
        }
    }

    private func makeHeader() -> NSStackView {
        let title: String
        let subtitle: String

        switch mode {
        case .split(let file, let fileSize):
            title = L("Split “%@”", file.lastPathComponent)
            subtitle = formatBytes(fileSize)
        case .combine(let firstPart, let parts, let totalSize):
            title = L("Combine “%@”", firstPart.lastPathComponent)
            subtitle = L("Parts found: %d · total %@", parts.count, formatBytes(totalSize))
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        return titleStack
    }

    private func setupSplitRows(in stackView: NSStackView, file: URL, fileSize: Int64) {
        // Volume size
        let volumeRow = createRow(label: L("Split to volumes:"))
        volumeCombo = NSComboBox()
        volumeCombo.translatesAutoresizingMaskIntoConstraints = false
        volumeCombo.usesDataSource = false
        volumeCombo.isEditable = true
        volumeCombo.completes = false
        volumeCombo.delegate = self
        volumeCombo.numberOfVisibleItems = Self.volumePresets.count
        volumeCombo.toolTip = L("Bytes, or a number followed by k, m or g — for example 100m, 1g, 500k.")
        for preset in Self.volumePresets {
            volumeCombo.addItem(withObjectValue: preset.label)
        }
        volumeCombo.stringValue = Self.defaultVolumeText(for: fileSize)
        volumeCombo.widthAnchor.constraint(equalToConstant: 220).isActive = true
        volumeRow.addArrangedSubview(volumeCombo)
        stackView.addArrangedSubview(volumeRow)

        // Live part count
        let estimateRow = createRow(label: "")
        estimateLabel = NSTextField(labelWithString: "")
        estimateLabel.translatesAutoresizingMaskIntoConstraints = false
        estimateLabel.font = .systemFont(ofSize: 11)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.lineBreakMode = .byTruncatingTail
        estimateRow.addArrangedSubview(estimateLabel)
        stackView.addArrangedSubview(estimateRow)

        // Destination folder
        let destinationRow = createRow(label: L("Save parts to:"))
        destinationField = NSTextField()
        destinationField.translatesAutoresizingMaskIntoConstraints = false
        destinationField.stringValue = file.deletingLastPathComponent().path
        destinationField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        destinationRow.addArrangedSubview(destinationField)
        destinationRow.addArrangedSubview(
            NSButton(title: L("Browse…"), target: self, action: #selector(browse))
        )
        stackView.addArrangedSubview(destinationRow)
    }

    private func setupCombineRows(in stackView: NSStackView, firstPart: URL) {
        let destinationRow = createRow(label: L("Combine to:"))
        destinationField = NSTextField()
        destinationField.translatesAutoresizingMaskIntoConstraints = false
        destinationField.stringValue = firstPart.deletingPathExtension().path
        destinationField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        destinationRow.addArrangedSubview(destinationField)
        destinationRow.addArrangedSubview(
            NSButton(title: L("Browse…"), target: self, action: #selector(browse))
        )
        stackView.addArrangedSubview(destinationRow)

        let hintRow = createRow(label: "")
        let hintLabel = NSTextField(labelWithString: L("The parts are left in place; they are only read."))
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintRow.addArrangedSubview(hintLabel)
        stackView.addArrangedSubview(hintRow)
    }

    private func createRow(label: String) -> NSStackView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.spacing = 8

        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(labelView)

        return row
    }

    /// 100 MB is a sane default for anything bigger than that; smaller files
    /// fall back to halving, which always yields a valid two-part split.
    private static func defaultVolumeText(for fileSize: Int64) -> String {
        let hundredMegabytes: Int64 = 100 * 1024 * 1024
        if fileSize > hundredMegabytes { return "100M" }
        return String(max(1, fileSize / 2))
    }

    // MARK: Live estimate

    private func updateSplitEstimate() {
        guard case .split(_, let fileSize) = mode,
              let label = estimateLabel,
              let button = confirmButton else { return }

        func show(_ text: String, valid: Bool) {
            label.stringValue = text
            label.textColor = valid ? .secondaryLabelColor : .systemOrange
            button.isEnabled = valid
        }

        let raw = volumeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            show(L("Enter a volume size, for example 100m, 1g or 1457664."), valid: false)
            return
        }
        guard let volumeSize = enteredVolumeSize() else {
            show(L("“%@” is not a size. Use bytes, or a number followed by k, m or g.", raw), valid: false)
            return
        }
        guard volumeSize > 0 else {
            show(L("The volume size must be greater than zero."), valid: false)
            return
        }
        guard volumeSize < fileSize else {
            show(L("The volume size must be smaller than the file (%@).", formatBytes(fileSize)), valid: false)
            return
        }

        let count = FileSplitter.partCount(fileSize: fileSize, volumeSize: volumeSize)
        guard count <= Int64(FileSplitter.maximumPartCount) else {
            show(L("That size would create %d parts — too many. Choose a larger volume size.", Int(count)), valid: false)
            return
        }

        let lastPartSize = fileSize - volumeSize * (count - 1)
        var text = L("Parts to create: %d, %@ each", Int(count), formatBytes(volumeSize))
        if lastPartSize != volumeSize {
            text += " " + L("(last part %@)", formatBytes(lastPartSize))
        }
        show(text, valid: true)
    }

    /// The parsed contents of the volume field. Preset rows carry a descriptive
    /// suffix ("650M — CD"), so an exact preset match resolves to its value;
    /// anything else must parse on its own.
    private func enteredVolumeSize() -> Int64? {
        let raw = volumeCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = Self.volumePresets.first(where: { $0.label == raw }) {
            return FileSplitter.parseSize(preset.value)
        }
        return FileSplitter.parseSize(raw)
    }

    // MARK: Actions

    @objc private func browse() {
        guard let window = window else { return }

        switch mode {
        case .split:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            let current = FolderAccess.expandTilde(destinationField.stringValue)
            if !current.isEmpty {
                panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
            }
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.destinationField.stringValue = url.path
                }
            }

        case .combine:
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            let current = URL(
                fileURLWithPath: FolderAccess.expandTilde(destinationField.stringValue)
            )
            panel.nameFieldStringValue = current.lastPathComponent
            panel.directoryURL = current.deletingLastPathComponent()
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.destinationField.stringValue = url.path
                }
            }
        }
    }

    @objc private func confirm() {
        switch mode {
        case .split(let file, let fileSize):
            confirmSplit(file: file, fileSize: fileSize)
        case .combine(let firstPart, let parts, _):
            confirmCombine(firstPart: firstPart, parts: parts)
        }
    }

    @objc private func cancel() {
        confirmedSplit = nil
        confirmedCombine = nil
        endSheet(returnCode: .cancel)
    }

    private func confirmSplit(file: URL, fileSize: Int64) {
        guard let volumeSize = enteredVolumeSize() else {
            showValidationAlert(
                L("Invalid Volume Size"),
                L("Enter a number of bytes, or a number followed by k, m or g — for example 100m, 1g, 500k or 1457664.")
            )
            return
        }
        guard volumeSize > 0 else {
            showValidationAlert(L("Invalid Volume Size"), L("The volume size must be greater than zero."))
            return
        }
        guard volumeSize < fileSize else {
            showValidationAlert(
                L("Invalid Volume Size"),
                L("The volume size must be smaller than the file (%@), otherwise there is nothing to split.", formatBytes(fileSize))
            )
            return
        }

        let count = FileSplitter.partCount(fileSize: fileSize, volumeSize: volumeSize)
        guard count <= Int64(FileSplitter.maximumPartCount) else {
            showValidationAlert(
                L("Too Many Parts"),
                L("That volume size would create %d parts, more than the limit of %d. Choose a larger volume size.", Int(count), FileSplitter.maximumPartCount)
            )
            return
        }

        guard let directory = validatedDestinationDirectory() else { return }

        let request = SplitRequest(file: file, volumeSize: volumeSize, destinationDirectory: directory)
        let targets = FileSplitter.partURLs(
            base: file.lastPathComponent,
            in: directory,
            count: Int(count)
        )
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            confirmedSplit = request
            endSheet(returnCode: .OK)
            return
        }

        confirmReplacement(of: existing) { [weak self] replace in
            guard let self = self, replace else { return }
            for url in existing {
                try? FileManager.default.removeItem(at: url)
            }
            self.confirmedSplit = request
            self.endSheet(returnCode: .OK)
        }
    }

    private func confirmCombine(firstPart: URL, parts: [URL]) {
        guard let destination = validatedDestinationFile() else { return }

        let partPaths = Set(parts.map { $0.standardizedFileURL.path })
        guard !partPaths.contains(destination.path) else {
            showValidationAlert(
                L("Invalid Destination"),
                L("The combined file cannot be written over one of the parts. Choose a different name.")
            )
            return
        }

        let request = CombineRequest(firstPart: firstPart, destination: destination)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            confirmedCombine = request
            endSheet(returnCode: .OK)
            return
        }

        confirmReplacement(of: [destination]) { [weak self] replace in
            guard let self = self, replace else { return }
            try? FileManager.default.removeItem(at: destination)
            self.confirmedCombine = request
            self.endSheet(returnCode: .OK)
        }
    }

    // MARK: Validation helpers

    /// Resolves the destination folder for a split, reporting the reason to the
    /// user and returning nil when it is not usable.
    private func validatedDestinationDirectory() -> URL? {
        let raw = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showValidationAlert(L("Invalid Destination"), L("Choose a folder for the parts."))
            return nil
        }
        let expanded = FolderAccess.expandTilde(raw)
        guard expanded.hasPrefix("/") else {
            showValidationAlert(
                L("Invalid Destination"),
                L("The destination must be an absolute path (for example /Users/you/Desktop or ~/Desktop).")
            )
            return nil
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showValidationAlert(L("Invalid Destination"), L("The destination folder does not exist:\n%@", url.path))
            return nil
        }
        return url
    }

    /// Resolves the destination file for a combine, reporting the reason to the
    /// user and returning nil when it is not usable.
    private func validatedDestinationFile() -> URL? {
        let raw = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showValidationAlert(L("Invalid Destination"), L("Enter a name for the combined file."))
            return nil
        }
        let expanded = FolderAccess.expandTilde(raw)
        guard expanded.hasPrefix("/") else {
            showValidationAlert(
                L("Invalid Destination"),
                L("The destination must be an absolute path (for example /Users/you/Desktop/movie.mkv).")
            )
            return nil
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else {
            showValidationAlert(L("Invalid Destination"), L("Enter a name for the combined file."))
            return nil
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showValidationAlert(L("Invalid Destination"), L("The destination folder does not exist:\n%@", parent.path))
            return nil
        }
        var destinationIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &destinationIsDirectory),
           destinationIsDirectory.boolValue {
            showValidationAlert(L("Invalid Destination"), L("“%@” is a folder. Enter a file name.", url.lastPathComponent))
            return nil
        }
        return url
    }

    /// Asks before overwriting files the user already has. `handler` runs only
    /// on an explicit Replace.
    private func confirmReplacement(of urls: [URL], handler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        if urls.count == 1, let single = urls.first {
            alert.messageText = L("“%@” already exists", single.lastPathComponent)
            alert.informativeText = L("Replacing it deletes the current file in %@.", single.deletingLastPathComponent().path)
        } else {
            alert.messageText = L("%d files already exist", urls.count)
            alert.informativeText = L("Parts with these names are already in the destination folder. Replacing them deletes the current files.")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))

        if let window = window {
            alert.beginSheetModal(for: window) { response in
                handler(response == .alertFirstButtonReturn)
            }
        } else {
            handler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func showValidationAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: returnCode)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: Running the work

    private static func runSplit(
        request: SplitRequest,
        parent: NSWindow,
        completion: @escaping ([URL]?) -> Void
    ) {
        let name = request.file.lastPathComponent
        let token = OperationToken()
        let progressController = ProgressWindowController(
            operationName: L("Splitting %@…", name),
            token: token
        )
        progressController.showWindow(nil)

        Task.detached(priority: .userInitiated) {
            do {
                let parts = try await FileSplitter.split(
                    file: request.file,
                    volumeSize: request.volumeSize,
                    destinationDirectory: request.destinationDirectory,
                    token: token,
                    progress: { percent in
                        // The reporter runs on the I/O thread; the window is main-actor bound.
                        Task { @MainActor in
                            progressController.updateProgress(percent: percent, file: name)
                        }
                    }
                )
                await MainActor.run {
                    progressController.close()
                    if let first = parts.first {
                        NSWorkspace.shared.activateFileViewerSelecting([first])
                    }
                    completion(parts)
                }
            } catch SplitCombineError.cancelled {
                await MainActor.run {
                    progressController.close()
                    completion(nil)
                }
            } catch {
                await MainActor.run {
                    progressController.close()
                    presentAlert(title: L("Split Failed"), error: error, on: parent)
                    completion(nil)
                }
            }
        }
    }

    private static func runCombine(
        request: CombineRequest,
        parent: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        let name = request.destination.lastPathComponent
        let token = OperationToken()
        let progressController = ProgressWindowController(
            operationName: L("Combining into %@…", name),
            token: token
        )
        progressController.showWindow(nil)

        Task.detached(priority: .userInitiated) {
            do {
                let combined = try await FileSplitter.combine(
                    firstPart: request.firstPart,
                    destination: request.destination,
                    token: token,
                    progress: { percent in
                        // The reporter runs on the I/O thread; the window is main-actor bound.
                        Task { @MainActor in
                            progressController.updateProgress(percent: percent, file: name)
                        }
                    }
                )
                await MainActor.run {
                    progressController.close()
                    NSWorkspace.shared.activateFileViewerSelecting([combined])
                    completion(combined)
                }
            } catch SplitCombineError.cancelled {
                await MainActor.run {
                    progressController.close()
                    completion(nil)
                }
            } catch {
                await MainActor.run {
                    progressController.close()
                    presentAlert(title: L("Combine Failed"), error: error, on: parent)
                    completion(nil)
                }
            }
        }
    }

    private static func presentAlert(title: String, error: Error, on window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window = window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSTextFieldDelegate / NSComboBoxDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let control = obj.object as? NSControl, control === volumeCombo else { return }
        updateSplitEstimate()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = volumeCombo else { return }
        let index = combo.indexOfSelectedItem
        guard index >= 0, index < Self.volumePresets.count else { return }
        let value = Self.volumePresets[index].value
        // The selection is applied to the field after this notification, so the
        // bare value has to be written back on the next runloop pass.
        DispatchQueue.main.async { [weak self] in
            self?.volumeCombo?.stringValue = value
            self?.updateSplitEstimate()
        }
    }
}
