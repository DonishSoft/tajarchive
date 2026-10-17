import Cocoa
import UniformTypeIdentifiers

/// Localized string with an English fallback.
///
/// The string tables live in files this window does not own, so a key that has not been
/// translated yet must not surface in the UI as a raw `prefs.something` identifier.
/// `NSLocalizedString` returns the key itself when it finds no entry, which is exactly
/// the case this catches. Once the key lands in `Localizable.strings` it takes over
/// with no change here.
private func L(_ key: String, fallback: String) -> String {
    let value = L(key)
    return value == key ? fallback : value
}

/// Preferences window with file association management (like Windows 7-Zip settings)
class PreferencesWindowController: NSWindowController {

    // MARK: - Supported Archive Format Definitions

    struct ArchiveFormat {
        let ext: String
        let utType: String
        let name: String
        let icon: String
    }

    static let supportedFormats: [ArchiveFormat] = [
        ArchiveFormat(ext: "taj", utType: "com.donishsoft.taj-archive", name: L("TAJ Archive"), icon: "📦"),
        ArchiveFormat(ext: "7z",  utType: "org.7-zip.7-zip-archive", name: L("7-Zip Archive"), icon: "7️⃣"),
        ArchiveFormat(ext: "zip", utType: "public.zip-archive", name: L("ZIP Archive"), icon: "📁"),
        ArchiveFormat(ext: "rar", utType: "com.rarlab.rar-archive", name: L("RAR Archive"), icon: "📂"),
        ArchiveFormat(ext: "tar", utType: "public.tar-archive", name: L("TAR Archive"), icon: "📋"),
        ArchiveFormat(ext: "gz",  utType: "org.gnu.gnu-zip-archive", name: L("GZip Archive"), icon: "🗜️"),
        ArchiveFormat(ext: "tgz", utType: "org.gnu.gnu-zip-tar-archive", name: L("TAR + GZip Archive"), icon: "🗜️"),
        ArchiveFormat(ext: "bz2", utType: "public.bzip2-archive", name: L("BZip2 Archive"), icon: "🗜️"),
        ArchiveFormat(ext: "xz",  utType: "org.tukaani.xz-archive", name: L("XZ Archive"), icon: "🗜️"),
        ArchiveFormat(ext: "zst", utType: "com.facebook.zstandard-archive", name: L("Zstandard Archive"), icon: "⚡️"),
        ArchiveFormat(ext: "lz4", utType: "org.lz4.lz4-archive", name: L("LZ4 Archive"), icon: "⚡️"),
        ArchiveFormat(ext: "cab", utType: "com.microsoft.cab", name: L("Windows CAB"), icon: "🪟"),
        ArchiveFormat(ext: "wim", utType: "com.microsoft.windows-imaging-format", name: L("Windows Imaging (WIM)"), icon: "🪟"),
        ArchiveFormat(ext: "arj", utType: "cx.c3.arj-archive", name: L("ARJ Archive"), icon: "📦"),
        ArchiveFormat(ext: "lzh", utType: "cx.c3.lha-archive", name: L("LHA Archive"), icon: "📦"),
        ArchiveFormat(ext: "001", utType: "com.donishsoft.split-archive-volume", name: L("Split Archive"), icon: "✂️"),
        ArchiveFormat(ext: "iso", utType: "public.iso-image", name: L("ISO Disk Image"), icon: "💿"),
        ArchiveFormat(ext: "dmg", utType: "com.apple.disk-image-udif", name: L("macOS Disk Image"), icon: "💾"),
    ]

    /// The three external programs of 7-Zip's Editor tab. The raw value doubles as the
    /// button tag, which is how an `@objc` action learns which row it was fired from.
    private enum ExternalProgramSlot: Int, CaseIterable {
        case viewer = 0
        case editor = 1
        case diff = 2

        var label: String {
            switch self {
            case .viewer: return L("prefs.viewer", fallback: "Viewer:")
            case .editor: return L("prefs.editor_app", fallback: "Editor:")
            case .diff: return L("prefs.diff", fallback: "Diff:")
            }
        }

