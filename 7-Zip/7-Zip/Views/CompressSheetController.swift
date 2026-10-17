import Cocoa

/// Add-to-Archive sheet: format, level, method and the full advanced option set,
/// with a live memory estimate and per-format settings that survive across launches.
class CompressSheetController: NSWindowController {

    // MARK: - Properties

    var sourceFiles: [String] = [] {
        didSet {
            calculateTotalSize()
            applyDefaultDestination()
            applyDefaultArchiveName()
        }
    }

    /// Called with the produced archive path when compression succeeds.
    var onCompleted: ((String) -> Void)?

    private var settings = CompressionSettings.load(for: .sevenZip)

    // Basic controls
    private var archiveNameField: NSTextField!
    private var destinationField: NSTextField!
    private var totalSizeLabel: NSTextField!
    private var formatPopup: NSPopUpButton!
    private var levelPopup: NSPopUpButton!
    private var methodPopup: NSPopUpButton!
    private var passwordField: NSSecureTextField!
    private var passwordConfirmField: NSSecureTextField!
    private var showPasswordCheckbox: NSButton!
    private var passwordPlainField: NSTextField!

    // Advanced controls
    private var dictionaryPopup: NSPopUpButton!
    private var wordSizePopup: NSPopUpButton!
    private var wordSizeLabel: NSTextField!
    private var solidPopup: NSPopUpButton!
    private var threadsPopup: NSPopUpButton!
    private var memoryLabel: NSTextField!
    private var pathModePopup: NSPopUpButton!
    private var updateModePopup: NSPopUpButton!
    private var volumeCombo: NSComboBox!
    private var encryptionPopup: NSPopUpButton!
    private var encryptNamesCheckbox: NSButton!
    private var sfxCheckbox: NSButton!
    private var deleteAfterCheckbox: NSButton!
    private var symlinksCheckbox: NSButton!
    private var parametersField: NSTextField!

    // MARK: - Initialization

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("compress.title")

