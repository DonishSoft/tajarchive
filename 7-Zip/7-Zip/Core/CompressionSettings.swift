import Foundation

// MARK: - Option enums

/// How stored paths are derived from the source files.
enum PathMode: String, CaseIterable, Codable {
    case relative   // default: names relative to the working directory
    case full       // -spf: full paths without the drive/root prefix
    case absolute   // -spf2: absolute paths

    var displayName: String {
        switch self {
        case .relative: return L("Relative pathnames")
        case .full: return L("Full pathnames")
        case .absolute: return L("Absolute pathnames")
        }
    }

    var flag: String? {
        switch self {
        case .relative: return nil
        case .full: return "-spf"
        case .absolute: return "-spf2"
        }
    }
}

/// What happens to files that already exist in the target archive.
enum UpdateMode: String, CaseIterable, Codable {
    case addAndReplace  // a
    case updateAndAdd   // u
    case freshen        // u -ur0 (only refresh files already inside)
    case synchronize    // u with delete of vanished files

    var displayName: String {
        switch self {
        case .addAndReplace: return L("Add and replace files")
        case .updateAndAdd: return L("Update and add files")
        case .freshen: return L("Freshen existing files")
        case .synchronize: return L("Synchronize files")
        }
    }

    /// 7zz command letter
    var command: String {
        switch self {
        case .addAndReplace: return "a"
        default: return "u"
        }
    }

    /// -u switch describing how to treat new/old/deleted items.
    /// State chars: p = files only in archive, q = files only on disk, r = newer, x = older, etc.
    var updateSwitch: String? {
        switch self {
        case .addAndReplace: return nil
        case .updateAndAdd: return nil            // plain `u` already means update+add
        case .freshen: return "-uq0"              // do not add files missing from the archive
        case .synchronize: return "-up0q3r2x2y2z1w2" // drop archive-only entries, add/refresh the rest
        }
    }
}

/// Encryption algorithm for the archive payload.
enum EncryptionMethod: String, CaseIterable, Codable {
    case aes256 = "AES256"
    case zipCrypto = "ZipCrypto"

    var displayName: String {
        switch self {
        case .aes256: return "AES-256"
        case .zipCrypto: return L("ZipCrypto (legacy, weak)")
        }
    }
}

// MARK: - Method capabilities

extension CompressionMethod {

    /// Dictionary / memory sizes offered for this method, as (label, 7zz value).
    var dictionarySizes: [(label: String, value: String)] {
        let values: [String]
        switch self {
        case .lzma2, .lzma:
            values = ["64k", "1m", "2m", "4m", "6m", "8m", "12m", "16m", "24m", "32m", "48m", "64m",
                      "96m", "128m", "192m", "256m", "384m", "512m", "768m", "1024m", "1536m"]
        case .ppmd:
            values = ["1m", "2m", "4m", "8m", "16m", "32m", "64m", "128m", "192m", "256m", "512m", "1024m"]
        case .bzip2:
            values = ["100k", "200k", "300k", "400k", "500k", "600k", "700k", "800k", "900k"]
        case .deflate, .deflate64:
            values = ["32k"]
        case .tajAuto:
            values = []
        }
        return values.map { (CompressionMethod.sizeLabel($0), $0) }
    }

    /// Deflate's window is fixed at 32 KB (64 KB for Deflate64): 7zz rejects any `-md`
    /// for them with E_INVALIDARG, so the size is shown but never passed.
    var hasConfigurableDictionary: Bool {
        switch self {
        case .deflate, .deflate64, .tajAuto: return false
        case .lzma2, .lzma, .ppmd, .bzip2: return true
        }
    }

    /// "64k" → "64 KB", "16m" → "16 MB", "4g" → "4 GB", with the unit in the interface language.
    static func sizeLabel(_ value: String) -> String {
        guard let unit = value.last, let number = Int(value.dropLast()) else { return value }
        switch unit {
        case "k": return L("%d KB", number)
        case "m": return L("%d MB", number)
        case "g": return L("%d GB", number)
        default: return value
        }
    }

