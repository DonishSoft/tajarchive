import Cocoa

// MARK: - ExtractOptions

/// Options gathered from the extract dialog. The caller is responsible for
/// creating directories and for interpreting `flattenPaths` (7zz "e" vs "x"),
/// `createSubfolder` and `eliminateRootDuplication`.
struct ExtractOptions {
    var destination: URL
    var createSubfolder: Bool          // extract into destination/<archiveName>/
    var flattenPaths: Bool             // true -> caller uses 7zz 'e' instead of 'x'
    var overwriteMode: OverwriteMode
    var password: String?              // nil if field empty
    var eliminateRootDuplication: Bool // don't double-nest a single matching root folder
}

// MARK: - ExtractDialogController

/// Sheet-based dialog for configuring archive extraction.
final class ExtractDialogController: NSWindowController, NSTextFieldDelegate {

    // MARK: Constants

    static let destinationHistoryKey = "ExtractDestinationHistory"
    private static let historyLimit = 8
    private static let labelColumnWidth = fittingLabelWidth([L("Extract to:"), L("Overwrite:"), L("Password:")], minimum: 90)

    /// Keeps controllers alive while their sheet is on screen.
    private static var activeControllers: [ExtractDialogController] = []

    // MARK: Properties

    private let archiveName: String
    private let entryCount: Int
    private let suggestedDestination: URL

    private var destinationCombo: NSComboBox!
    private var subfolderCheckbox: NSButton!
    private var eliminateRootCheckbox: NSButton!
    private var flattenCheckbox: NSButton!
    private var overwritePopup: NSPopUpButton!
    private var passwordSecureField: NSSecureTextField!
    private var passwordPlainField: NSTextField!
    private var showPasswordCheckbox: NSButton!

    /// Set by the Extract action just before the sheet ends with `.OK`.
    private var confirmedOptions: ExtractOptions?

    // MARK: Presentation

    /// Presents the extract dialog as a sheet on `parent`. Calls `completion`
    /// exactly once: with the chosen options on Extract, or `nil` on Cancel.
    static func present(
        on parent: NSWindow,
        archiveName: String,
        entryCount: Int,
        suggestedDestination: URL,
        completion: @escaping (ExtractOptions?) -> Void
    ) {
        let controller = ExtractDialogController(
            archiveName: archiveName,
            entryCount: entryCount,
            suggestedDestination: suggestedDestination
        )

        guard let sheetWindow = controller.window else {
            completion(nil)
            return
        }

        activeControllers.append(controller)

        parent.beginSheet(sheetWindow) { response in
            let options = (response == .OK) ? controller.confirmedOptions : nil
            if let options = options {
                rememberDestination(options.destination.path)
            }
            sheetWindow.orderOut(nil)
            completion(options)
            activeControllers.removeAll { $0 === controller }
        }
    }

    // MARK: Initialization

