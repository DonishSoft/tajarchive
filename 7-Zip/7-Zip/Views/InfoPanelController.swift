import AppKit

/// Read-only properties panel: archive header info (type, method, solid, blocks, sizes)
/// or plain file attributes, shown as a two-column grid.
final class InfoPanelController: NSWindowController {

    init(title: String, properties: [(String, String)]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Info — %@", title)
        super.init(window: window)
        setupUI(properties: properties)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setupUI(properties: [(String, String)]) {
        guard let window = window else { return }
        let contentView = NSView()
        window.contentView = contentView

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        for (key, value) in properties {
            let keyLabel = NSTextField(labelWithString: key + ":")
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.font = .systemFont(ofSize: 12)

            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = .systemFont(ofSize: 12)
            valueLabel.isSelectable = true
            valueLabel.preferredMaxLayoutWidth = 300

            grid.addRow(with: [keyLabel, valueLabel])
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let clipDocument = NSView()
        clipDocument.translatesAutoresizingMaskIntoConstraints = false
        clipDocument.addSubview(grid)
        scrollView.documentView = clipDocument

        contentView.addSubview(scrollView)

        let contentHeight = min(CGFloat(properties.count) * 26 + 40, 520)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            clipDocument.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            grid.topAnchor.constraint(equalTo: clipDocument.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: clipDocument.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: clipDocument.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: clipDocument.bottomAnchor, constant: -16),

            contentView.heightAnchor.constraint(equalToConstant: contentHeight),
            contentView.widthAnchor.constraint(equalToConstant: 460)
        ])
    }
}
