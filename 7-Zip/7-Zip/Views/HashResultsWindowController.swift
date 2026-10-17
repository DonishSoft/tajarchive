import AppKit

/// Displays checksum results: one section per algorithm, per-file rows plus the
/// aggregate "for data" value, with a Copy button for the whole report.
final class HashResultsWindowController: NSWindowController {

    private let results: [HashResult]
    private var textView: NSTextView!

    init(results: [HashResult]) {
        self.results = results
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Checksums")
        window.center()
        super.init(window: window)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView()
        window.contentView = contentView

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.string = buildReport()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        let copyButton = NSButton(title: L("Copy All"), target: self, action: #selector(copyAll))
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: L("Close"), target: self, action: #selector(closeWindow))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.keyEquivalent = "\r"

        contentView.addSubview(scrollView)
        contentView.addSubview(copyButton)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -12),

            copyButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            copyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func buildReport() -> String {
        var lines: [String] = []
        for result in results {
            lines.append("─── \(result.algorithm.rawValue) ───")
            for file in result.files {
                let size = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
                lines.append("\(file.hash)  \(file.name)  (\(size))")
            }
            if let aggregate = result.aggregate, result.files.count > 1 {
                lines.append(L("%@  — aggregate for all data", aggregate))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func closeWindow() {
        window?.close()
    }
}