    private init(archiveName: String, entryCount: Int, suggestedDestination: URL) {
        self.archiveName = archiveName
        self.entryCount = entryCount
        self.suggestedDestination = suggestedDestination

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L("Extract")

        super.init(window: window)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Destination History

    private static func destinationHistory() -> [String] {
        return UserDefaults.standard.stringArray(forKey: destinationHistoryKey) ?? []
    }

    private static func rememberDestination(_ path: String) {
        var history = destinationHistory()
        history.removeAll { $0 == path }
        history.insert(path, at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        UserDefaults.standard.set(history, forKey: destinationHistoryKey)
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

        // Title + subtitle
        let titleLabel = NSTextField(labelWithString: L("Extract “%@”", archiveName))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: L("Items: %d", entryCount))
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        stackView.addArrangedSubview(titleStack)

        // Destination
        let destRow = createRow(label: L("Extract to:"))
        destinationCombo = NSComboBox()
        destinationCombo.translatesAutoresizingMaskIntoConstraints = false
        destinationCombo.usesDataSource = false
        destinationCombo.isEditable = true
        destinationCombo.completes = true
        destinationCombo.numberOfVisibleItems = Self.historyLimit
        destinationCombo.stringValue = suggestedDestination.path
        let history = Self.destinationHistory()
        if !history.isEmpty {
            destinationCombo.addItems(withObjectValues: history)
        }
        destinationCombo.widthAnchor.constraint(equalToConstant: 260).isActive = true
        destRow.addArrangedSubview(destinationCombo)

        let browseButton = NSButton(title: L("Browse…"), target: self, action: #selector(browse))
        destRow.addArrangedSubview(browseButton)
        stackView.addArrangedSubview(destRow)

        // Checkboxes (indented to align with the field column)
        subfolderCheckbox = NSButton(
            checkboxWithTitle: L("Extract into subfolder “%@/”", archiveName),
            target: nil,
            action: nil
        )
        subfolderCheckbox.state = .on

        eliminateRootCheckbox = NSButton(
            checkboxWithTitle: L("Eliminate duplication of root folder"),
            target: nil,
            action: nil
        )
        eliminateRootCheckbox.state = .on

        flattenCheckbox = NSButton(
            checkboxWithTitle: L("Flatten paths (extract all files into one folder)"),
            target: nil,
            action: nil
        )
        flattenCheckbox.state = .off

        for checkbox in [subfolderCheckbox!, eliminateRootCheckbox!, flattenCheckbox!] {
            let row = createRow(label: "")
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            row.addArrangedSubview(checkbox)
            stackView.addArrangedSubview(row)
        }

        // Overwrite mode
        let overwriteRow = createRow(label: L("Overwrite:"))
        overwritePopup = NSPopUpButton()
        overwritePopup.translatesAutoresizingMaskIntoConstraints = false
        let overwriteChoices: [(String, OverwriteMode)] = [
            (L("Ask before overwrite"), .ask),
            (L("Overwrite existing"), .overwriteAll),
            (L("Skip existing"), .skipExisting),
            (L("Auto-rename new files"), .renameExtracting),
            (L("Auto-rename existing files"), .renameExisting)
        ]
        for (title, mode) in overwriteChoices {
            overwritePopup.addItem(withTitle: title)
            overwritePopup.lastItem?.representedObject = mode
        }
        overwritePopup.selectItem(at: 0)
        overwritePopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        overwriteRow.addArrangedSubview(overwritePopup)
        stackView.addArrangedSubview(overwriteRow)

        // Password
        let passwordRow = createRow(label: L("Password:"))

        passwordSecureField = NSSecureTextField()
        passwordSecureField.translatesAutoresizingMaskIntoConstraints = false
        passwordSecureField.placeholderString = L("Password (if required)")
        passwordSecureField.delegate = self
        passwordSecureField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        passwordPlainField = NSTextField()
        passwordPlainField.translatesAutoresizingMaskIntoConstraints = false
        passwordPlainField.placeholderString = L("Password (if required)")
        passwordPlainField.delegate = self
        passwordPlainField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        passwordPlainField.isHidden = true

        showPasswordCheckbox = NSButton(
            checkboxWithTitle: L("Show"),
            target: self,
            action: #selector(togglePasswordVisibility)
        )

        passwordRow.addArrangedSubview(passwordSecureField)
        passwordRow.addArrangedSubview(passwordPlainField)
        passwordRow.addArrangedSubview(showPasswordCheckbox)
        stackView.addArrangedSubview(passwordRow)

        // Buttons
        let buttonRow = NSStackView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.spacing = 12

        let cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let extractButton = NSButton(title: L("Extract"), target: self, action: #selector(extract))
        extractButton.keyEquivalent = "\r" // Return
        extractButton.bezelColor = .controlAccentColor

        buttonRow.addArrangedSubview(NSView()) // Spacer
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(extractButton)
        stackView.addArrangedSubview(buttonRow)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(greaterThanOrEqualToConstant: 500),

            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            buttonRow.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])

        window.initialFirstResponder = destinationCombo
        // Size the sheet to its content instead of stretching the stack's spacing.
        contentView.layoutSubtreeIfNeeded()
        window.setContentSize(contentView.fittingSize)
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

    // MARK: - Actions

    @objc private func browse() {
        guard let window = window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        let currentPath = FolderAccess.expandTilde(destinationCombo.stringValue)
        if !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        }

        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.destinationCombo.stringValue = url.path
            }
        }
    }

    @objc private func togglePasswordVisibility() {
        let show = showPasswordCheckbox.state == .on
        // Sync the field that becomes visible with the one being hidden.
        if show {
            passwordPlainField.stringValue = passwordSecureField.stringValue
        } else {
            passwordSecureField.stringValue = passwordPlainField.stringValue
        }
        passwordPlainField.isHidden = !show
        passwordSecureField.isHidden = show
        window?.makeFirstResponder(show ? passwordPlainField : passwordSecureField)
    }

    @objc private func extract() {
        let rawPath = destinationCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            showValidationAlert(L("Please enter a destination folder."))
            return
        }

        let expandedPath = FolderAccess.expandTilde(rawPath)
        guard expandedPath.hasPrefix("/") else {
            showValidationAlert(L("The destination must be an absolute path (e.g. /Users/you/Desktop or ~/Desktop)."))
            return
        }

        let destination = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL

        confirmedOptions = ExtractOptions(
            destination: destination,
            createSubfolder: subfolderCheckbox.state == .on,
            flattenPaths: flattenCheckbox.state == .on,
            overwriteMode: selectedOverwriteMode(),
            password: currentPassword(),
            eliminateRootDuplication: eliminateRootCheckbox.state == .on
        )
        endSheet(returnCode: .OK)
    }

    @objc private func cancel() {
        confirmedOptions = nil
        endSheet(returnCode: .cancel)
    }

    // MARK: - Helpers

    private func endSheet(returnCode: NSApplication.ModalResponse) {
        guard let window = window else { return }
        if let sheetParent = window.sheetParent {
            sheetParent.endSheet(window, returnCode: returnCode)
        } else {
            window.orderOut(nil)
        }
    }

    private func selectedOverwriteMode() -> OverwriteMode {
        return overwritePopup.selectedItem?.representedObject as? OverwriteMode ?? .ask
    }

    private func currentPassword() -> String? {
        let value = passwordSecureField.isHidden
            ? passwordPlainField.stringValue
            : passwordSecureField.stringValue
        return value.isEmpty ? nil : value
    }

    private func showValidationAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("Invalid Destination")
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === passwordSecureField {
            passwordPlainField.stringValue = passwordSecureField.stringValue
        } else if field === passwordPlainField {
            passwordSecureField.stringValue = passwordPlainField.stringValue
        }
    }
}