    /// Word size (fast bytes for LZMA, model order for PPMd) choices.
    var wordSizes: [Int] {
        switch self {
        case .lzma2, .lzma: return [8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 273]
        case .ppmd: return [2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32]
        case .deflate: return [8, 16, 32, 64, 128, 258]
        case .deflate64: return [8, 16, 32, 64, 128, 257]
        case .bzip2, .tajAuto: return []
        }
    }

    /// Label used for the word-size row (PPMd calls it "model order").
    var wordSizeLabel: String {
        self == .ppmd ? L("Model order:") : L("Word size:")
    }

    /// Default dictionary value for a compression level.
    func defaultDictionary(for level: CompressionLevel) -> String? {
        switch self {
        case .lzma2, .lzma:
            switch level {
            case .store: return nil
            case .fastest: return "64k"
            case .fast: return "1m"
            case .normal: return "16m"
            case .maximum: return "32m"
            case .ultra: return "64m"
            }
        case .ppmd:
            switch level {
            case .store: return nil
            case .fastest, .fast: return "4m"
            case .normal: return "16m"
            case .maximum: return "64m"
            case .ultra: return "192m"
            }
        case .bzip2:
            return level == .fastest ? "100k" : "900k"
        case .deflate, .deflate64:
            return "32k"
        case .tajAuto:
            return nil
        }
    }

    func defaultWordSize(for level: CompressionLevel) -> Int? {
        switch self {
        case .lzma2, .lzma:
            switch level {
            case .store: return nil
            case .fastest, .fast: return 32
            case .normal: return 32
            case .maximum: return 64
            case .ultra: return 64
            }
        case .ppmd:
            return level == .ultra ? 32 : 6
        case .deflate, .deflate64:
            return level == .ultra ? 258 : 32
        case .bzip2, .tajAuto:
            return nil
        }
    }

    var supportsMultithreading: Bool {
        switch self {
        case .lzma2, .bzip2: return true
        case .lzma: return true // bt4 match finder uses 2 threads
        case .ppmd, .deflate, .deflate64, .tajAuto: return false
        }
    }
}

extension ArchiveFormat {
    /// Methods 7zz can use inside this container.
    var availableMethods: [CompressionMethod] {
        switch self {
        case .taj: return [.tajAuto]
        case .sevenZip: return [.lzma2, .lzma, .ppmd, .bzip2]
        case .zip: return [.deflate, .deflate64, .bzip2, .lzma, .ppmd]
        case .tar, .gzip, .bzip2, .xz: return []
        }
    }

    var supportsSolidBlocks: Bool { self == .sevenZip }
    var supportsEncryption: Bool { self == .sevenZip || self == .zip || self == .taj }
    var supportsHeaderEncryption: Bool { self == .sevenZip }
    var supportsSFX: Bool { self == .sevenZip || self == .zip }
    var supportsVolumes: Bool { self != .taj }
    /// ZipCrypto exists only in the ZIP container; everything else is AES-256 only.
    var supportsZipCrypto: Bool { self == .zip }
}

// MARK: - Solid block choices

enum SolidBlockSize: String, CaseIterable, Codable {
    case nonSolid = "off"
    case size1m = "1m"
    case size4m = "4m"
    case size16m = "16m"
    case size64m = "64m"
    case size256m = "256m"
    case size1g = "1g"
    case size4g = "4g"
    case solid = "on"

    var displayName: String {
        switch self {
        case .nonSolid: return L("Non-solid")
        case .solid: return L("Solid (single block)")
        case .size1m, .size4m, .size16m, .size64m, .size256m, .size1g, .size4g:
            return CompressionMethod.sizeLabel(rawValue)
        }
    }
}

// MARK: - Settings

/// Everything the compress sheet can configure, persisted per archive format.
struct CompressionSettings: Codable {
    var level: CompressionLevel = .normal
    var methodRaw: String?
    var dictionary: String?
    var wordSize: Int?
    var solidBlock: SolidBlockSize = .size4g
    var threadCount: Int = 0            // 0 = auto (all cores)
    var pathMode: PathMode = .relative
    var updateMode: UpdateMode = .addAndReplace
    var createSFX: Bool = false
    var deleteAfter: Bool = false
    var storeSymlinks: Bool = true
    var encryptHeaders: Bool = false
    var encryptionMethod: EncryptionMethod = .aes256
    var volumeSize: String = ""
    var customParameters: String = ""

