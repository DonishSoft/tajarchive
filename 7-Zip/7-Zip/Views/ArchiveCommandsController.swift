import Cocoa

// MARK: - SelectionMaskAction

/// Which of the two 7-Zip file-manager mask commands is running
/// (Windows 7-Zip binds them to numpad `+` and numpad `-`).
enum SelectionMaskAction {
    case select
    case deselect

    var windowTitle: String {
        switch self {
        case .select: return L("Select by Mask")
        case .deselect: return L("Deselect by Mask")
        }
    }

    var actionButtonTitle: String {
        switch self {
        case .select: return L("Select")
        case .deselect: return L("Deselect")
        }
    }

    var promptText: String {
        switch self {
        case .select: return L("Select items matching this mask:")
        case .deselect: return L("Deselect items matching this mask:")
        }
    }
}

// MARK: - SelectByMaskController

/// Sheet for 7-Zip's "Select/Deselect by pattern" commands.
///
/// The dialog only *collects* a mask; applying it to a selection is the caller's
/// job — feed each visible row's name to ``SelectByMaskController/matches(name:pattern:)``.
final class SelectByMaskController: NSWindowController {

    // MARK: Constants

    // `nonisolated` throughout the file marks the members that are pure logic or
    // engine calls. NSWindowController is @MainActor, so without it every static
    // here would inherit main-actor isolation and the mask matcher, the ZIP byte
    // writer and the 7zz staging work would all be pinned to the UI thread.
    nonisolated static let maskHistoryKey = "SelectMaskHistory"
    nonisolated private static let historyLimit = 8
    private static let defaultMask = "*.*"
    private static let labelColumnWidth = fittingLabelWidth([L("Mask:")], minimum: 90)

    /// Keeps controllers alive while their sheet is on screen.
    private static var activeControllers: [SelectByMaskController] = []

    // MARK: Properties

    private let action: SelectionMaskAction
    private var maskCombo: NSComboBox!

    /// Set by the action button just before the sheet ends with `.OK`.
    private var confirmedMask: String?

    // MARK: Presentation

