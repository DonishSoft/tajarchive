import AppKit
import Darwin

// MARK: - Parsed model
//
// `7zz b` prints a fixed report. Everything below is modelled on the real output,
// e.g. for `7zz b -md=24 -mmt=4 3`:
//
//     7-Zip (z) 25.01 (arm64) : Copyright (c) 1999-2025 Igor Pavlov : 2025-08-03
//      d=24 mt=4
//     Apple M3 Pro 12C12T
//
//     RAM size:   18432 MB,  # CPU hardware threads:  12
//     RAM usage:    455 MB,  # Benchmark threads:      4
//
//                            Compressing  |                  Decompressing
//     Dict     Speed Usage    R/U Rating  |      Speed Usage    R/U Rating
//              KiB/s     %   MIPS   MIPS  |      KiB/s     %   MIPS   MIPS
//
//     22:      38652   393   9559  37601  |     338055   369   7805  28840
//     23:      36007   388   9452  36688  |     373483   387   8353  32317
//     ...
//     ----------------------------------  | ------------------------------
//     Avr:     38757   387  10236  39566  |     366476   384   8252  31715
//     Tot:             385   9244  35641
//
// Note that the number of `Dict` rows is chosen by 7-Zip itself (it walks a range of
// dictionary sizes up to `-md=`), and every extra pass repeats the whole block, so the
// parser must not assume a fixed row count.

/// One "Speed / Usage / R/U / Rating" group of a benchmark line.
/// `speed` is nil on the `Tot:` line, which prints no speed column.
struct BenchmarkMeasurement: Equatable {
    let speed: Int?          // KiB/s
    let usage: Int           // %
    let ratingPerUsage: Int  // R/U, MIPS
    let rating: Int          // MIPS
}

enum BenchmarkRowKind: Equatable {
    /// A `NN:` line. `log2Size` is the dictionary size exponent, `pass` is 1-based.
    case dictionary(log2Size: Int, pass: Int)
    case average
    case total
}

struct BenchmarkRow: Equatable {
    let kind: BenchmarkRowKind
    /// For `.total` this carries the combined figures (7-Zip prints them under the
    /// compressing columns) and `decompressing` is nil.
    let compressing: BenchmarkMeasurement?
    let decompressing: BenchmarkMeasurement?
}

struct BenchmarkReport {
    var version: String?          // "7-Zip (z) 25.01 (arm64)"
    var cpuDescription: String?   // 7-Zip's own CPU line, e.g. "Apple M3 Pro 12C12T"
    var ramSizeMB: Int?
    var hardwareThreads: Int?
    var ramUsageMB: Int?
    var benchmarkThreads: Int?
    var rows: [BenchmarkRow] = []
    var rawOutput: String = ""

    var average: BenchmarkRow? {
        rows.first { $0.kind == .average }
    }

    var total: BenchmarkMeasurement? {
        rows.first { $0.kind == .total }?.compressing
    }

    /// Number of passes actually reported (7-Zip repeats the dictionary block per pass).
    var passCount: Int {
        var maximum = 0
        for row in rows {
            if case .dictionary(_, let pass) = row.kind { maximum = max(maximum, pass) }
        }
        return maximum
    }

    /// Human label for a dictionary exponent: 22 -> "4 MB", 18 -> "256 KB".
    static func dictionaryLabel(log2Size: Int) -> String {
        guard log2Size >= 0 && log2Size < 63 else { return "2^\(log2Size)" }
        if log2Size >= 30 { return L("%d GB", 1 << (log2Size - 30)) }
        if log2Size >= 20 { return L("%d MB", 1 << (log2Size - 20)) }
        if log2Size >= 10 { return L("%d KB", 1 << (log2Size - 10)) }
        return "\(1 << log2Size) B"
    }
}

// MARK: - Parser

/// Parses the text `7zz b` writes to stdout. Kept free of AppKit so it can be exercised
/// on its own against captured output.
enum BenchmarkParser {

