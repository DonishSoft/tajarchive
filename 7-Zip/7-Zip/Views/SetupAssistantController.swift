import Cocoa

/// First-run window: turns on the Finder menu and makes TajArchive the app for archives,
/// each with one click. Shown once automatically and from the app menu afterwards.
final class SetupAssistantController: NSWindowController {

    static let shownKey = "SetupAssistantShown"

    private var finderButton: NSButton!
    private var finderStatus: NSTextField!
    private var finderHint: NSTextField!
    private var defaultButton: NSButton!
    private var defaultStatus: NSTextField!
    private var filesButton: NSButton!
    private var filesStatus: NSTextField!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Welcome to TajArchive")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
        window.center()
    }

    /// Shows the window once per user, unless a test run asked to skip it.
    static func shouldShowAutomatically() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "SkipSetupAssistant") { return false }
        return !defaults.bool(forKey: shownKey)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let window = window else { return }
        let content = NSView()
        window.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: L("Welcome to TajArchive"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: L("A free archiver built on the 7-Zip engine. Two clicks make it part of your Mac — you can change both later in Settings."))
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 440

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4

        let header = NSStackView(views: [icon, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        finderButton = NSButton(title: L("Turn On"), target: self, action: #selector(enableFinderMenu))
        finderButton.bezelStyle = .rounded
        finderStatus = makeStatusLabel()
        finderHint = NSTextField(wrappingLabelWithString: L("macOS did not let the app switch it on. Click “Open System Settings” and turn on “TajArchive Finder Extension”."))
        finderHint.font = .systemFont(ofSize: 11)
        finderHint.textColor = .systemOrange
        finderHint.preferredMaxLayoutWidth = 330
        finderHint.isHidden = true

        #if APPSTORE
        // The sandboxed build cannot switch the extension on itself.
        finderButton.title = L("Open System Settings")
        finderHint.stringValue = L("Turn on “TajArchive Finder Extension” in System Settings.")
        finderHint.textColor = .secondaryLabelColor
        finderHint.isHidden = false
        #endif

        filesButton = NSButton(title: L("Allow Access…"), target: self, action: #selector(allowFileAccess))
        filesButton.bezelStyle = .rounded
        filesStatus = makeStatusLabel()

        defaultButton = NSButton(title: L("Set as Default"), target: self, action: #selector(makeDefault))
        defaultButton.bezelStyle = .rounded
        defaultStatus = makeStatusLabel()

        let finderStep = makeStep(
            symbol: "contextualmenu.and.cursorarrow",
            title: L("Finder menu"),
            detail: L("Right-click files in Finder to compress, extract or test them."),
            extra: finderHint,
            controls: [finderStatus, finderButton]
        )
        let defaultStep = makeStep(
            symbol: "doc.zipper",
            title: L("Open archives with TajArchive"),
            detail: L("Double-click .7z, .rar and other archives to open them here. ZIP files keep opening the way they do now."),
            extra: nil,
            controls: [defaultStatus, defaultButton]
        )
        let filesStep = makeStep(
            symbol: "folder.badge.person.crop",
            title: L("Access to your files"),
            detail: L("Let TajArchive open archives and save files anywhere in your home folder. Otherwise it asks for each folder separately."),
            extra: nil,
            controls: [filesStatus, filesButton]
        )
        filesStep.isHidden = !FolderAccess.isSandboxed
        let previewStep = makeStep(
            symbol: "eye",
            title: L("Quick Look"),
            detail: L("Select an archive in Finder and press Space to see what is inside. Nothing to set up."),
            extra: nil,
            controls: []
        )

        let doneButton = NSButton(title: L("Done"), target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        let footnote = NSTextField(labelWithString: L("This window is always available from the TajArchive menu."))
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [footnote, NSView(), doneButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [header, filesStep, finderStep, defaultStep, previewStep, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(22, after: header)
        stack.setCustomSpacing(22, after: previewStep)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            finderStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filesStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            defaultStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewStep.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func makeStatusLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.textColor = .systemGreen
        label.font = .systemFont(ofSize: 13, weight: .medium)
        return label
    }

    /// One rounded card: symbol, title and explanation on the left, controls on the right.
    private func makeStep(symbol: String, title: String, detail: String, extra: NSView?, controls: [NSView]) -> NSView {
        let card = CardView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)!)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 300

        var texts: [NSView] = [titleLabel, detailLabel]
        if let extra = extra { texts.append(extra) }
        let textStack = NSStackView(views: texts)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controlStack = NSStackView(views: controls)
        controlStack.orientation = .horizontal
        controlStack.spacing = 8
        controlStack.setContentHuggingPriority(.required, for: .horizontal)
        controlStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [image, textStack, controlStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        return card
    }

    /// Rounded, bordered background that follows light and dark mode.
    private final class CardView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    // MARK: - State

    @objc private func allowFileAccess() {
        FolderAccess.requestHomeAccess()
        refresh()
    }

    private func refresh() {
        let filesAllowed = FolderAccess.hasHomeAccess
        filesStatus.stringValue = filesAllowed ? "✓ " + L("Allowed") : ""
        filesButton.isHidden = filesAllowed

        let finderOn = FinderExtensionControl.isEnabled
        finderStatus.stringValue = finderOn ? "✓ " + L("On") : ""
        finderButton.isHidden = finderOn
        if finderOn { finderHint.isHidden = true }

        let isDefault = DefaultArchiveApp.isDefaultForRecommendedTypes
        defaultStatus.stringValue = isDefault ? "✓ " + L("Done") : ""
        defaultButton.isHidden = isDefault
    }

    @objc private func enableFinderMenu() {
        if finderButton.title == L("Open System Settings") {
            FinderExtensionControl.openSystemSettings()
            return
        }
        finderButton.isEnabled = false
        FinderExtensionControl.enable { [weak self] enabled in
            guard let self = self else { return }
            self.finderButton.isEnabled = true
            if !enabled {
                self.finderButton.title = L("Open System Settings")
                self.finderHint.isHidden = false
            }
            self.refresh()
        }
    }

    @objc private func makeDefault() {
        defaultButton.isEnabled = false
        Task { @MainActor [weak self] in
            _ = await DefaultArchiveApp.claimRecommendedTypes()
            self?.defaultButton.isEnabled = true
            self?.refresh()
        }
    }

    @objc private func done() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        close()
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SetupAssistantController: NSWindowDelegate {
    /// Coming back from System Settings: show what changed there.
    func windowDidBecomeKey(_ notification: Notification) {
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
    }
}