        /// Shown when nothing is configured.
        var emptyDescription: String {
            switch self {
            case .viewer, .editor: return L("prefs.system_default", fallback: "System default")
            case .diff: return L("prefs.not_set", fallback: "Not set")
            }
        }

        var application: URL? {
            get {
                switch self {
                case .viewer: return AppSettings.viewerApplication
                case .editor: return AppSettings.editorApplication
                case .diff: return AppSettings.diffApplication
                }
            }
            nonmutating set {
                switch self {
                case .viewer: AppSettings.viewerApplication = newValue
                case .editor: AppSettings.editorApplication = newValue
                case .diff: AppSettings.diffApplication = newValue
                }
            }
        }
    }

    private var checkboxes: [String: NSButton] = [:]
    private var tabView: NSTabView!
    private var applyButton: NSButton!
    private var progressIndicator: NSProgressIndicator!

    // Extraction tab
    private var quarantinePopup: NSPopUpButton!
    private var quarantineExplanation: NSTextField!

    // Folders tab
    private var workingFolderRadios: [WorkingFolderMode: NSButton] = [:]
    private var workingFolderField: NSTextField!
    private var workingFolderChooseButton: NSButton!

    // Editor tab
    private var programFields: [ExternalProgramSlot: NSTextField] = [:]

    /// UserDefaults key: [utiIdentifier: bundleID] of the handler that owned each UTI before we claimed it.
    private static let previousHandlersKey = AppSettings.Key.Legacy.previousHandlers
    private static let legacySetter: LegacyHandlerSetting = LegacyHandlerSetter()

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("prefs.title")
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        setupUI()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let window = window else { return }

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        window.contentView = contentView

        tabView = NSTabView(frame: contentView.bounds)
        tabView.autoresizingMask = [.width, .height]
        contentView.addSubview(tabView)