    var method: CompressionMethod? {
        get { methodRaw.flatMap { CompressionMethod(rawValue: $0) } }
        set { methodRaw = newValue?.rawValue }
    }

    // MARK: Persistence

    private static func defaultsKey(for format: ArchiveFormat) -> String {
        "CompressionSettings.\(format.rawValue)"
    }

    static func load(for format: ArchiveFormat) -> CompressionSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(for: format)),
              let decoded = try? JSONDecoder().decode(CompressionSettings.self, from: data) else {
            var fresh = CompressionSettings()
            fresh.method = format.availableMethods.first
            if let method = fresh.method {
                fresh.dictionary = method.defaultDictionary(for: fresh.level)
                fresh.wordSize = method.defaultWordSize(for: fresh.level)
            }
            return fresh
        }
        return decoded
    }

    func save(for format: ArchiveFormat) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(for: format))
    }
}

// MARK: - Level extension

extension CompressionLevel {
    /// Levels below Normal use the HC4 match finder; Normal and up use BT4.
    var usesBinaryTreeMatchFinder: Bool { rawValue >= 5 }
}

// MARK: - Memory estimation

/// Estimates RAM needed to compress and to decompress, mirroring what the
/// Windows Add-to-Archive dialog shows. Values are approximations of 7-Zip's own
/// formulas: LZMA needs roughly 11.5× the dictionary with BT4 (9.5× with HC4),
/// and decompression needs the dictionary itself plus a small fixed overhead.
enum MemoryEstimator {

    static func parseSize(_ value: String?) -> Int64? {
        guard let value = value?.lowercased(), !value.isEmpty else { return nil }
        let multiplier: Int64
        var numberPart = value
        if value.hasSuffix("k") { multiplier = 1024; numberPart = String(value.dropLast()) }
        else if value.hasSuffix("m") { multiplier = 1024 * 1024; numberPart = String(value.dropLast()) }
        else if value.hasSuffix("g") { multiplier = 1024 * 1024 * 1024; numberPart = String(value.dropLast()) }
        else { multiplier = 1 }
        guard let number = Int64(numberPart) else { return nil }
        return number * multiplier
    }