    /// Presents the mask dialog as a sheet on `parent`. Calls `completion` exactly
    /// once: with the trimmed mask on OK, or `nil` on Cancel.
    static func present(
        on parent: NSWindow,
        action: SelectionMaskAction,
        completion: @escaping (String?) -> Void
    ) {
        let controller = SelectByMaskController(action: action)

        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let mask = (response == .OK) ? controller.confirmedMask : nil
            if let mask = mask {
                rememberMask(mask)
            }
            sheetWindow.orderOut(nil)
            completion(mask)
            activeControllers.removeAll { $0 === controller }
        }
    }

    // MARK: Initialization

    private init(action: SelectionMaskAction) {
        self.action = action

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = action.windowTitle

        super.init(window: window)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Mask History

    nonisolated static func maskHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: maskHistoryKey) ?? []
    }

    nonisolated private static func rememberMask(_ mask: String) {
        var history = maskHistory()
        history.removeAll { $0 == mask }
        history.insert(mask, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        UserDefaults.standard.set(history, forKey: maskHistoryKey)
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

        let titleLabel = NSTextField(labelWithString: action.promptText)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(titleLabel)

        // Mask field (combo box remembers recent masks)
        let maskRow = createRow(label: L("Mask:"))
        maskCombo = NSComboBox()
        maskCombo.translatesAutoresizingMaskIntoConstraints = false
        maskCombo.usesDataSource = false
        maskCombo.isEditable = true
        maskCombo.completes = false
        maskCombo.numberOfVisibleItems = Self.historyLimit
        let history = Self.maskHistory()
        if !history.isEmpty {
            maskCombo.addItems(withObjectValues: history)
        }
        maskCombo.stringValue = history.first ?? Self.defaultMask
        maskCombo.widthAnchor.constraint(equalToConstant: 260).isActive = true
        maskRow.addArrangedSubview(maskCombo)
        stackView.addArrangedSubview(maskRow)

        let hintLabel = NSTextField(labelWithString: L("“*” matches any characters, “?” matches exactly one. Case-insensitive."))
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(hintLabel)

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.spacing = 12

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let okButton = NSButton(title: action.actionButtonTitle, target: self, action: #selector(confirm))
        okButton.keyEquivalent = "\r" // Return
        okButton.bezelColor = .controlAccentColor

        buttonRow.addArrangedSubview(NSView()) // Spacer
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(okButton)
        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        window.initialFirstResponder = maskCombo
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

    // MARK: Actions

    @objc private func confirm() {
        let mask = maskCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mask.isEmpty else {
            let alert = NSAlert()
            alert.messageText = L("Invalid Mask")
            alert.informativeText = L("Enter a mask, for example *.txt — or * to match everything.")
            alert.alertStyle = .warning
            if let window = window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        confirmedMask = mask
        endSheet(returnCode: .OK)
    }

    @objc private func cancel() {
        confirmedMask = nil
        endSheet(returnCode: .cancel)
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: returnCode)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: - Mask Matching

    /// Matches `name` against a Windows-style file mask.
    ///
    /// Semantics — deliberately hand-rolled rather than `NSPredicate` LIKE (which
    /// treats `?`/`*` differently and applies its own normalization) or `fnmatch`
    /// (which is byte-oriented and treats `/` and leading dots specially):
    ///
    /// - `*` matches any run of characters, including none, including `.` and `/`.
    /// - `?` matches exactly one character — one Swift `Character`, i.e. one
    ///   grapheme cluster, so an emoji or a base+combining-mark pair counts as one.
    /// - Matching is case-insensitive and anchored: the *whole* name must match.
    /// - Nothing else is special. `[`, `]`, `{`, `}` and `\` are literal characters,
    ///   which is what a user typing `weird[1].*` expects.
    ///
    /// Consequences worth knowing before wiring this up:
    /// - `*` matches everything, extension or not ("Makefile", ".hidden", "a.txt").
    /// - `*.txt` matches "a.txt" but not "a.txt.bak" — the name has to *end* in ".txt".
    /// - `*.*` therefore matches only names containing a dot. That is 7-Zip's own
    ///   behaviour; cmd.exe's legacy "`*.*` means literally everything" quirk is
    ///   intentionally not reproduced. Change only this line of reasoning if the
    ///   product decision flips — the algorithm below needs no special cases.
    nonisolated static func matches(name: String, pattern: String) -> Bool {
        // Lowercasing both sides gives Unicode-aware case folding; `Character`
        // equality then compares by canonical equivalence, so an NFC "é" from an
        // archive header matches an NFD "é" typed on macOS.
        let subject = Array(name.lowercased())
        let mask = Array(pattern.lowercased())

        let subjectCount = subject.count
        let maskCount = mask.count

        // Bottom-up DP over prefixes.
        // previous[j] == "mask[0..<j] matches subject[0..<i]" for the row already built.
        var previous = [Bool](repeating: false, count: maskCount + 1)
        var current = [Bool](repeating: false, count: maskCount + 1)

        // Row 0: an empty name is matched only by a leading run of "*".
        previous[0] = true
        for j in 0..<maskCount {
            previous[j + 1] = previous[j] && mask[j] == "*"
        }

        if subjectCount == 0 {
            return previous[maskCount]
        }

        for i in 0..<subjectCount {
            current[0] = false // a non-empty name never matches an empty mask
            for j in 0..<maskCount {
                switch mask[j] {
                case "*":
                    // Either the star matches nothing (same row, shorter mask) or it
                    // swallows subject[i] (previous row, same mask).
                    current[j + 1] = current[j] || previous[j + 1]
                case "?":
                    current[j + 1] = previous[j]
                default:
                    current[j + 1] = previous[j] && mask[j] == subject[i]
                }
            }
            swap(&previous, &current)
        }

        return previous[maskCount]
    }

    /// Convenience: indices of `names` matching `pattern`, in input order.
    nonisolated static func matchingIndices(in names: [String], pattern: String) -> [Int] {
        return names.enumerated().compactMap { matches(name: $0.element, pattern: pattern) ? $0.offset : nil }
    }
}

// MARK: - ArchiveCommentController

/// Sheet for 7-Zip's archive-comment command (Ctrl+Z on Windows).
///
/// See ``ArchiveCommentController/writeComment(archivePath:comment:)`` for the
/// important caveat: the 7zz command-line tool can *read* comments but cannot
/// write them, so writing is done by editing the ZIP end-of-central-directory
/// record directly, and is only possible for ZIP-family archives.
final class ArchiveCommentController: NSWindowController {

    // MARK: Constants

    /// ZIP hard limit: the EOCD stores the comment length in a UInt16.
    nonisolated static let maximumCommentLength = 0xFFFF

    /// Keeps controllers alive while their sheet is on screen.
    private static var activeControllers: [ArchiveCommentController] = []

    // MARK: Properties

    private let archivePath: String
    private let currentComment: String
    private let isEditable: Bool

    private var textView: NSTextView!

    /// Set by Save just before the sheet ends with `.OK`.
    private var confirmedComment: String?

    // MARK: Presentation

    /// Presents the comment editor as a sheet on `parent`. Calls `completion`
    /// exactly once: with the new comment text on Save, or `nil` on Cancel.
    ///
    /// When the archive cannot carry a writable comment (anything that is not a
    /// ZIP-family container) the sheet is shown read-only and `completion` always
    /// receives `nil`.
    static func present(
        on parent: NSWindow,
        archivePath: String,
        currentComment: String,
        completion: @escaping (String?) -> Void
    ) {
        let controller = ArchiveCommentController(
            archivePath: archivePath,
            currentComment: currentComment,
            isEditable: canWriteComment(archivePath: archivePath)
        )

        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let comment = (response == .OK) ? controller.confirmedComment : nil
            sheetWindow.orderOut(nil)
            completion(comment)
            activeControllers.removeAll { $0 === controller }
        }
    }

    // MARK: Initialization

    private init(archivePath: String, currentComment: String, isEditable: Bool) {
        self.archivePath = archivePath
        self.currentComment = currentComment
        self.isEditable = isEditable

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Comment")
        window.minSize = NSSize(width: 420, height: 260)

        super.init(window: window)
        setupUI()
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
        stackView.spacing = 10
        contentView.addSubview(stackView)

        let titleLabel = NSTextField(labelWithString: L("Comment for “%@”", (archivePath as NSString).lastPathComponent))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(titleLabel)

        // Scrollable multi-line editor
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Comments are stored verbatim — never let macOS "improve" the text.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = currentComment
        textView.isEditable = isEditable
        textView.isSelectable = true
        scrollView.documentView = textView
        self.textView = textView

        stackView.addArrangedSubview(scrollView)

        let footnote = NSTextField(labelWithString: isEditable
            ? L("Stored in the ZIP end-of-central-directory record. Press ⌘↩ to save.")
            : L("This archive format cannot store a comment, so the text above is read-only."))
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.lineBreakMode = .byWordWrapping
        footnote.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(footnote)

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.spacing = 12

        let cancelButton = NSButton(
            title: isEditable ? L("Cancel") : L("Close"),
            target: self,
            action: #selector(cancel)
        )
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        buttonRow.addArrangedSubview(NSView()) // Spacer
        buttonRow.addArrangedSubview(cancelButton)

        if isEditable {
            let saveButton = NSButton(title: L("Save"), target: self, action: #selector(save))
            // Return has to stay available for typing newlines, so Save is ⌘↩.
            saveButton.keyEquivalent = "\r"
            saveButton.keyEquivalentModifierMask = [.command]
            saveButton.bezelColor = .controlAccentColor
            buttonRow.addArrangedSubview(saveButton)
        }

        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            scrollView.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            footnote.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        window.initialFirstResponder = textView
    }

    // MARK: Actions

    @objc private func save() {
        let comment = textView.string
        if comment.utf8.count > Self.maximumCommentLength {
            let alert = NSAlert()
            alert.messageText = L("Comment Too Long")
            alert.informativeText = L("A ZIP comment is limited to %d bytes; this one is %d.", Self.maximumCommentLength, comment.utf8.count)
            alert.alertStyle = .warning
            if let window = window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        confirmedComment = comment
        endSheet(returnCode: .OK)
    }

    @objc private func cancel() {
        confirmedComment = nil
        endSheet(returnCode: .cancel)
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: returnCode)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: - Reading

    /// Reads the archive-level comment via `7zz l -slt`. Returns "" when the
    /// archive has no comment (7zz simply omits the field in that case).
    ///
    /// This goes through 7zz rather than reading ZIP bytes directly because 7zz
    /// surfaces comments for every format that has them — ZIP and RAR alike.
    nonisolated static func readComment(archivePath: String) async throws -> String {
        // TAJ is our own container and is not readable by 7zz; it has no comment field.
        if archivePath.lowercased().hasSuffix(".taj") { return "" }

        let output = try await SevenZipWrapper.runProcess(
            arguments: ["l", "-slt", "--", archivePath],
            password: nil
        )
        return parseComment(fromListing: output)
    }

    /// Extracts the archive-level `Comment` value out of `7zz l -slt` output.
    ///
    /// Only the header block (everything before the `----------` separator) is
    /// considered — individual ZIP entries carry their own `Comment = ` field and
    /// must not be mistaken for the archive comment.
    ///
    /// 7zz prints a one-line comment inline:
    ///
    ///     Comment = Just one single line
    ///
    /// and a multi-line comment as a brace-delimited block:
    ///
    ///     Comment =
    ///     {
    ///     first line
    ///     second line
    ///     }
    ///
    /// The braces are not escaped, so a comment may itself contain a `}` line; the
    /// *last* `}` in the block is therefore the real terminator.
    nonisolated static func parseComment(fromListing output: String) -> String {
        var headerLines: [String] = []
        var inHeader = false

        for line in output.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.hasPrefix("----------") { break }
            if line.hasPrefix("Listing archive:") {
                inHeader = true
                continue
            }
            if inHeader { headerLines.append(line) }
        }

        guard let commentIndex = headerLines.firstIndex(where: { line in
            guard let eqIndex = line.firstIndex(of: "=") else { return false }
            return String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces) == "Comment"
        }) else {
            return ""
        }

        let commentLine = headerLines[commentIndex]
        // Safe: firstIndex(of: "=") already succeeded for this line.
        let eqIndex = commentLine.firstIndex(of: "=")!
        let inlineValue = String(commentLine[commentLine.index(after: eqIndex)...])
            .trimmingCharacters(in: .whitespaces)

        if !inlineValue.isEmpty {
            return inlineValue
        }

        // Multi-line form: the next line must be the opening brace.
        let blockStart = commentIndex + 1
        guard blockStart < headerLines.count,
              headerLines[blockStart].trimmingCharacters(in: .whitespaces) == "{" else {
            return ""
        }

        let body = Array(headerLines[(blockStart + 1)...])
        guard let terminator = body.lastIndex(of: "}") else {
            return body.joined(separator: "\n")
        }
        return body[..<terminator].joined(separator: "\n")
    }

    // MARK: - Writing

    /// Whether ``writeComment(archivePath:comment:)`` can succeed for this file.
    ///
    /// True exactly when the file ends in a valid ZIP end-of-central-directory
    /// record — which covers .zip, .zipx, .jar, .docx, self-extracting ZIPs and
    /// ZIP64, and correctly excludes 7z, tar, rar and friends.
    nonisolated static func canWriteComment(archivePath: String) -> Bool {
        return (try? locateEndOfCentralDirectory(atPath: archivePath)) != nil
    }

    /// Writes the archive-level comment.
    ///
    /// **The 7zz command-line tool cannot do this.** It reads comments (`l -slt`)
    /// and faithfully preserves an existing one across `a`, `u`, `d` and `rn`, but
    /// it exposes no switch that sets one: every `-m` spelling tried (`-mcomment=`,
    /// `-mcm=`, `-mc=`, `-mzc=`, `-mcmt=`, …) fails with `E_INVALIDARG` exactly the
    /// way a nonsense property like `-mfoobarbaz=1` does, while a real ZIP property
    /// such as `-mcu=on` is accepted. Comment editing lives only in the Windows GUI
    /// file manager, which drives the archive object directly rather than the CLI.
    ///
    /// So this writes the comment itself, which for ZIP is a small, exactly
    /// specified operation: the comment is the tail of the end-of-central-directory
    /// record, preceded by its UInt16 length. Nothing is re-compressed and no entry
    /// data is touched — only the last few bytes of the file are rewritten, and
    /// 7zz reads the result straight back.
    ///
    /// - Throws: `SevenZipError.archiveNotFound` if the file is missing,
    ///   `SevenZipError.commandFailed` if the format has no comment field or the
    ///   comment exceeds the 65535-byte ZIP limit.
    nonisolated static func writeComment(archivePath: String, comment: String) async throws {
        guard FileManager.default.fileExists(atPath: archivePath) else {
            throw SevenZipError.archiveNotFound
        }

        let commentData = Data(comment.utf8)
        guard commentData.count <= maximumCommentLength else {
            throw SevenZipError.commandFailed(
                L("This comment is %d bytes; the ZIP format stores comments in a 16-bit length field, so %d bytes is the maximum.", commentData.count, maximumCommentLength)
            )
        }

        let eocdOffset: UInt64
        do {
            eocdOffset = try locateEndOfCentralDirectory(atPath: archivePath)
        } catch {
            throw SevenZipError.commandFailed(
                L("Only ZIP archives can store a comment. “%@” is not a ZIP archive, and the 7-Zip engine cannot write a comment into any other format.", (archivePath as NSString).lastPathComponent)
            )
        }

        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: archivePath))
        defer { try? handle.close() }

        // Comment length lives 20 bytes into the 22-byte EOCD record, immediately
        // followed by the comment itself, which runs to end-of-file.
        try handle.seek(toOffset: eocdOffset + 20)
        let length = UInt16(commentData.count)
        try handle.write(contentsOf: Data([UInt8(length & 0xFF), UInt8(length >> 8)]))
        if !commentData.isEmpty {
            try handle.write(contentsOf: commentData)
        }
        try handle.truncate(atOffset: eocdOffset + 22 + UInt64(commentData.count))
        try handle.synchronize()

        AppLogger.shared.log(message: "📝 Wrote \(commentData.count)-byte ZIP comment to \((archivePath as NSString).lastPathComponent)")
    }

    /// Finds the byte offset of the ZIP end-of-central-directory record.
    ///
    /// The record is at most 22 + 65535 bytes from the end, so only that tail is
    /// read. Candidates are scanned from the end backwards and accepted only when
    /// the stored comment length accounts for exactly the remaining bytes, which
    /// rules out the signature appearing by chance inside compressed data.
    nonisolated private static func locateEndOfCentralDirectory(atPath path: String) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let minimumRecord: UInt64 = 22
        guard fileSize >= minimumRecord else { throw SevenZipError.invalidArchive }

        let maximumTail: UInt64 = minimumRecord + 0xFFFF
        let tailLength = min(fileSize, maximumTail)
        let tailStart = fileSize - tailLength

        try handle.seek(toOffset: tailStart)
        guard let tail = try handle.read(upToCount: Int(tailLength)), tail.count >= Int(minimumRecord) else {
            throw SevenZipError.invalidArchive
        }

        let bytes = [UInt8](tail)
        var index = bytes.count - Int(minimumRecord)
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                let commentLength = UInt64(bytes[index + 20]) | (UInt64(bytes[index + 21]) << 8)
                let recordEnd = UInt64(index) + minimumRecord + commentLength
                if recordEnd == tailLength {
                    return tailStart + UInt64(index)
                }
            }
            index -= 1
        }

        throw SevenZipError.invalidArchive
    }
}