    static func parse(_ output: String) -> BenchmarkReport {
        var report = BenchmarkReport()
        report.rawOutput = output

        var lines: [String] = []
        output.enumerateLines { line, _ in lines.append(line) }

        report.cpuDescription = cpuLine(in: lines)

        var previousDictionary = Int.max
        var pass = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("-") { continue }

            if report.version == nil, trimmed.hasPrefix("7-Zip"), trimmed.contains("Copyright") {
                // "7-Zip (z) 25.01 (arm64) : Copyright (c) ... : 2025-08-03"
                let head = trimmed.components(separatedBy: " : ").first ?? trimmed
                report.version = head.trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.hasPrefix("RAM size:") {
                let halves = trimmed.components(separatedBy: ",")
                report.ramSizeMB = integers(in: halves[0]).first
                if halves.count > 1 { report.hardwareThreads = integers(in: halves[1]).first }
                continue
            }
            if trimmed.hasPrefix("RAM usage:") {
                let halves = trimmed.components(separatedBy: ",")
                report.ramUsageMB = integers(in: halves[0]).first
                if halves.count > 1 { report.benchmarkThreads = integers(in: halves[1]).first }
                continue
            }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let label = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let body = trimmed[trimmed.index(after: colon)...]

            // Split the two column groups on the "|" 7-Zip prints between them.
            let groups = body.components(separatedBy: "|")
            let left = integers(in: groups[0])
            let right = groups.count > 1 ? integers(in: groups[1]) : []

            if label == "Avr" {
                guard left.count >= 4, right.count >= 4 else { continue }
                report.rows.append(BenchmarkRow(
                    kind: .average,
                    compressing: measurement(left),
                    decompressing: measurement(right)
                ))
            } else if label == "Tot" {
                guard left.count >= 3 else { continue }
                report.rows.append(BenchmarkRow(
                    kind: .total,
                    compressing: BenchmarkMeasurement(
                        speed: nil,
                        usage: left[0],
                        ratingPerUsage: left[1],
                        rating: left[2]
                    ),
                    decompressing: nil
                ))
            } else if isAllDigits(label), let log2Size = Int(label) {
                guard left.count >= 4, right.count >= 4 else { continue }
                // A dictionary value that does not grow means 7-Zip restarted the block,
                // i.e. a new pass began.
                if log2Size <= previousDictionary { pass += 1 }
                previousDictionary = log2Size
                report.rows.append(BenchmarkRow(
                    kind: .dictionary(log2Size: log2Size, pass: pass),
                    compressing: measurement(left),
                    decompressing: measurement(right)
                ))
            }
        }

        return report
    }

    // MARK: Helpers

    /// 7-Zip prints the CPU name on the last non-empty line before the "<n>T CPU Freq" block.
    private static func cpuLine(in lines: [String]) -> String? {
        guard let freqIndex = lines.firstIndex(where: { $0.contains("CPU Freq") }) else { return nil }
        var index = freqIndex - 1
        while index >= 0 {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { return candidate }
            index -= 1
        }
        return nil
    }

    private static func measurement(_ values: [Int]) -> BenchmarkMeasurement {
        BenchmarkMeasurement(
            speed: values[0],
            usage: values[1],
            ratingPerUsage: values[2],
            rating: values[3]
        )
    }

    private static func isAllDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Every run of ASCII digits in `text`, in order.
    private static func integers<S: StringProtocol>(in text: S) -> [Int] {
        var result: [Int] = []
        var current = ""
        for character in text {
            if character.isASCII && character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Int(current) { result.append(value) }
                current = ""
            }
        }
        if !current.isEmpty, let value = Int(current) { result.append(value) }
        return result
    }
}

// MARK: - Text rendering
//
// The results are drawn into a monospaced text view rather than an NSTableView: the report
// has two column *groups* ("Compressing" / "Decompressing") sharing four identically named
// sub-columns each, which NSTableView's single-line header cannot express without either
// inventing column names or hand-syncing a floating group strip against column positions.
// A monospaced grid reproduces the dialog's own layout exactly and stays correct at any
// window size.

extension BenchmarkReport {