    /// Returns (compressBytes, decompressBytes).
    static func estimate(
        format: ArchiveFormat,
        method: CompressionMethod?,
        level: CompressionLevel,
        dictionary: String?,
        threads: Int
    ) -> (compress: Int64, decompress: Int64) {

        let hardwareThreads = ProcessInfo.processInfo.activeProcessorCount
        let effectiveThreads = threads > 0 ? threads : hardwareThreads

        if level == .store {
            return (2 * 1024 * 1024, 1024 * 1024)
        }

        switch method {
        case .lzma2, .lzma, .none:
            guard let dict = parseSize(dictionary) ?? parseSize(method?.defaultDictionary(for: level)) else {
                return (16 * 1024 * 1024, 8 * 1024 * 1024)
            }
            let multiplier = level.usesBinaryTreeMatchFinder ? 11.5 : 9.5
            let perBlock = Int64(Double(dict) * multiplier) + 6 * 1024 * 1024

            // LZMA2 splits input into blocks compressed in parallel; with BT4 each
            // block consumes 2 hardware threads.
            var parallelBlocks = 1
            if method == .lzma2 && effectiveThreads > 1 {
                parallelBlocks = level.usesBinaryTreeMatchFinder
                    ? max(1, effectiveThreads / 2)
                    : effectiveThreads
            }

            let compress = perBlock * Int64(parallelBlocks)
            // Multithreaded LZMA2 decoding keeps one dictionary per parallel block
            let decompressBlocks = method == .lzma2 ? min(parallelBlocks, 4) : 1
            let decompress = (dict + 2 * 1024 * 1024) * Int64(decompressBlocks)
            return (compress, decompress)

        case .ppmd:
            let mem = parseSize(dictionary) ?? parseSize(method?.defaultDictionary(for: level)) ?? (16 * 1024 * 1024)
            // PPMd is single-threaded per stream but 7z can run several streams
            let streams = format == .sevenZip ? min(effectiveThreads, 4) : 1
            return ((mem + 2 * 1024 * 1024) * Int64(streams), (mem + 2 * 1024 * 1024) * Int64(streams))

        case .bzip2:
            let blockSize = parseSize(dictionary) ?? 900 * 1024
            let perThreadCompress = Int64(Double(blockSize) * 9.0) + 1024 * 1024
            let perThreadDecompress = Int64(Double(blockSize) * 4.0) + 1024 * 1024
            let threadsUsed = Int64(max(1, effectiveThreads))
            return (perThreadCompress * threadsUsed, perThreadDecompress * threadsUsed)

        case .deflate, .deflate64:
            return (3 * 1024 * 1024, 1024 * 1024)

        case .tajAuto:
            // TAJ hashes and buffers blocks in memory, then hands a solid stream to LZMA2
            return (192 * 1024 * 1024, 128 * 1024 * 1024)
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

// MARK: - Self-extracting archives

/// Builds a macOS self-extracting archive: a shell script with the archive
/// payload appended after a marker line.
///
/// ZIP payloads extract with the system `unzip`, so the result runs on any Mac with
/// nothing installed. 7z payloads need a 7-Zip engine, so the stub looks for one in the
/// usual places (including this app) and explains the problem if none is found.
enum SFXBuilder {

    static let marker = "__TAJARCHIVE_PAYLOAD_BELOW__"

    static func makeSelfExtracting(archivePath: String, format: ArchiveFormat) throws -> String {
        let archiveURL = URL(fileURLWithPath: archivePath)
        let outputURL = archiveURL.deletingPathExtension().appendingPathExtension("sfx.command")

        let payload = try Data(contentsOf: archiveURL)
        let script = stub(archiveName: archiveURL.lastPathComponent, format: format)

        guard var output = script.data(using: .utf8) else {
            throw SevenZipError.commandFailed(L("Could not encode the self-extractor stub"))
        }
        output.append(payload)
        try output.write(to: outputURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
        return outputURL.path
    }

    private static func stub(archiveName: String, format: ArchiveFormat) -> String {
        let extractCommands: String
        if format == .zip {
            extractCommands = """
            if ! command -v unzip >/dev/null 2>&1; then
              echo "Error: unzip is not available on this system." >&2
              exit 1
            fi
            unzip -o "$PAYLOAD" -d "$DEST"
            """
        } else {
            extractCommands = """
            SEVENZZ=""
            for candidate in \\
                /Applications/TajArchive.app/Contents/Resources/7zz \\
                /opt/homebrew/bin/7zz \\
                /usr/local/bin/7zz \\
                "$(command -v 7zz 2>/dev/null)" \\
                "$(command -v 7z 2>/dev/null)"; do
              if [ -n "$candidate" ] && [ -x "$candidate" ]; then SEVENZZ="$candidate"; break; fi
            done
            if [ -z "$SEVENZZ" ]; then
              echo "Error: this archive needs a 7-Zip-compatible engine to unpack." >&2
              echo "Install TajArchive, or run: brew install sevenzip" >&2
              exit 1
            fi
            "$SEVENZZ" x -y -o"$DEST" -- "$PAYLOAD"
            """
        }

        return """
        #!/bin/bash
        # Self-extracting archive created by TajArchive (https://donishsoft.com/tajarchive).
        # Run it to unpack, or pass a destination folder as the first argument.
        set -e

        SELF="${BASH_SOURCE[0]}"
        cd "$(dirname "$SELF")"
        SELF_NAME="$(basename "$SELF")"

        DEST="${1:-$(pwd)/\(archiveName.replacingOccurrences(of: ".", with: "_"))}"
        PAYLOAD="$(mktemp -t tajsfx).\(format.extensionString)"
        trap 'rm -f "$PAYLOAD"' EXIT

        echo "Extracting \(archiveName) -> $DEST"
        mkdir -p "$DEST"

        PAYLOAD_LINE=$(awk '/^\(marker)$/ { print NR + 1; exit 0; }' "$SELF_NAME")
        tail -n "+$PAYLOAD_LINE" "$SELF_NAME" > "$PAYLOAD"

        \(extractCommands)

        echo "Done: $DEST"
        open "$DEST" 2>/dev/null || true
        exit 0
        \(marker)

        """
    }
}
