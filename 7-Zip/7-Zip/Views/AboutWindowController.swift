import Cocoa

class AboutWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("About TajArchive")
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupUI()
        window.center()
    }

    /// The engine's own version, read from the bundled 7zz banner
    /// ("7-Zip (z) 25.01 (arm64) : Copyright (c) 1999-2025 Igor Pavlov").
    static let engineVersion: String = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SevenZipWrapper.binaryPath)
        process.arguments = ["i"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "25.01" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let banner = String(decoding: data.prefix(400), as: UTF8.self)
        if let range = banner.range(of: #"7-Zip(?: \(\w+\))? (\d+\.\d+)"#, options: .regularExpression) {
            let match = String(banner[range])
            if let version = match.split(separator: " ").last { return String(version) }
        }
        return "25.01"
    }()

    private func setupUI() {
        guard let window = window else { return }
        let content = NSView()
        window.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let name = NSTextField(labelWithString: "TajArchive")
        name.font = .systemFont(ofSize: 24, weight: .bold)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let versionLabel = NSTextField(labelWithString: L("Version %@ (%@)", version, build)
                                       + "  ·  " + L("7-Zip engine %@", Self.engineVersion))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true

        let summary = NSTextField(wrappingLabelWithString: L("A free, open-source archiver for macOS built on the 7-Zip engine by Igor Pavlov."))
        summary.alignment = .center
        summary.preferredMaxLayoutWidth = 360

        let legal = NSTextField(wrappingLabelWithString:
            L("7-Zip © 1999–2025 Igor Pavlov, GNU LGPL. RAR decoding uses the unRAR licence.") + "\n"
            + L("TajArchive and the .taj format © 2026 DonishSoft, GNU LGPL. TajArchive is not affiliated with the 7-Zip project."))
        legal.font = .systemFont(ofSize: 11)
        legal.textColor = .tertiaryLabelColor
        legal.alignment = .center
        legal.preferredMaxLayoutWidth = 380

        var buttons: [NSView] = [
            makeButton(L("Credits and Licenses"), #selector(showLicenses)),
            makeButton(L("7-Zip Website"), #selector(open7Zip)),
        ]
        if AppDelegate.websiteURL != nil {
            buttons.append(makeButton(L("TajArchive Website"), #selector(openWebsite)))
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [icon, name, versionLabel, summary, legal, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(16, after: versionLabel)
        stack.setCustomSpacing(14, after: summary)
        stack.setCustomSpacing(20, after: legal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
        ])
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func showLicenses() {
        let alert = NSAlert()
        alert.messageText = L("Credits and licenses")
        alert.informativeText = [
            L("TajArchive is built on the 7-Zip compression engine."),
            L("7-Zip — Copyright © 1999–2025 Igor Pavlov, https://www.7-zip.org/") + "\n"
                + L("Licensed under the GNU LGPL version 2.1 or later. The RAR decoding code is used under the unRAR licence, which forbids using it to recreate the RAR compression algorithm."),
            L("TajArchive runs the 7zz command-line program as a separate, unmodified executable inside its Resources folder. As the LGPL requires, you may replace it with any compatible build of your own; the complete 7-Zip source used for each release is published alongside it."),
            L("“7-Zip” is the name of Igor Pavlov's project. TajArchive is an independent application and is not affiliated with, endorsed by, or supported by the 7-Zip project."),
            L("Zstandard, LZ4 and Apple Archive files are created with tools that are part of macOS."),
            L("TajArchive and the .taj format — Copyright © 2026 DonishSoft, GNU LGPL. The .taj format specification ships with the source code."),
        ].joined(separator: "\n\n")
        alert.addButton(withTitle: L("OK"))
        alert.alertStyle = .informational
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    @objc private func open7Zip() {
        if let url = URL(string: "https://www.7-zip.org/") { NSWorkspace.shared.open(url) }
    }

    @objc private func openWebsite() {
        if let url = AppDelegate.websiteURL { NSWorkspace.shared.open(url) }
    }
}