    private enum Column {
        static let dictionary = 12
        static let compressSpeed = 9
        static let compressUsage = 7
        static let compressRatingPerUsage = 8
        static let compressRating = 9
        static let decompressSpeed = 10
        static let decompressUsage = 7
        static let decompressRatingPerUsage = 8
        static let decompressRating = 9
        static let separator = "  |"

        static var compressGroup: Int {
            compressSpeed + compressUsage + compressRatingPerUsage + compressRating
        }
        static var decompressGroup: Int {
            decompressSpeed + decompressUsage + decompressRatingPerUsage + decompressRating
        }
    }

    /// The grid of parsed rows, laid out like 7-Zip's own report.
    /// Returns "" when nothing parsed, so callers can fall back to the raw output.
    func renderedTable() -> String {
        guard !rows.isEmpty else { return "" }

        var lines: [String] = []
        lines.append(
            pad("", Column.dictionary)
            + center(L("Compressing"), Column.compressGroup)
            + Column.separator
            + center(L("Decompressing"), Column.decompressGroup)
        )
        lines.append(
            pad(L("Dict"), Column.dictionary)
            + right(L("Speed"), Column.compressSpeed)
            + right(L("Usage"), Column.compressUsage)
            + right("R/U", Column.compressRatingPerUsage)
            + right(L("Rating"), Column.compressRating)
            + Column.separator
            + right(L("Speed"), Column.decompressSpeed)
            + right(L("Usage"), Column.decompressUsage)
            + right("R/U", Column.decompressRatingPerUsage)
            + right(L("Rating"), Column.decompressRating)
        )
        lines.append(
            pad("", Column.dictionary)
            + right("KiB/s", Column.compressSpeed)
            + right("%", Column.compressUsage)
            + right("MIPS", Column.compressRatingPerUsage)
            + right("MIPS", Column.compressRating)
            + Column.separator
            + right("KiB/s", Column.decompressSpeed)
            + right("%", Column.decompressUsage)
            + right("MIPS", Column.decompressRatingPerUsage)
            + right("MIPS", Column.decompressRating)
        )
        lines.append("")

        let showPasses = passCount > 1
        var renderedPass = 0

        for row in rows {
            switch row.kind {
            case .dictionary(let log2Size, let pass):
                if showPasses && pass != renderedPass {
                    if renderedPass != 0 { lines.append("") }
                    renderedPass = pass
                    lines.append(L("Pass %d", pass))
                }
                let label = "\(log2Size) (\(BenchmarkReport.dictionaryLabel(log2Size: log2Size)))"
                lines.append(dataLine(label: label, row: row))

            case .average:
                lines.append(
                    String(repeating: "-", count: Column.dictionary + Column.compressGroup)
                    + Column.separator + " "
                    + String(repeating: "-", count: Column.decompressGroup - 1)
                )
                lines.append(dataLine(label: L("Avr:"), row: row))

            case .total:
                guard let total = row.compressing else { continue }
                lines.append(
                    pad(L("Tot:"), Column.dictionary)
                    + pad("", Column.compressSpeed)
                    + right("\(total.usage)", Column.compressUsage)
                    + right("\(total.ratingPerUsage)", Column.compressRatingPerUsage)
                    + right("\(total.rating)", Column.compressRating)
                )
            }
        }

        return lines
            .map { line in
                String(line.reversed().drop { $0 == " " }.reversed())
            }
            .joined(separator: "\n")
    }

    private func dataLine(label: String, row: BenchmarkRow) -> String {
        pad(label, Column.dictionary)
        + group(
            row.compressing,
            widths: (Column.compressSpeed, Column.compressUsage,
                     Column.compressRatingPerUsage, Column.compressRating)
        )
        + Column.separator
        + group(
            row.decompressing,
            widths: (Column.decompressSpeed, Column.decompressUsage,
                     Column.decompressRatingPerUsage, Column.decompressRating)
        )
    }