        addTab("associations", L("prefs.file_assoc"), createAssociationsTab())
        addTab("general", L("prefs.general"), createGeneralTab())
        addTab("extraction", L("prefs.extraction", fallback: "Extraction"), createExtractionTab())
        addTab("folders", L("prefs.folders", fallback: "Folders"), createFoldersTab())
        addTab("editor", L("prefs.editor", fallback: "Editor"), createEditorTab())
    }

    private func addTab(_ identifier: String, _ label: String, _ view: NSView) {
        let item = NSTabViewItem(identifier: identifier)
        item.label = label
        item.view = view
        tabView.addTabViewItem(item)
    }

    // MARK: - File Associations Tab

    private func createAssociationsTab() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))

        // Header
        let header = NSTextField(labelWithString: L("prefs.choose_formats"))
        header.frame = NSRect(x: 20, y: 395, width: 480, height: 20)
        header.autoresizingMask = [.width, .minYMargin]
        header.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        container.addSubview(header)

        // Scroll view for checkboxes
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 480, height: 330))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        let clipView = NSClipView(frame: scrollView.bounds)
        scrollView.contentView = clipView

        let listView = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: CGFloat(Self.supportedFormats.count * 36 + 10)))

        let bundleId = Bundle.main.bundleIdentifier ?? "com.donishsoft.tajarchive"

        for (index, format) in Self.supportedFormats.enumerated() {
            let y = listView.frame.height - CGFloat((index + 1) * 36)

            // Checkbox
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(formatToggled(_:)))
            checkbox.frame = NSRect(x: 10, y: y, width: 20, height: 24)
            checkbox.tag = index

            // Check if currently the default handler
            let isDefault = isDefaultHandler(for: format.utType, bundleId: bundleId)
            checkbox.state = isDefault ? .on : .off
            checkboxes[format.ext] = checkbox
            listView.addSubview(checkbox)

            // Icon + extension label
            let extLabel = NSTextField(labelWithString: "\(format.icon)  .\(format.ext)")
            extLabel.frame = NSRect(x: 40, y: y, width: 100, height: 24)
            extLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
            listView.addSubview(extLabel)

            // Description
            let descLabel = NSTextField(labelWithString: format.name)
            descLabel.frame = NSRect(x: 140, y: y, width: 225, height: 24)
            descLabel.lineBreakMode = .byTruncatingTail
            descLabel.font = NSFont.systemFont(ofSize: 13)
            descLabel.textColor = .secondaryLabelColor
            listView.addSubview(descLabel)

            // Status indicator
            let statusLabel = NSTextField(labelWithString: isDefault ? "✅ " + L("prefs.default") : "")
            statusLabel.frame = NSRect(x: 370, y: y, width: 80, height: 24)
            statusLabel.font = NSFont.systemFont(ofSize: 11)
            statusLabel.textColor = .tertiaryLabelColor
            statusLabel.tag = 1000 + index
            listView.addSubview(statusLabel)
        }

        scrollView.documentView = listView
        container.addSubview(scrollView)
        // The list view is not flipped, so its first rows sit at the top of its frame;
        // start scrolled there rather than at the bottom.
        listView.scroll(NSPoint(x: 0, y: max(0, listView.frame.height - scrollView.contentSize.height)))

        // Buttons
        // Buttons size to their (translated) titles
        let selectAllBtn = NSButton(title: L("prefs.select_all"), target: self, action: #selector(selectAllFormats))
        selectAllBtn.bezelStyle = NSButton.BezelStyle.rounded
        let selectWidth = max(100, selectAllBtn.fittingSize.width + 8)
        selectAllBtn.frame = NSRect(x: 20, y: 20, width: selectWidth, height: 32)
        container.addSubview(selectAllBtn)

        let deselectAllBtn = NSButton(title: L("prefs.deselect_all"), target: self, action: #selector(deselectAllFormats))
        deselectAllBtn.bezelStyle = NSButton.BezelStyle.rounded
        let deselectWidth = max(100, deselectAllBtn.fittingSize.width + 8)
        deselectAllBtn.frame = NSRect(x: 20 + selectWidth + 10, y: 20, width: deselectWidth, height: 32)
        container.addSubview(deselectAllBtn)

        let applyBtn = NSButton(title: L("prefs.apply"), target: self, action: #selector(applyAssociations))
        applyBtn.bezelStyle = NSButton.BezelStyle.rounded
        applyBtn.keyEquivalent = "\r"
        applyBtn.frame = NSRect(x: 370, y: 20, width: 130, height: 32)
        applyBtn.autoresizingMask = [.minXMargin]
        container.addSubview(applyBtn)
        applyButton = applyBtn

        let spinner = NSProgressIndicator(frame: NSRect(x: 344, y: 27, width: 18, height: 18))
        spinner.autoresizingMask = [.minXMargin]
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        container.addSubview(spinner)
        progressIndicator = spinner

        return container
    }

    // MARK: - General Tab

    private func createGeneralTab() -> NSView {
        let container = makeTabContainer()
        let grid = makeGrid(in: container)

        // ── Appearance ──
        addSection(grid, L("prefs.appearance_section", fallback: "Appearance"))

        let themePopup = NSPopUpButton()
        themePopup.addItems(withTitles: [L("prefs.theme_system"), L("prefs.theme_dark"), L("prefs.theme_light")])
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        switch UserDefaults.standard.string(forKey: AppSettings.Key.Legacy.appTheme) ?? "system" {
        case "dark": themePopup.selectItem(at: 1)
        case "light": themePopup.selectItem(at: 2)
        default: themePopup.selectItem(at: 0)
        }
        addRow(grid, L("prefs.appearance"), themePopup, width: 200)

        let langPopup = NSPopUpButton()
        langPopup.addItems(withTitles: [L("Same as macOS"), "English", "Русский", "Тоҷикӣ"])
        langPopup.target = self
        langPopup.action = #selector(languageChanged(_:))
        let savedLang = UserDefaults.standard.string(forKey: AppSettings.Key.Legacy.selectedLanguage) ?? ""
        langPopup.selectItem(at: Self.languageCodes.firstIndex(of: savedLang) ?? 0)
        addRow(grid, L("prefs.language"), langPopup, width: 200)

        // ── File list ──
        addSection(grid, L("prefs.list_section", fallback: "File list"))

        addCheckboxRow(grid,
                       title: L("prefs.real_icons", fallback: "Show real file icons"),
                       isOn: AppSettings.showRealFileIcons,
                       action: #selector(showRealFileIconsToggled(_:)))
        addCheckboxRow(grid,
                       title: L("prefs.grid_lines", fallback: "Show grid lines"),
                       isOn: AppSettings.showGridLines,
                       action: #selector(showGridLinesToggled(_:)))
        addCheckboxRow(grid,
                       title: L("prefs.single_click", fallback: "Single click to open"),
                       isOn: AppSettings.singleClickToOpen,
                       action: #selector(singleClickToOpenToggled(_:)))
        addNote(grid, L("prefs.list_note",
                        fallback: "List changes take effect the next time a folder or archive is opened."))

        // ── Finder ──
        addSection(grid, L("Finder"))
        let setupButton = NSButton(title: L("Setup Assistant…"), target: NSApp.delegate,
                                   action: #selector(AppDelegate.showSetupAssistant))
        setupButton.bezelStyle = .rounded
        addRow(grid, "", setupButton, width: 200)
        addNote(grid, L("Turn on the Finder menu and choose which archives open in TajArchive."))

        return container
    }

    // MARK: - Extraction Tab

    private func createExtractionTab() -> NSView {
        let container = makeTabContainer()
        let grid = makeGrid(in: container)

        addSection(grid, L("prefs.quarantine_section", fallback: "Download mark (quarantine)"))

        quarantinePopup = NSPopUpButton()
        quarantinePopup.target = self
        quarantinePopup.action = #selector(quarantinePropagationChanged(_:))
        for mode in QuarantinePropagation.allCases {
            quarantinePopup.addItem(withTitle: mode.displayName)
            quarantinePopup.lastItem?.representedObject = mode
        }
        selectItem(in: quarantinePopup) { ($0 as? QuarantinePropagation) == AppSettings.quarantinePropagation }
        addRow(grid, L("prefs.propagate_mark", fallback: "Propagate mark:"), quarantinePopup, width: 300)

        quarantineExplanation = makeNoteLabel(AppSettings.quarantinePropagation.explanation)
        addRow(grid, "", quarantineExplanation, width: Self.noteWidth)

        addNote(grid, L("prefs.quarantine_note", fallback:
            "Files downloaded from the internet carry a mark that makes macOS check them "
            + "before they run. This setting decides whether files unpacked from a "
            + "downloaded archive keep that mark."))

        return container
    }

    // MARK: - Folders Tab

    private func createFoldersTab() -> NSView {
        let container = makeTabContainer()
        let grid = makeGrid(in: container)

        addSection(grid, L("prefs.working_folder_section", fallback: "Working folder"))

        let radioStack = NSStackView()
        radioStack.orientation = .vertical
        radioStack.alignment = .leading
        radioStack.spacing = 6
        radioStack.translatesAutoresizingMaskIntoConstraints = false
        for mode in WorkingFolderMode.allCases {
            let radio = NSButton(radioButtonWithTitle: mode.displayName,
                                 target: self,
                                 action: #selector(workingFolderModeChanged(_:)))
            radio.tag = WorkingFolderMode.allCases.firstIndex(of: mode) ?? 0
            radio.state = (AppSettings.workingFolderMode == mode) ? .on : .off
            workingFolderRadios[mode] = radio
            radioStack.addArrangedSubview(radio)
        }
        addRow(grid, L("prefs.temp_files", fallback: "Temporary files:"), radioStack, width: 320)

        workingFolderField = NSTextField(labelWithString: "")
        workingFolderField.isSelectable = true
        workingFolderField.lineBreakMode = .byTruncatingMiddle
        workingFolderField.textColor = .secondaryLabelColor
        workingFolderChooseButton = NSButton(title: L("prefs.choose", fallback: "Choose…"),
                                             target: self,
                                             action: #selector(chooseWorkingFolder))
        workingFolderChooseButton.bezelStyle = NSButton.BezelStyle.rounded
        addRow(grid, "",
               pair(workingFolderField, workingFolderChooseButton, controlWidth: 215),
               width: 320)

        addCheckboxRow(grid,
                       title: L("prefs.removable_only", fallback: "Use only for removable drives"),
                       isOn: AppSettings.useWorkingFolderForRemovableDrivesOnly,
                       action: #selector(removableOnlyToggled(_:)))

        addNote(grid, L("prefs.working_folder_note", fallback:
            "Temporary files are written here while an archive is opened, tested or updated. "
            + "Keeping them on the same volume as the archive makes the final move a rename "
            + "instead of a copy; the system temp folder is emptied for you."))

        updateWorkingFolderControls()
        return container
    }

    // MARK: - Editor Tab

    private func createEditorTab() -> NSView {
        let container = makeTabContainer()
        let grid = makeGrid(in: container)

        addSection(grid, L("prefs.external_programs", fallback: "External programs"))

        for slot in ExternalProgramSlot.allCases {
            let field = NSTextField(labelWithString: "")
            field.isSelectable = true
            field.lineBreakMode = .byTruncatingMiddle
            programFields[slot] = field

            let chooseButton = NSButton(title: L("prefs.choose", fallback: "Choose…"),
                                        target: self,
                                        action: #selector(chooseExternalProgram(_:)))
            chooseButton.bezelStyle = NSButton.BezelStyle.rounded
            chooseButton.tag = slot.rawValue

            let clearButton = NSButton(title: L("prefs.clear", fallback: "Clear"),
                                       target: self,
                                       action: #selector(clearExternalProgram(_:)))
            clearButton.bezelStyle = NSButton.BezelStyle.rounded
            clearButton.tag = slot.rawValue

            let buttons = NSStackView(views: [chooseButton, clearButton])
            buttons.orientation = .horizontal
            buttons.spacing = 6
            addRow(grid, slot.label, pair(field, buttons, controlWidth: 165), width: 340)

            refreshProgramField(slot)
        }

        addNote(grid, L("prefs.external_programs_note", fallback:
            "Used for View, Edit and Compare on files inside an archive. Leave a program "
            + "unset to let macOS pick the app that normally opens that kind of file."))

        return container
    }

    // MARK: - Layout helpers

    /// Tab pages are laid out with Auto Layout inside a frame the tab view resizes,
    /// matching the grid idiom of the Add-to-Archive sheet.
    private func makeTabContainer() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
    }

    private func makeGrid(in container: NSView) -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 5
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        // One label width for every tab, wide enough for the longest translated label
        grid.column(at: 0).width = fittingLabelWidth([
            L("prefs.appearance"), L("prefs.language"),
            L("prefs.propagate_mark", fallback: "Propagate mark:"),
            L("prefs.temp_files", fallback: "Temporary files:"),
            L("prefs.viewer", fallback: "Viewer:"), L("prefs.editor_app", fallback: "Editor:"),
            L("prefs.diff", fallback: "Diff:")
        ], minimum: 140)
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20)
        ])
        return grid
    }

    /// Adds a section header spanning both grid columns.
    private func addSection(_ grid: NSGridView, _ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        // A merged cell inherits the placement of the column it starts in, and column 0
        // is trailing so the labels line up against their controls. Without this the
        // header would be flung to the right edge of the whole window.
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

    /// A checkbox sits in the control column with no label of its own, so the
    /// column of controls stays aligned down the page.
    @discardableResult
    private func addCheckboxRow(_ grid: NSGridView, title: String, isOn: Bool, action: Selector) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.state = isOn ? .on : .off
        addRow(grid, "", checkbox, width: 340)
        return checkbox
    }

    /// Wrapping width shared by every explanatory label, so the width a label wraps at
    /// is always the width it is laid out at.
    private static let noteWidth: CGFloat = 340

    /// Small secondary text under the controls it explains.
    private func addNote(_ grid: NSGridView, _ text: String) {
        addRow(grid, "", makeNoteLabel(text), width: Self.noteWidth)
    }

    private func makeNoteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.noteWidth
        label.isSelectable = false
        return label
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

    private func selectItem(in popup: NSPopUpButton, matching predicate: (Any?) -> Bool) {
        for item in popup.itemArray where predicate(item.representedObject) {
            popup.select(item)
            return
        }
    }

    // MARK: - Actions

    @objc private func formatToggled(_ sender: NSButton) {
        // Visual feedback only — actual change on "Apply"
    }

    @objc private func selectAllFormats() {
        for (_, checkbox) in checkboxes {
            checkbox.state = .on
        }
    }

    @objc private func deselectAllFormats() {
        for (_, checkbox) in checkboxes {
            checkbox.state = .off
        }
    }

    @objc private func applyAssociations() {
        // Prefer the installed copy, not a running build somewhere else
        let appURL = DefaultArchiveApp.applicationURL
        let ownBundleId = Bundle.main.bundleIdentifier ?? "com.donishsoft.tajarchive"

        // Snapshot checkbox states before going async
        var toClaim: [ArchiveFormat] = []
        var toRelease: [ArchiveFormat] = []
        for format in Self.supportedFormats {
            guard let checkbox = checkboxes[format.ext] else { continue }
            if checkbox.state == .on {
                toClaim.append(format)
            } else {
                toRelease.append(format)
            }
        }

        applyButton.isEnabled = false
        progressIndicator.startAnimation(nil)

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            var claimedOK: [String] = []
            var claimFailures: [(ext: String, reason: String)] = []
            var releasedOK: [String] = []
            var cannotRelease: [String] = []

            var previousHandlers = UserDefaults.standard
                .dictionary(forKey: Self.previousHandlersKey) as? [String: String] ?? [:]

            // --- Claim checked formats ---
            for format in toClaim {
                guard let utType = UTType(format.utType) else {
                    // UTI not resolvable on this system — fall back to the legacy API
                    let status = Self.legacySetter.setDefaultRoleHandler(format.utType, ownBundleId)
                    if status == 0 {
                        claimedOK.append(format.ext)
                    } else {
                        claimFailures.append((format.ext, "OSStatus \(status)"))
                    }
                    continue
                }

                // Record the current handler BEFORE claiming, so the association
                // can be handed back on release. Never record ourselves.
                if let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: utType),
                   let handlerID = Bundle(url: handlerURL)?.bundleIdentifier,
                   handlerID.lowercased() != ownBundleId.lowercased() {
                    previousHandlers[format.utType] = handlerID
                }

                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: utType)
                    claimedOK.append(format.ext)
                } catch {
                    claimFailures.append((format.ext, error.localizedDescription))
                }
            }

            // --- Release unchecked formats we currently own ---
            for format in toRelease {
                guard self.isDefaultHandler(for: format.utType, bundleId: ownBundleId) else { continue }

                if let prevID = previousHandlers[format.utType],
                   prevID.lowercased() != ownBundleId.lowercased() {
                    let status = Self.legacySetter.setDefaultRoleHandler(format.utType, prevID)
                    if status == 0 {
                        releasedOK.append(format.ext)
                        previousHandlers.removeValue(forKey: format.utType)
                    } else {
                        cannotRelease.append(format.ext)
                    }
                } else {
                    // No previous handler recorded — macOS has no "unset" API
                    cannotRelease.append(format.ext)
                }
            }

            UserDefaults.standard.set(previousHandlers, forKey: Self.previousHandlersKey)

            self.progressIndicator.stopAnimation(nil)
            self.applyButton.isEnabled = true
            self.refreshStatusLabels()
            self.showApplySummary(
                claimed: claimedOK,
                failures: claimFailures,
                released: releasedOK,
                cannotRelease: cannotRelease
            )
        }
    }

    private func showApplySummary(
        claimed: [String],
        failures: [(ext: String, reason: String)],
        released: [String],
        cannotRelease: [String]
    ) {
        let alert = NSAlert()
        alert.messageText = L("prefs.assoc_updated")
        alert.alertStyle = (failures.isEmpty && cannotRelease.isEmpty) ? .informational : .warning
        alert.addButton(withTitle: L("dialog.ok"))

        var lines: [String] = [L("prefs.assoc_claimed", claimed.count, released.count)]
        if !claimed.isEmpty {
            lines.append("✅ " + claimed.map { ".\($0)" }.joined(separator: ", "))
        }
        if !released.isEmpty {
            lines.append("↩️ " + released.map { ".\($0)" }.joined(separator: ", "))
        }
        if !failures.isEmpty {
            lines.append("")
            for failure in failures {
                lines.append("❌ .\(failure.ext): \(failure.reason)")
            }
        }
        if !cannotRelease.isEmpty {
            lines.append("")
            lines.append(
                "⚠️ " + cannotRelease.map { ".\($0)" }.joined(separator: ", ")
                + " — " + L("macOS cannot release a format without knowing which app handled it before. Choose another app for it in Finder → Get Info → Open with.")
            )
        }
        alert.informativeText = lines.joined(separator: "\n")

        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        let theme: String
        switch index {
        case 1:
            theme = "dark"
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case 2:
            theme = "light"
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            theme = "system"
            NSApp.appearance = nil
        }
        UserDefaults.standard.set(theme, forKey: AppSettings.Key.Legacy.appTheme)
    }

    /// Order matches the titles in the language pop-up; "" follows the macOS setting.
    private static let languageCodes = ["", "en", "ru", "tg"]

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let languages = Self.languageCodes
        let index = sender.indexOfSelectedItem
        guard index < languages.count else { return }

        let lang = languages[index]
        if lang.isEmpty {
            UserDefaults.standard.removeObject(forKey: AppSettings.Key.Legacy.selectedLanguage)
            UserDefaults.standard.removeObject(forKey: AppSettings.Key.Legacy.appleLanguages)
        } else {
            UserDefaults.standard.set(lang, forKey: AppSettings.Key.Legacy.selectedLanguage)
            UserDefaults.standard.set([lang], forKey: AppSettings.Key.Legacy.appleLanguages)
        }
        
        // Restart the app to apply language change
        let alert = NSAlert()
        alert.messageText = L("prefs.language")
        alert.informativeText = L("Restart the app to apply the new language.")
        alert.addButton(withTitle: L("Restart"))
        alert.addButton(withTitle: L("dialog.cancel"))
        
        if let window = window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    AppRelauncher.relaunch(at: Bundle.main.bundleURL)
                }
            }
        }
    }

    // MARK: - List behaviour actions

    @objc private func showRealFileIconsToggled(_ sender: NSButton) {
        AppSettings.showRealFileIcons = (sender.state == .on)
    }

    @objc private func showGridLinesToggled(_ sender: NSButton) {
        AppSettings.showGridLines = (sender.state == .on)
    }

    @objc private func singleClickToOpenToggled(_ sender: NSButton) {
        AppSettings.singleClickToOpen = (sender.state == .on)
    }

    // MARK: - Extraction actions

    @objc private func quarantinePropagationChanged(_ sender: NSPopUpButton) {
        guard let mode = sender.selectedItem?.representedObject as? QuarantinePropagation else { return }
        AppSettings.quarantinePropagation = mode
        quarantineExplanation.stringValue = mode.explanation
    }

    // MARK: - Folders actions

    @objc private func workingFolderModeChanged(_ sender: NSButton) {
        let modes = WorkingFolderMode.allCases
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        AppSettings.workingFolderMode = modes[sender.tag]
        updateWorkingFolderControls()
    }

    @objc private func removableOnlyToggled(_ sender: NSButton) {
        AppSettings.useWorkingFolderForRemovableDrivesOnly = (sender.state == .on)
    }

    @objc private func chooseWorkingFolder() {
        let panel = NSOpenPanel()
        panel.title = L("prefs.choose_working_folder", fallback: "Choose Working Folder")
        panel.prompt = L("prefs.choose", fallback: "Choose…")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppSettings.workingFolder

        run(panel) { [weak self] url in
            AppSettings.workingFolder = url
            // The button is only reachable in "Specified folder" mode, but a picked folder
            // should never sit inert behind another mode if that ever changes.
            AppSettings.workingFolderMode = .specified
            self?.syncWorkingFolderRadios()
            self?.updateWorkingFolderControls()
        }
    }

    // MARK: - External program actions

    @objc private func chooseExternalProgram(_ sender: NSButton) {
        guard let slot = ExternalProgramSlot(rawValue: sender.tag) else { return }

        let panel = NSOpenPanel()
        panel.title = L("prefs.choose_application", fallback: "Choose Application")
        panel.prompt = L("prefs.choose", fallback: "Choose…")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = slot.application?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/Applications")

        run(panel) { [weak self] url in
            slot.application = url
            self?.refreshProgramField(slot)
        }
    }

    @objc private func clearExternalProgram(_ sender: NSButton) {
        guard let slot = ExternalProgramSlot(rawValue: sender.tag) else { return }
        slot.application = nil
        refreshProgramField(slot)
    }

    /// Runs an open panel as a sheet when there is a window to hang it off, modally
    /// otherwise, and calls back only when the user actually picked something.
    private func run(_ panel: NSOpenPanel, completion: @escaping (URL) -> Void) {
        guard let window = window else {
            if panel.runModal() == .OK, let url = panel.url { completion(url) }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    // MARK: - New-tab state refresh

    private func syncWorkingFolderRadios() {
        let current = AppSettings.workingFolderMode
        for (mode, radio) in workingFolderRadios {
            radio.state = (mode == current) ? .on : .off
        }
    }

    private func updateWorkingFolderControls() {
        let isSpecified = AppSettings.workingFolderMode == .specified
        workingFolderField.isEnabled = isSpecified
        workingFolderChooseButton.isEnabled = isSpecified

        if let folder = AppSettings.workingFolder {
            workingFolderField.stringValue = folder.path
            workingFolderField.toolTip = folder.path
        } else {
            workingFolderField.stringValue = L("prefs.no_folder_chosen", fallback: "No folder chosen")
            workingFolderField.toolTip = nil
        }
        workingFolderField.textColor = isSpecified ? .labelColor : .tertiaryLabelColor
    }

    private func refreshProgramField(_ slot: ExternalProgramSlot) {
        guard let field = programFields[slot] else { return }

        guard let url = slot.application else {
            field.stringValue = slot.emptyDescription
            field.textColor = .tertiaryLabelColor
            field.toolTip = nil
            return
        }

        let name = FileManager.default.displayName(atPath: url.path)
        if FileManager.default.fileExists(atPath: url.path) {
            field.stringValue = name
            field.textColor = .labelColor
        } else {
            // Honest about a program that has been moved or deleted since it was picked.
            field.stringValue = name + " " + L("prefs.missing", fallback: "(missing)")
            field.textColor = .systemRed
        }
        field.toolTip = url.path
    }

    // MARK: - Helpers

    private func isDefaultHandler(for utType: String, bundleId: String) -> Bool {
        if let defaultHandler = LSCopyDefaultRoleHandlerForContentType(utType as CFString, .all)?.takeRetainedValue() as String? {
            return defaultHandler.lowercased() == bundleId.lowercased()
        }
        return false
    }

    private func refreshStatusLabels() {
        // Looked up by identifier rather than by index so that adding tabs cannot
        // silently point this at the wrong page.
        guard let assocTab = tabView.tabViewItems.first(where: { $0.identifier as? String == "associations" }),
              let scrollView = assocTab.view?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let listView = scrollView.documentView else { return }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.donishsoft.tajarchive"

        for (index, format) in Self.supportedFormats.enumerated() {
            let isDefault = isDefaultHandler(for: format.utType, bundleId: bundleId)
            if let statusLabel = listView.subviews.first(where: { $0.tag == 1000 + index }) as? NSTextField {
                statusLabel.stringValue = isDefault ? "✅ " + L("prefs.default") : ""
            }
        }
    }
}

// MARK: - Legacy Launch Services Shim

/// `LSSetDefaultRoleHandlerForContentType` is deprecated in macOS 12, but it remains the only
/// API that can hand a file association to *another* app by bundle identifier (needed to release
/// an association). Dispatching through a protocol witness keeps the deliberate call sites free
/// of deprecation warnings while confining the deprecated call to one place.
private protocol LegacyHandlerSetting {
    func setDefaultRoleHandler(_ uti: String, _ bundleID: String) -> OSStatus
}

private struct LegacyHandlerSetter: LegacyHandlerSetting {
    @available(macOS, introduced: 10.10, deprecated: 12.0)
    func setDefaultRoleHandler(_ uti: String, _ bundleID: String) -> OSStatus {
        LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, bundleID as CFString)
    }
}