        self.init(window: window)
        setupUI()
        loadSettingsIntoUI()
    }

    // MARK: - Defaults

    private func applyDefaultDestination() {
        guard destinationField != nil else { return }
        if let first = sourceFiles.first {
            let parent = URL(fileURLWithPath: first).deletingLastPathComponent().path
            if FileManager.default.isWritableFile(atPath: parent) {
                destinationField.stringValue = parent
                return
            }
        }
        destinationField.stringValue = FolderAccess.userFolder(.downloadsDirectory)
    }

    private func applyDefaultArchiveName() {
        guard archiveNameField != nil, archiveNameField.stringValue.isEmpty, let first = sourceFiles.first else { return }
        let url = URL(fileURLWithPath: first)
        let base = sourceFiles.count == 1
            ? url.deletingPathExtension().lastPathComponent
            : url.deletingLastPathComponent().lastPathComponent
        if !base.isEmpty {
            archiveNameField.stringValue = base
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView()
        window.contentView = contentView

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 5
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        contentView.addSubview(grid)

        // ── Archive ──
        addSection(grid, L("Archive"))

        archiveNameField = NSTextField()
        archiveNameField.placeholderString = L("archive")
        archiveNameField.target = self
        archiveNameField.action = #selector(compress)
        addRow(grid, L("compress.archive_name"), archiveNameField, width: 340)

        destinationField = NSTextField()
        destinationField.isEditable = true
        let browseButton = NSButton(title: L("compress.browse"), target: self, action: #selector(browseDestination))
        addRow(grid, L("compress.destination"), pair(destinationField, browseButton, controlWidth: 250), width: 340)

        // Source size rides along with the destination row instead of taking its own
        totalSizeLabel = NSTextField(labelWithString: L("Calculating…"))
        totalSizeLabel.textColor = .secondaryLabelColor
        totalSizeLabel.font = .systemFont(ofSize: 11)
        addRow(grid, "", totalSizeLabel, width: 340)

        // ── Compression ──
        addSection(grid, L("Compression"))

        formatPopup = NSPopUpButton()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        for format in ArchiveFormat.allCases {
            formatPopup.addItem(withTitle: format.displayName)
            formatPopup.lastItem?.representedObject = format
        }
        addRow(grid, L("compress.format"), formatPopup, width: 200)

        levelPopup = NSPopUpButton()
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)
        for level in CompressionLevel.allCases {
            levelPopup.addItem(withTitle: level.displayName)
            levelPopup.lastItem?.representedObject = level
        }
        addRow(grid, L("compress.level"), levelPopup, width: 230)

        methodPopup = NSPopUpButton()
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        addRow(grid, L("compress.method"), methodPopup, width: 230)

        dictionaryPopup = NSPopUpButton()
        dictionaryPopup.target = self
        dictionaryPopup.action = #selector(advancedOptionChanged)
        addRow(grid, L("Dictionary size:"), dictionaryPopup, width: 200)

        wordSizePopup = NSPopUpButton()
        wordSizePopup.target = self
        wordSizePopup.action = #selector(advancedOptionChanged)
        wordSizeLabel = addRow(grid, L("Word size:"), wordSizePopup, width: 200)

        solidPopup = NSPopUpButton()
        solidPopup.target = self
        solidPopup.action = #selector(advancedOptionChanged)
        for size in SolidBlockSize.allCases {
            solidPopup.addItem(withTitle: size.displayName)
            solidPopup.lastItem?.representedObject = size
        }
        addRow(grid, L("Solid block size:"), solidPopup, width: 200)

        threadsPopup = NSPopUpButton()
        threadsPopup.target = self
        threadsPopup.action = #selector(advancedOptionChanged)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        threadsPopup.addItem(withTitle: L("Automatic (%d)", cores))
        threadsPopup.lastItem?.representedObject = 0
        for count in 1...cores {
            threadsPopup.addItem(withTitle: "\(count)")
            threadsPopup.lastItem?.representedObject = count
        }
        addRow(grid, L("CPU threads:"), threadsPopup, width: 200)

        memoryLabel = NSTextField(labelWithString: "—")
        memoryLabel.textColor = .secondaryLabelColor
        memoryLabel.font = .systemFont(ofSize: 11)
        addRow(grid, L("Memory usage:"), memoryLabel, width: 380)

        volumeCombo = NSComboBox()
        volumeCombo.isEditable = true
        volumeCombo.completes = false
        volumeCombo.delegate = self
        volumeCombo.placeholderString = L("no split")
        for preset in ["10m", "100m", "700m", "1g", "4092m", "4480m"] {
            volumeCombo.addItem(withObjectValue: preset)
        }
        volumeCombo.toolTip = L("Split into volumes, e.g. 100m, 4g. Leave empty for a single file.")
        addRow(grid, L("Split to volumes:"), volumeCombo, width: 200)

        // ── Encryption ──
        addSection(grid, L("Encryption"))

        passwordField = NSSecureTextField()
        passwordField.placeholderString = L("Password (optional)")
        passwordField.delegate = self
        passwordPlainField = NSTextField()
        passwordPlainField.placeholderString = L("Password (optional)")
        passwordPlainField.delegate = self
        passwordPlainField.isHidden = true
        showPasswordCheckbox = NSButton(checkboxWithTitle: L("Show"), target: self, action: #selector(togglePasswordVisibility))

        let passwordSwap = NSView()
        passwordSwap.translatesAutoresizingMaskIntoConstraints = false
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordPlainField.translatesAutoresizingMaskIntoConstraints = false
        passwordSwap.addSubview(passwordField)
        passwordSwap.addSubview(passwordPlainField)
        NSLayoutConstraint.activate([
            passwordField.leadingAnchor.constraint(equalTo: passwordSwap.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: passwordSwap.trailingAnchor),
            passwordField.topAnchor.constraint(equalTo: passwordSwap.topAnchor),
            passwordField.bottomAnchor.constraint(equalTo: passwordSwap.bottomAnchor),
            passwordPlainField.leadingAnchor.constraint(equalTo: passwordSwap.leadingAnchor),
            passwordPlainField.trailingAnchor.constraint(equalTo: passwordSwap.trailingAnchor),
            passwordPlainField.topAnchor.constraint(equalTo: passwordSwap.topAnchor),
            passwordPlainField.bottomAnchor.constraint(equalTo: passwordSwap.bottomAnchor)
        ])
        addRow(grid, L("compress.password"), pair(passwordSwap, showPasswordCheckbox, controlWidth: 220), width: 360)

        passwordConfirmField = NSSecureTextField()
        passwordConfirmField.placeholderString = L("Re-enter password")
        passwordConfirmField.delegate = self
        addRow(grid, L("Confirm:"), passwordConfirmField, width: 220)

        encryptionPopup = NSPopUpButton()
        encryptionPopup.target = self
        encryptionPopup.action = #selector(advancedOptionChanged)
        for method in EncryptionMethod.allCases {
            encryptionPopup.addItem(withTitle: method.displayName)
            encryptionPopup.lastItem?.representedObject = method
        }
        addRow(grid, L("Method:"), encryptionPopup, width: 230)

        encryptNamesCheckbox = NSButton(checkboxWithTitle: L("compress.encrypt_names"), target: self, action: #selector(advancedOptionChanged))
        encryptNamesCheckbox.toolTip = L("7z only: hides file names inside the archive (requires a password)")
        addRow(grid, "", encryptNamesCheckbox, width: 340)

        // ── Options ──
        addSection(grid, L("Options"))

        pathModePopup = NSPopUpButton()
        pathModePopup.target = self
        pathModePopup.action = #selector(advancedOptionChanged)
        for mode in PathMode.allCases {
            pathModePopup.addItem(withTitle: mode.displayName)
            pathModePopup.lastItem?.representedObject = mode
        }
        addRow(grid, L("Path mode:"), pathModePopup, width: 230)

        updateModePopup = NSPopUpButton()
        updateModePopup.target = self
        updateModePopup.action = #selector(advancedOptionChanged)
        for mode in UpdateMode.allCases {
            updateModePopup.addItem(withTitle: mode.displayName)
            updateModePopup.lastItem?.representedObject = mode
        }
        updateModePopup.toolTip = L("Applies when the target archive already exists")
        addRow(grid, L("Update mode:"), updateModePopup, width: 230)

        sfxCheckbox = NSButton(checkboxWithTitle: L("Create self-extracting archive (.command)"), target: self, action: #selector(advancedOptionChanged))
        sfxCheckbox.toolTip = L("Produces a double-clickable script that unpacks itself on any Mac")
        addRow(grid, "", sfxCheckbox, width: 340)

        deleteAfterCheckbox = NSButton(checkboxWithTitle: L("Delete source files after compression"), target: self, action: #selector(advancedOptionChanged))
        addRow(grid, "", deleteAfterCheckbox, width: 340)

        symlinksCheckbox = NSButton(checkboxWithTitle: L("Store symbolic links as links"), target: self, action: #selector(advancedOptionChanged))
        symlinksCheckbox.toolTip = L("7z and TAR: keeps links instead of copying their targets")
        addRow(grid, "", symlinksCheckbox, width: 340)

        parametersField = NSTextField()
        parametersField.placeholderString = L("e.g. -mqs=on -myx=9")
        parametersField.toolTip = L("Extra 7zz switches appended verbatim, overriding the settings above")
        addRow(grid, L("Parameters:"), parametersField, width: 340)

        // ── Buttons ──
        let cancelButton = NSButton(title: L("compress.cancel"), target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let compressButton = NSButton(title: L("compress.compress"), target: self, action: #selector(compress))
        compressButton.keyEquivalent = "\r"
        compressButton.bezelColor = .controlAccentColor

        let buttonRow = NSStackView(views: [NSView(), cancelButton, compressButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
    }

    // MARK: - Layout helpers

    /// Adds a bold section header spanning both grid columns.
    private func addSection(_ grid: NSGridView, _ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        // A merged cell inherits the label column's trailing placement, which would
        // shove the header against the right edge.
        row.cell(at: 0).xPlacement = .leading
        row.topPadding = grid.numberOfRows > 1 ? 10 : 0
    }

    /// Adds a label/control row and returns the label so callers can retitle it later.
    @discardableResult
    private func addRow(_ grid: NSGridView, _ label: String, _ control: NSView, width: CGFloat) -> NSTextField {
        let labelView = NSTextField(labelWithString: label)
        labelView.alignment = .right
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: width).isActive = true
        grid.addRow(with: [labelView, control])
        return labelView
    }

    /// Puts a control and a trailing accessory (button/checkbox) side by side.
    private func pair(_ control: NSView, _ accessory: NSView, controlWidth: CGFloat) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        let stack = NSStackView(views: [control, accessory])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    // MARK: - Settings <-> UI

    private var selectedFormat: ArchiveFormat {
        formatPopup.selectedItem?.representedObject as? ArchiveFormat ?? .sevenZip
    }

    private func loadSettingsIntoUI() {
        let format = selectedFormat
        settings = CompressionSettings.load(for: format)

        selectItem(in: levelPopup, matching: { ($0 as? CompressionLevel) == settings.level })
        rebuildMethodPopup(for: format)
        rebuildDictionaryPopup()
        rebuildWordSizePopup()

        selectItem(in: solidPopup, matching: { ($0 as? SolidBlockSize) == settings.solidBlock })
        selectItem(in: threadsPopup, matching: { ($0 as? Int) == settings.threadCount })
        selectItem(in: pathModePopup, matching: { ($0 as? PathMode) == settings.pathMode })
        selectItem(in: updateModePopup, matching: { ($0 as? UpdateMode) == settings.updateMode })
        selectItem(in: encryptionPopup, matching: { ($0 as? EncryptionMethod) == settings.encryptionMethod })

        volumeCombo.stringValue = settings.volumeSize
        parametersField.stringValue = settings.customParameters
        encryptNamesCheckbox.state = settings.encryptHeaders ? .on : .off
        sfxCheckbox.state = settings.createSFX ? .on : .off
        deleteAfterCheckbox.state = settings.deleteAfter ? .on : .off
        symlinksCheckbox.state = settings.storeSymlinks ? .on : .off

        updateControlAvailability()
        updateMemoryEstimate()
    }

    private func collectSettingsFromUI() -> CompressionSettings {
        var result = settings
        result.level = levelPopup.selectedItem?.representedObject as? CompressionLevel ?? .normal
        result.method = methodPopup.selectedItem?.representedObject as? CompressionMethod
        result.dictionary = dictionaryPopup.selectedItem?.representedObject as? String
        result.wordSize = wordSizePopup.selectedItem?.representedObject as? Int
        result.solidBlock = solidPopup.selectedItem?.representedObject as? SolidBlockSize ?? .size4g
        result.threadCount = threadsPopup.selectedItem?.representedObject as? Int ?? 0
        result.pathMode = pathModePopup.selectedItem?.representedObject as? PathMode ?? .relative
        result.updateMode = updateModePopup.selectedItem?.representedObject as? UpdateMode ?? .addAndReplace
        result.encryptionMethod = encryptionPopup.selectedItem?.representedObject as? EncryptionMethod ?? .aes256
        result.volumeSize = volumeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        result.customParameters = parametersField.stringValue.trimmingCharacters(in: .whitespaces)
        result.encryptHeaders = encryptNamesCheckbox.state == .on
        result.createSFX = sfxCheckbox.state == .on
        result.deleteAfter = deleteAfterCheckbox.state == .on
        result.storeSymlinks = symlinksCheckbox.state == .on
        return result
    }

    private func selectItem(in popup: NSPopUpButton, matching predicate: (Any?) -> Bool) {
        for item in popup.itemArray where predicate(item.representedObject) {
            popup.select(item)
            return
        }
        if popup.numberOfItems > 0 { popup.selectItem(at: 0) }
    }

    private func rebuildMethodPopup(for format: ArchiveFormat) {
        methodPopup.removeAllItems()
        let methods = format.availableMethods
        if methods.isEmpty {
            methodPopup.isEnabled = false
            methodPopup.addItem(withTitle: "—")
            return
        }
        methodPopup.isEnabled = true
        for method in methods {
            methodPopup.addItem(withTitle: method.rawValue)
            methodPopup.lastItem?.representedObject = method
        }
        if let saved = settings.method, methods.contains(saved) {
            selectItem(in: methodPopup, matching: { ($0 as? CompressionMethod) == saved })
        } else {
            methodPopup.selectItem(at: 0)
        }
    }

    private func rebuildDictionaryPopup() {
        dictionaryPopup.removeAllItems()
        guard let method = methodPopup.selectedItem?.representedObject as? CompressionMethod else {
            dictionaryPopup.isEnabled = false
            dictionaryPopup.addItem(withTitle: "—")
            return
        }
        let sizes = method.dictionarySizes
        if sizes.isEmpty {
            dictionaryPopup.isEnabled = false
            dictionaryPopup.addItem(withTitle: "—")
            return
        }
        dictionaryPopup.isEnabled = method.hasConfigurableDictionary
        for size in sizes {
            dictionaryPopup.addItem(withTitle: size.label)
            dictionaryPopup.lastItem?.representedObject = size.value
        }
        let level = levelPopup.selectedItem?.representedObject as? CompressionLevel ?? .normal
        let target = settings.dictionary ?? method.defaultDictionary(for: level)
        selectItem(in: dictionaryPopup, matching: { ($0 as? String) == target })
    }

    private func rebuildWordSizePopup() {
        wordSizePopup.removeAllItems()
        guard let method = methodPopup.selectedItem?.representedObject as? CompressionMethod else {
            wordSizePopup.isEnabled = false
            wordSizePopup.addItem(withTitle: "—")
            return
        }
        wordSizeLabel?.stringValue = method.wordSizeLabel
        let sizes = method.wordSizes
        if sizes.isEmpty {
            wordSizePopup.isEnabled = false
            wordSizePopup.addItem(withTitle: "—")
            return
        }
        wordSizePopup.isEnabled = true
        for size in sizes {
            wordSizePopup.addItem(withTitle: "\(size)")
            wordSizePopup.lastItem?.representedObject = size
        }
        let level = levelPopup.selectedItem?.representedObject as? CompressionLevel ?? .normal
        let target = settings.wordSize ?? method.defaultWordSize(for: level)
        selectItem(in: wordSizePopup, matching: { ($0 as? Int) == target })
    }

    /// Enables only what the current format, method and password state actually support.
    private func updateControlAvailability() {
        let format = selectedFormat
        let level = levelPopup.selectedItem?.representedObject as? CompressionLevel ?? .normal
        let method = methodPopup.selectedItem?.representedObject as? CompressionMethod
        let hasPassword = !currentPassword.isEmpty
        let isStore = level == .store

        dictionaryPopup.isEnabled = !isStore && !(method?.dictionarySizes.isEmpty ?? true)
        wordSizePopup.isEnabled = !isStore && !(method?.wordSizes.isEmpty ?? true)
        solidPopup.isEnabled = format.supportsSolidBlocks && !isStore
        threadsPopup.isEnabled = method?.supportsMultithreading ?? false
        volumeCombo.isEnabled = format.supportsVolumes && sfxCheckbox.state != .on

        encryptNamesCheckbox.isEnabled = format.supportsHeaderEncryption && hasPassword
        if !encryptNamesCheckbox.isEnabled { encryptNamesCheckbox.state = .off }

        encryptionPopup.isEnabled = format.supportsEncryption && hasPassword && format.supportsZipCrypto
        if !format.supportsZipCrypto {
            selectItem(in: encryptionPopup, matching: { ($0 as? EncryptionMethod) == .aes256 })
        }

        passwordField.isEnabled = format.supportsEncryption
        passwordPlainField.isEnabled = format.supportsEncryption
        passwordConfirmField.isEnabled = format.supportsEncryption

        // SFX and volume splitting are mutually exclusive, as on Windows
        sfxCheckbox.isEnabled = format.supportsSFX && volumeCombo.stringValue.isEmpty
        if !sfxCheckbox.isEnabled { sfxCheckbox.state = .off }

        symlinksCheckbox.isEnabled = (format == .sevenZip || format == .tar)
    }

    private func updateMemoryEstimate() {
        let format = selectedFormat
        let level = levelPopup.selectedItem?.representedObject as? CompressionLevel ?? .normal
        let method = methodPopup.selectedItem?.representedObject as? CompressionMethod
        let dictionary = dictionaryPopup.selectedItem?.representedObject as? String
        let threads = threadsPopup.selectedItem?.representedObject as? Int ?? 0

        let estimate = MemoryEstimator.estimate(
            format: format, method: method, level: level,
            dictionary: dictionary, threads: threads
        )

        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let compressText = MemoryEstimator.format(estimate.compress)
        let decompressText = MemoryEstimator.format(estimate.decompress)
        memoryLabel.stringValue = L("≈ %@ to compress · %@ to extract", compressText, decompressText)

        // Warn when the estimate approaches the machine's RAM
        if estimate.compress > physical * 3 / 4 {
            memoryLabel.textColor = .systemOrange
            memoryLabel.stringValue += L("  ⚠︎ exceeds available RAM")
        } else {
            memoryLabel.textColor = .secondaryLabelColor
        }
    }

    private var currentPassword: String {
        showPasswordCheckbox.state == .on ? passwordPlainField.stringValue : passwordField.stringValue
    }

    // MARK: - Actions

    @objc private func formatChanged() {
        // Persist what the user had for the previous format before switching
        loadSettingsIntoUI()
    }

    @objc private func levelChanged() {
        // A new level implies new method defaults unless the user overrode them
        settings.dictionary = nil
        settings.wordSize = nil
        rebuildDictionaryPopup()
        rebuildWordSizePopup()
        updateControlAvailability()
        updateMemoryEstimate()
    }

    @objc private func methodChanged() {
        settings.dictionary = nil
        settings.wordSize = nil
        rebuildDictionaryPopup()
        rebuildWordSizePopup()
        updateControlAvailability()
        updateMemoryEstimate()
    }

    @objc private func advancedOptionChanged() {
        settings.dictionary = dictionaryPopup.selectedItem?.representedObject as? String
        settings.wordSize = wordSizePopup.selectedItem?.representedObject as? Int
        updateControlAvailability()
        updateMemoryEstimate()
    }

    @objc private func togglePasswordVisibility() {
        let showing = showPasswordCheckbox.state == .on
        if showing {
            passwordPlainField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = passwordPlainField.stringValue
        }
        passwordField.isHidden = showing
        passwordPlainField.isHidden = !showing
        window?.makeFirstResponder(showing ? passwordPlainField : passwordField)
    }

    @objc private func browseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            destinationField.stringValue = url.path
        }
    }

    private func calculateTotalSize() {
        let files = sourceFiles
        Task { [weak self] in
            let totalBytes = await Task.detached(priority: .userInitiated) {
                Self.totalSize(of: files)
            }.value
            let formatted = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            self?.totalSizeLabel?.stringValue = L("%@ in %d item(s)", formatted, files.count)
        }
    }

    /// Bytes in the given files and folders (recursively), read off the main thread.
    nonisolated private static func totalSize(of files: [String]) -> Int64 {
        var totalBytes: Int64 = 0
        let fm = FileManager.default
        for path in files {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: path),
                                                     includingPropertiesForKeys: [.fileSizeKey]) else { continue }
                while let fileURL = enumerator.nextObject() as? URL {
                    if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        totalBytes += Int64(size)
                    }
                }
            } else if let attrs = try? fm.attributesOfItem(atPath: path), let size = attrs[.size] as? NSNumber {
                totalBytes += size.int64Value
            }
        }
        return totalBytes
    }

    @objc private func cancel() {
        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!, returnCode: .cancel)
        } else {
            window?.close()
        }
    }

    @objc private func compress() {
        guard !sourceFiles.isEmpty else {
            showAlert(message: L("No files selected to compress"))
            return
        }

        let format = selectedFormat
        let finalSettings = collectSettingsFromUI()

        var archiveName = archiveNameField.stringValue.trimmingCharacters(in: .whitespaces)
        if archiveName.isEmpty {
            archiveName = "archive.\(format.extensionString)"
        } else if !archiveName.hasSuffix(".\(format.extensionString)") {
            archiveName += ".\(format.extensionString)"
        }

        let destinationDir = FolderAccess.expandTilde(destinationField.stringValue)
        guard FolderAccess.ensureAccess(to: sourceFiles, forWriting: false),
              FolderAccess.ensureAccess(to: [destinationDir], forWriting: true) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationDir, isDirectory: &isDir), isDir.boolValue else {
            showAlert(message: L("Destination folder does not exist:\n%@", destinationDir))
            return
        }

        let password = currentPassword.isEmpty ? nil : currentPassword
        if password != nil && currentPassword != passwordConfirmField.stringValue {
            showAlert(message: L("Passwords do not match."))
            return
        }

        let destinationPath = (destinationDir as NSString).appendingPathComponent(archiveName)
        let archiveExists = FileManager.default.fileExists(atPath: destinationPath)

        // An existing archive is updated according to the update mode, not silently replaced
        if archiveExists && finalSettings.updateMode == .addAndReplace {
            let alert = NSAlert()
            alert.messageText = L("“%@” already exists", archiveName)
            alert.informativeText = L("Add the selected files to the existing archive, or replace it?")
            alert.addButton(withTitle: L("Add to Archive"))
            alert.addButton(withTitle: L("Replace"))
            alert.addButton(withTitle: L("Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: break // 7zz `a` updates in place
            case .alertSecondButtonReturn: try? FileManager.default.removeItem(atPath: destinationPath)
            default: return
            }
        }

        finalSettings.save(for: format)

        let workingDirectory = URL(fileURLWithPath: sourceFiles[0]).deletingLastPathComponent()

        if let sheetParent = window?.sheetParent {
            sheetParent.endSheet(window!, returnCode: .OK)
        } else {
            window?.close()
        }

        let token = OperationToken()
        let progressWindowController = ProgressWindowController(operationName: L("Compressing to %@…", archiveName), token: token)
        progressWindowController.showWindow(self)

        let sources = sourceFiles
        let completion = onCompleted

        Task {
            do {
                let producedPath = try await SevenZipWrapper.createArchive(
                    at: destinationPath,
                    from: sources,
                    workingDirectory: workingDirectory,
                    format: format,
                    settings: finalSettings,
                    password: password,
                    token: token,
                    progressHandler: { percent, file in
                        progressWindowController.updateProgress(percent: percent, file: file)
                    }
                )

                await MainActor.run {
                    progressWindowController.close()
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: producedPath)])
                    completion?(producedPath)
                }
            } catch SevenZipError.cancelled {
                await MainActor.run {
                    progressWindowController.close()
                    try? FileManager.default.removeItem(atPath: destinationPath)
                }
            } catch {
                await MainActor.run {
                    progressWindowController.close()
                    self.showAlert(message: L("Compression failed: %@", error.localizedDescription))
                }
            }
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = L("Error")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Password fields drive dependent controls