// MARK: - NewFolderController

/// Sheet for 7-Zip's "Create Folder" command (F7), plus the engine call that
/// materialises the folder inside an archive.
final class NewFolderController: NSWindowController {

    // MARK: Constants

    private static let defaultName = L("New Folder")
    private static let labelColumnWidth = fittingLabelWidth([L("Name:")], minimum: 60)

    /// Keeps controllers alive while their sheet is on screen.
    private static var activeControllers: [NewFolderController] = []

    // MARK: Properties

    private var nameField: NSTextField!

    /// Set by Create just before the sheet ends with `.OK`.
    private var confirmedName: String?

    // MARK: Presentation

    /// Presents the name-entry sheet on `parent`. Calls `completion` exactly once:
    /// with a validated folder name on Create, or `nil` on Cancel.
    static func present(on parent: NSWindow, completion: @escaping (String?) -> Void) {
        let controller = NewFolderController()

        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let name = (response == .OK) ? controller.confirmedName : nil
            sheetWindow.orderOut(nil)
            completion(name)
            activeControllers.removeAll { $0 === controller }
        }
    }

    // MARK: Initialization

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L("Create Folder")

        super.init(window: window)
        setupUI()
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

        let titleLabel = NSTextField(labelWithString: L("Name the new folder:"))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(titleLabel)

        let nameRow = NSStackView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.spacing = 8

        let labelView = NSTextField(labelWithString: L("Name:"))
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        nameRow.addArrangedSubview(labelView)

        nameField = NSTextField()
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.stringValue = Self.defaultName
        nameField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        nameRow.addArrangedSubview(nameField)
        stackView.addArrangedSubview(nameRow)

        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.spacing = 12

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let createButton = NSButton(title: L("Create"), target: self, action: #selector(confirm))
        createButton.keyEquivalent = "\r" // Return
        createButton.bezelColor = .controlAccentColor

        buttonRow.addArrangedSubview(NSView()) // Spacer
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(createButton)
        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        window.initialFirstResponder = nameField
        // Pre-select the placeholder so typing replaces it.
        DispatchQueue.main.async { [weak self] in
            self?.nameField.currentEditor()?.selectAll(nil)
        }
    }

    // MARK: Actions

    @objc private func confirm() {
        do {
            confirmedName = try Self.validatedFolderName(nameField.stringValue)
            endSheet(returnCode: .OK)
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Invalid Folder Name")
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    @objc private func cancel() {
        confirmedName = nil
        endSheet(returnCode: .cancel)
    }

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: returnCode)
        } else {
            window.orderOut(nil)
        }
    }

    // MARK: - Validation

    /// Trims and validates a folder name, returning the name that will be stored.
    ///
    /// - Throws: `SevenZipError.commandFailed` with a user-presentable reason.
    nonisolated static func validatedFolderName(_ rawName: String) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            throw SevenZipError.commandFailed(L("Enter a name for the folder."))
        }
        guard !name.contains("/") else {
            throw SevenZipError.commandFailed(L("A folder name cannot contain “/”. Create the folders one level at a time."))
        }
        guard name != "." && name != ".." else {
            throw SevenZipError.commandFailed(L("“%@” is a reserved name and cannot be used for a folder.", name))
        }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SevenZipError.commandFailed(L("A folder name cannot contain control characters."))
        }

        return name
    }

    // MARK: - Engine

    /// Creates an empty folder inside an existing archive.
    ///
    /// 7zz has no "make directory" command and cannot invent an entry out of thin
    /// air, so the folder is staged on disk first: an empty directory is created at
    /// `<temp>/<parentFolder>/<name>` and added with `u` from `<temp>` as the working
    /// directory, so the stored path is exactly `parentFolder/name`.
    ///
    /// The relative path is passed explicitly rather than as `.` on purpose — adding
    /// `.` walks the whole staging tree and rewrites the timestamps of every parent
    /// folder entry that already exists in the archive, whereas naming the path adds
    /// the one new entry and leaves everything else byte-identical. `-spd` disables
    /// wildcard matching so a folder genuinely named `report*` is taken literally.
    ///
    /// - Parameters:
    ///   - archivePath: Archive to modify. Resolved to an absolute path, since 7zz
    ///     runs with the staging directory as its working directory.
    ///   - parentFolder: In-archive folder to create the new folder inside; empty
    ///     for the archive root.
    ///   - name: Leaf name, validated by ``validatedFolderName(_:)``.
    nonisolated static func createFolder(
        inArchive archivePath: String,
        parentFolder: String,
        name: String,
        password: String? = nil,
        token: OperationToken? = nil
    ) async throws {
        let folderName = try validatedFolderName(name)

        let absoluteArchivePath = URL(fileURLWithPath: archivePath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: absoluteArchivePath) else {
            throw SevenZipError.archiveNotFound
        }

        // "", "/", "docs/" and "/docs/" all mean the same thing to a caller.
        let normalizedParent = parentFolder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let storedPath = normalizedParent.isEmpty ? folderName : "\(normalizedParent)/\(folderName)"

        let fileManager = FileManager.default
        let stagingRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        var stagedFolder = stagingRoot
        for component in storedPath.components(separatedBy: "/") {
            stagedFolder.appendPathComponent(component, isDirectory: true)
        }
        try fileManager.createDirectory(at: stagedFolder, withIntermediateDirectories: true, attributes: nil)

        var arguments = ["u", "-bsp1", "-spd"]
        arguments.append(contentsOf: ["--", absoluteArchivePath, storedPath])

        _ = try await SevenZipWrapper.runProcess(
            arguments: arguments,
            password: password,
            passwordSwitch: password != nil,
            currentDirectoryURL: stagingRoot,
            token: token
        )
    }
}