// MARK: - OverwriteDecision

enum OverwriteDecision {
    case yes
    case yesToAll
    case no
    case noToAll
    case autoRename
    case cancel
}

// MARK: - OverwriteDialog

/// NSAlert-based per-file overwrite prompt used while extracting with
/// `OverwriteMode.ask`.
final class OverwriteDialog {

    private init() {}

    /// Asks the user whether to replace `fileName`. Presented as a sheet when
    /// `parent` is non-nil, otherwise as an application-modal alert.
    @MainActor
    static func ask(
        on parent: NSWindow?,
        fileName: String,
        existing: (size: Int64, modified: Date?),
        incoming: (size: Int64, modified: Date?)
    ) async -> OverwriteDecision {
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        func describe(size: Int64, modified: Date?) -> String {
            let sizeText = byteFormatter.string(fromByteCount: size)
            if let modified = modified {
                return L("%@, modified %@", sizeText, dateFormatter.string(from: modified))
            }
            return L("%@, modification date unknown", sizeText)
        }

        let alert = NSAlert()
        alert.messageText = L("Replace “%@”?", fileName)
        alert.informativeText = L(
            "A file with the same name already exists in the destination.\n\nExisting file: %@\nNew file: %@",
            describe(size: existing.size, modified: existing.modified),
            describe(size: incoming.size, modified: incoming.modified)
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Yes"))                    // 1000
        alert.addButton(withTitle: L("Yes to All"))             // 1001
        alert.addButton(withTitle: L("No"))                     // 1002
        alert.addButton(withTitle: L("No to All"))              // 1003
        alert.addButton(withTitle: L("Auto Rename"))            // 1004
        alert.addButton(withTitle: L("Cancel"))                 // 1005 (also Escape)

        let response: NSApplication.ModalResponse
        if let parent = parent {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: parent) { result in
                    continuation.resume(returning: result)
                }
            }
        } else {
            response = alert.runModal()
        }

        let thirdButton = NSApplication.ModalResponse.alertThirdButtonReturn.rawValue
        switch response {
        case .alertFirstButtonReturn:
            return .yes
        case .alertSecondButtonReturn:
            return .yesToAll
        case .alertThirdButtonReturn:
            return .no
        case NSApplication.ModalResponse(rawValue: thirdButton + 1):
            return .noToAll
        case NSApplication.ModalResponse(rawValue: thirdButton + 2):
            return .autoRename
        default:
            return .cancel
        }
    }
}