extension CompressSheetController: NSTextFieldDelegate, NSComboBoxDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSControl else { return }
        if field === passwordField || field === passwordPlainField || field === volumeCombo {
            updateControlAvailability()
        }
    }

    /// Also refresh when focus leaves a field, so pasted or auto-filled values —
    /// which do not always emit change notifications — still unlock the
    /// encryption controls.
    func controlTextDidEndEditing(_ obj: Notification) {
        updateControlAvailability()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // Volume splitting and SFX are mutually exclusive
        DispatchQueue.main.async { self.updateControlAvailability() }
    }
}

/// Window controller for displaying operation progress, with cancellation,
/// speed, and remaining-time estimates.
class ProgressWindowController: NSWindowController, NSWindowDelegate {

    private var progressBar: NSProgressIndicator!
    private var percentLabel: NSTextField!
    private var fileLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var cancelButton: NSButton!
    private var pauseButton: NSButton!

    private let token: OperationToken?
    private let startDate = Date()
    /// Time spent paused, left out of the elapsed/remaining estimate.
    private var pausedDuration: TimeInterval = 0
    private var pauseStarted: Date?

    init(operationName: String, token: OperationToken? = nil) {
        self.token = token
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = operationName
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        progressBar = NSProgressIndicator()
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0

        percentLabel = NSTextField(labelWithString: "0%")
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        percentLabel.alignment = .right

        fileLabel = NSTextField(labelWithString: L("Starting…"))
        fileLabel.translatesAutoresizingMaskIntoConstraints = false
        fileLabel.font = .systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        statsLabel = NSTextField(labelWithString: "")
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .tertiaryLabelColor

        cancelButton = NSButton(title: L("Cancel"), target: self, action: #selector(cancelPressed))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        pauseButton = NSButton(title: L("Pause"), target: self, action: #selector(pausePressed))
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        pauseButton.isHidden = (token == nil)

        contentView.addSubview(progressBar)
        contentView.addSubview(percentLabel)
        contentView.addSubview(fileLabel)
        contentView.addSubview(statsLabel)
        contentView.addSubview(cancelButton)
        contentView.addSubview(pauseButton)

        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: percentLabel.leadingAnchor, constant: -12),

            percentLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            percentLabel.widthAnchor.constraint(equalToConstant: 45),

            fileLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 10),
            fileLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            fileLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            statsLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 4),
            statsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statsLabel.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -12),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            pauseButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),

            contentView.heightAnchor.constraint(equalToConstant: 150),
            contentView.widthAnchor.constraint(equalToConstant: 470)
        ])
    }

    @objc private func cancelPressed() {
        token?.cancel()
        fileLabel.stringValue = L("Cancelling…")
        cancelButton.isEnabled = false
        pauseButton.isEnabled = false
    }

    @objc private func pausePressed() {
        guard let token = token else { return }
        let pause = !token.isPaused
        token.setPaused(pause)
        pauseButton.title = pause ? L("Resume") : L("Pause")
        if pause {
            pauseStarted = Date()
            statsLabel.stringValue = L("Paused")
        } else if let started = pauseStarted {
            pausedDuration += Date().timeIntervalSince(started)
            pauseStarted = nil
        }
    }

    /// Long jobs often finish while the user is in another app: bounce the Dock icon.
    override func close() {
        if !NSApp.isActive && Date().timeIntervalSince(startDate) > 5 {
            NSApp.requestUserAttention(.informationalRequest)
        }
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        token?.cancel()
        return true
    }

    /// Update progress display on the main thread; safe to call from any thread.
    nonisolated func updateProgress(percent: Double, file: String) {
        DispatchQueue.main.async {
            self.progressBar.doubleValue = percent
            self.percentLabel.stringValue = "\(Int(percent))%"
            if !file.isEmpty {
                self.fileLabel.stringValue = file
            }

            guard self.pauseStarted == nil else { return }
            let elapsed = Date().timeIntervalSince(self.startDate) - self.pausedDuration
            if percent > 1, elapsed > 1 {
                let remaining = elapsed * (100 - percent) / percent
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = remaining > 3600 ? [.hour, .minute] : [.minute, .second]
                formatter.unitsStyle = .abbreviated
                let remainingText = formatter.string(from: remaining) ?? "—"
                let elapsedText = formatter.string(from: elapsed) ?? "—"
                self.statsLabel.stringValue = L("Elapsed: %@   Remaining: ~%@", elapsedText, remainingText)
            }
        }
    }
}