    private func group(
        _ measurement: BenchmarkMeasurement?,
        widths: (Int, Int, Int, Int)
    ) -> String {
        guard let measurement = measurement else {
            return pad("", widths.0 + widths.1 + widths.2 + widths.3)
        }
        let speed = measurement.speed.map(String.init) ?? ""
        return right(speed, widths.0)
            + right("\(measurement.usage)", widths.1)
            + right("\(measurement.ratingPerUsage)", widths.2)
            + right("\(measurement.rating)", widths.3)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    private func center(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text }
        let slack = width - text.count
        let leading = slack / 2
        return String(repeating: " ", count: leading)
            + text
            + String(repeating: " ", count: slack - leading)
    }
}

// MARK: - Window controller

/// Native counterpart of the Windows 7-Zip "Tools > Benchmark" dialog.
///
/// Runs `7zz b -md=<n> -mmt=<threads> <passes>` off the main thread, shows an
/// indeterminate progress bar and an elapsed-time readout while it works, then parses the
/// finished report. `7zz b` writes no percentage progress, so `runProcess`'s
/// `progressHandler` never fires for a benchmark — the timer is the only live feedback.
final class BenchmarkWindowController: NSWindowController, NSWindowDelegate {

    // MARK: Presentation

    /// Strong reference so the window survives after `presentBenchmark()` returns.
    private static var presentedController: BenchmarkWindowController?

    /// Creates (or re-uses) the Benchmark window and brings it to the front.
    @discardableResult
    static func presentBenchmark() -> BenchmarkWindowController {
        let controller = presentedController ?? BenchmarkWindowController()
        presentedController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    // MARK: Controls

    private let dictionaryPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let threadsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passesPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startButton = NSButton(title: L("Start"), target: nil, action: nil)
    private let stopButton = NSButton(title: L("Stop"), target: nil, action: nil)
    private let copyButton = NSButton(title: L("Copy Report"), target: nil, action: nil)
    private let closeButton = NSButton(title: L("Close"), target: nil, action: nil)

    private let progressIndicator = NSProgressIndicator()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: L("Ready."))

    private let cpuLabel = NSTextField(labelWithString: "")
    private let systemLabel = NSTextField(labelWithString: "")
    private let ratingCaptionLabel = NSTextField(labelWithString: L("Total Rating"))
    private let ratingLabel = NSTextField(labelWithString: "—")
    private let ratingDetailLabel = NSTextField(labelWithString: "")

    private let resultsScrollView = NSScrollView()
    private let resultsTextView = NSTextView()

    // MARK: Run state

    private var runTask: Task<Void, Never>?
    private var token: OperationToken?
    private var elapsedTimer: Timer?
    private var runStart: Date?
    private var stopRequested = false

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    // MARK: Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("Benchmark")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView()
        window.contentView = contentView

        let optionsRow = makeOptionsRow()
        let summaryRow = makeSummaryRow()
        let statusRow = makeStatusRow()
        let buttonRow = makeButtonRow()
        setupResultsView()

        for subview in [optionsRow, summaryRow, statusRow, resultsScrollView, buttonRow] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            optionsRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            optionsRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            optionsRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            summaryRow.topAnchor.constraint(equalTo: optionsRow.bottomAnchor, constant: 14),
            summaryRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            summaryRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            statusRow.topAnchor.constraint(equalTo: summaryRow.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            resultsScrollView.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 12),
            resultsScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            resultsScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            resultsScrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        cpuLabel.stringValue = BenchmarkWindowController.cpuDescription
        systemLabel.stringValue = L("Idle — press Start to run the benchmark.")
        updateElapsedLabel()
        setRunning(false)
    }

    private func makeOptionsRow() -> NSView {
        for log2Size in 20...29 {
            dictionaryPopUp.addItem(withTitle: BenchmarkReport.dictionaryLabel(log2Size: log2Size))
            dictionaryPopUp.lastItem?.tag = log2Size
        }
        _ = dictionaryPopUp.selectItem(withTag: BenchmarkWindowController.defaultDictionaryLog2)

        let maximumThreads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        for count in 1...maximumThreads {
            threadsPopUp.addItem(withTitle: count == maximumThreads ? L("%d (all)", count) : "\(count)")
            threadsPopUp.lastItem?.tag = count
        }
        _ = threadsPopUp.selectItem(withTag: maximumThreads)

        for count in BenchmarkWindowController.passOptions {
            passesPopUp.addItem(withTitle: "\(count)")
            passesPopUp.lastItem?.tag = count
        }
        _ = passesPopUp.selectItem(withTag: 1)

        startButton.target = self
        startButton.action = #selector(startBenchmark)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        stopButton.target = self
        stopButton.action = #selector(stopBenchmark)
        stopButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            makeFieldLabel(L("Dictionary size:")), dictionaryPopUp,
            makeFieldLabel(L("Threads:")), threadsPopUp,
            makeFieldLabel(L("Passes:")), passesPopUp,
            makeFlexibleSpacer(),
            startButton, stopButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.setCustomSpacing(18, after: dictionaryPopUp)
        stack.setCustomSpacing(18, after: threadsPopUp)
        return stack
    }

    private func makeSummaryRow() -> NSView {
        cpuLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        cpuLabel.lineBreakMode = .byTruncatingTail

        systemLabel.font = NSFont.systemFont(ofSize: 11)
        systemLabel.textColor = .secondaryLabelColor
        systemLabel.lineBreakMode = .byTruncatingTail

        let left = NSStackView(views: [cpuLabel, systemLabel])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        ratingCaptionLabel.font = NSFont.systemFont(ofSize: 11)
        ratingCaptionLabel.textColor = .secondaryLabelColor
        ratingCaptionLabel.alignment = .right

        ratingLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        ratingLabel.alignment = .right
        ratingLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        ratingDetailLabel.font = NSFont.systemFont(ofSize: 11)
        ratingDetailLabel.textColor = .secondaryLabelColor
        ratingDetailLabel.alignment = .right
        ratingDetailLabel.lineBreakMode = .byTruncatingTail

        let right = NSStackView(views: [ratingCaptionLabel, ratingLabel, ratingDetailLabel])
        right.orientation = .vertical
        right.alignment = .trailing
        right.spacing = 0
        right.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [left, makeFlexibleSpacer(), right])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        return stack
    }

    private func makeStatusRow() -> NSView {
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .small
        progressIndicator.usesThreadedAnimation = true
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.widthAnchor.constraint(equalToConstant: 160).isActive = true

        elapsedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .secondaryLabelColor

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [progressIndicator, elapsedLabel, statusLabel, makeFlexibleSpacer()])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        // Keep the bar's slot reserved while it is hidden so the row does not jump.
        stack.detachesHiddenViews = false
        return stack
    }

    private func makeButtonRow() -> NSView {
        copyButton.target = self
        copyButton.action = #selector(copyReport)
        copyButton.bezelStyle = .rounded

        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}" // Escape

        let stack = NSStackView(views: [copyButton, makeFlexibleSpacer(), closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func setupResultsView() {
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.hasHorizontalScroller = true
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.borderType = .bezelBorder

        resultsTextView.isEditable = false
        resultsTextView.isSelectable = true
        resultsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        resultsTextView.textContainerInset = NSSize(width: 10, height: 10)
        resultsTextView.minSize = NSSize(width: 0, height: 0)
        resultsTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        resultsTextView.isVerticallyResizable = true
        resultsTextView.isHorizontallyResizable = true
        resultsTextView.autoresizingMask = [.width, .height]
        // The grid must not wrap: give the container unlimited width and scroll instead.
        resultsTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        resultsTextView.textContainer?.widthTracksTextView = false

        resultsScrollView.documentView = resultsTextView
    }

    private func makeFieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    /// Empty view that soaks up leftover width so trailing controls stay right-aligned.
    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    // MARK: - Options

    private static let defaultDictionaryLog2 = 24
    private static let passOptions = [1, 2, 3, 5, 10]

    private var selectedDictionaryLog2: Int {
        let tag = dictionaryPopUp.selectedTag()
        return (20...29).contains(tag) ? tag : BenchmarkWindowController.defaultDictionaryLog2
    }

    private var selectedThreadCount: Int {
        let tag = threadsPopUp.selectedTag()
        return tag > 0 ? tag : max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    private var selectedPassCount: Int {
        let tag = passesPopUp.selectedTag()
        return tag > 0 ? tag : 1
    }

    // MARK: - Actions

    @objc private func startBenchmark(_ sender: Any?) {
        guard runTask == nil else { return }

        let dictionaryLog2 = selectedDictionaryLog2
        let threads = selectedThreadCount
        let passes = selectedPassCount
        let arguments = ["b", "-md=\(dictionaryLog2)", "-mmt=\(threads)", "\(passes)"]

        clearResults()
        stopRequested = false

        let token = OperationToken()
        self.token = token

        setRunning(true)
        systemLabel.stringValue = commandDescription(
            arguments: arguments,
            dictionaryLog2: dictionaryLog2,
            threads: threads,
            passes: passes
        )
        statusLabel.stringValue = L("Running…")
        runStart = Date()
        startElapsedTimer()

        runTask = Task { [weak self] in
            do {
                let output = try await SevenZipWrapper.runProcess(
                    arguments: arguments,
                    password: nil,
                    token: token,
                    progressHandler: nil
                )
                await MainActor.run { [weak self] in
                    self?.runDidFinish(output: output, error: nil, arguments: arguments)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.runDidFinish(output: nil, error: error, arguments: arguments)
                }
            }
        }
    }

    @objc private func stopBenchmark(_ sender: Any?) {
        guard runTask != nil else { return }
        stopRequested = true
        statusLabel.stringValue = L("Stopping…")
        stopButton.isEnabled = false
        token?.cancel()
    }

    @objc private func copyReport(_ sender: Any?) {
        let text = resultsTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.close()
    }

    // MARK: - Run lifecycle

    private func runDidFinish(output: String?, error: Error?, arguments: [String]) {
        // Freeze the duration once so the label and the status text cannot disagree.
        let elapsed = BenchmarkWindowController.formatElapsed(elapsedSeconds)
        runTask = nil
        token = nil
        runStart = nil
        stopElapsedTimer()
        elapsedLabel.stringValue = L("Elapsed %@", "\(elapsed)")
        setRunning(false)

        if let output = output {
            let report = BenchmarkParser.parse(output)
            apply(report, arguments: arguments)
            statusLabel.stringValue = report.total == nil
                ? L("Finished, but the report could not be parsed — raw output shown.")
                : L("Finished in %@.", elapsed)
            return
        }

        let cancelled = stopRequested || isCancellation(error)
        stopRequested = false

        if cancelled {
            statusLabel.stringValue = L("Stopped.")
            setResultsText("")
            return
        }

        guard let error = error else {
            statusLabel.stringValue = L("Finished with no output.")
            return
        }

        statusLabel.stringValue = L("Failed.")
        setResultsText(error.localizedDescription)
        showFailureAlert(error)
    }

    private func apply(_ report: BenchmarkReport, arguments: [String]) {
        if let total = report.total {
            ratingLabel.stringValue = "\(BenchmarkWindowController.formatNumber(total.rating)) MIPS"
            ratingDetailLabel.stringValue =
                L("usage %@%%  ·  R/U %@ MIPS", "\(total.usage)", "\(BenchmarkWindowController.formatNumber(total.ratingPerUsage))")
        } else {
            ratingLabel.stringValue = "—"
            ratingDetailLabel.stringValue = ""
        }

        cpuLabel.stringValue = BenchmarkWindowController.cpuDescription
        systemLabel.stringValue = systemDescription(for: report, arguments: arguments)
        setResultsText(reportText(for: report))
    }

    private func clearResults() {
        setResultsText("")
        ratingLabel.stringValue = "—"
        ratingDetailLabel.stringValue = ""
        cpuLabel.stringValue = BenchmarkWindowController.cpuDescription
    }

    private func setResultsText(_ text: String) {
        resultsTextView.string = text
        resultsTextView.scroll(NSPoint.zero)
        // Enablement depends on the text, so it must be refreshed after every change,
        // not only from setRunning(_:).
        copyButton.isEnabled = runTask == nil && !text.isEmpty
    }

    private func setRunning(_ running: Bool) {
        startButton.isEnabled = !running
        stopButton.isEnabled = running
        dictionaryPopUp.isEnabled = !running
        threadsPopUp.isEnabled = !running
        passesPopUp.isEnabled = !running
        copyButton.isEnabled = !running && !resultsTextView.string.isEmpty

        progressIndicator.isHidden = !running
        if running {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func isCancellation(_ error: Error?) -> Bool {
        guard let sevenZipError = error as? SevenZipError else { return false }
        if case .cancelled = sevenZipError { return true }
        return false
    }

    private func showFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("Benchmark failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        if let window = window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Elapsed time

    private var elapsedSeconds: TimeInterval {
        guard let runStart = runStart else { return 0 }
        return Date().timeIntervalSince(runStart)
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        updateElapsedLabel()
        // Added to .common so the readout keeps ticking during menu tracking and live resize.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateElapsedLabel()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func updateElapsedLabel() {
        elapsedLabel.stringValue = L("Elapsed %@", "\(BenchmarkWindowController.formatElapsed(elapsedSeconds))")
    }

    // MARK: - Text

    private func commandDescription(
        arguments: [String],
        dictionaryLog2: Int,
        threads: Int,
        passes: Int
    ) -> String {
        let dictionary = BenchmarkReport.dictionaryLabel(log2Size: dictionaryLog2)
        return "7zz \(arguments.joined(separator: " "))  ·  "
            + L("dictionary %@, threads: %d, passes: %d", dictionary, threads, passes)
    }

    private func systemDescription(for report: BenchmarkReport, arguments: [String]) -> String {
        var parts: [String] = []
        if let version = report.version { parts.append(version) }
        if let cpu = report.cpuDescription { parts.append(cpu) }
        if let ram = report.ramSizeMB { parts.append(L("RAM %d MB", ram)) }
        if let usage = report.ramUsageMB { parts.append(L("used %d MB", usage)) }
        if let threads = report.benchmarkThreads { parts.append(L("benchmark threads: %d", threads)) }
        if parts.isEmpty { parts.append("7zz \(arguments.joined(separator: " "))") }
        return parts.joined(separator: "  ·  ")
    }

    private func reportText(for report: BenchmarkReport) -> String {
        var lines: [String] = []
        if let version = report.version { lines.append(version) }
        lines.append(L("CPU: %@", BenchmarkWindowController.cpuDescription))
        if let cpu = report.cpuDescription { lines.append(L("7-Zip CPU line: %@", cpu)) }

        var system: [String] = []
        if let ram = report.ramSizeMB { system.append(L("RAM size: %d MB", ram)) }
        if let threads = report.hardwareThreads { system.append(L("CPU hardware threads: %d", threads)) }
        if let usage = report.ramUsageMB { system.append(L("RAM usage: %d MB", usage)) }
        if let threads = report.benchmarkThreads { system.append(L("benchmark threads: %d", threads)) }
        if !system.isEmpty { lines.append(system.joined(separator: ", ")) }

        if report.passCount > 1 { lines.append(L("Passes: %d", report.passCount)) }
        lines.append("")

        let table = report.renderedTable()
        // Fall back to whatever 7zz printed if the layout ever changes under us.
        lines.append(table.isEmpty ? report.rawOutput : table)
        return lines.joined(separator: "\n")
    }

    // MARK: - System info

    /// CPU model from `machdep.cpu.brand_string`, falling back to ProcessInfo core counts.
    static var cpuDescription: String {
        let total = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount
        let cores = active == total ? L("cores: %d", total) : L("active cores: %d of %d", active, total)
        if let brand = cpuBrandString() { return "\(brand) — \(cores)" }
        return "\(cores)"
    }

    private static func cpuBrandString() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }
        let brand = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return brand.isEmpty ? nil : brand
    }

    private static func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if runTask != nil {
            stopRequested = true
            token?.cancel()
        }
        runTask?.cancel()
        runTask = nil
        token = nil
        stopElapsedTimer()
        if BenchmarkWindowController.presentedController === self {
            BenchmarkWindowController.presentedController = nil
        }
    }
}
