import Foundation
import os

/// Archive formats that the bundled 7zz engine cannot handle, implemented on top of
/// the command-line tools macOS already ships.
///
/// WHY THIS MODULE EXISTS
/// ---------------------
/// The bundled 7zz 25.01 can *write* only 7z, zip, tar, wim, xz, gzip and bzip2. It has
/// no zstd, lz4, brotli or lzip codec compiled in, so the whole modern-compression family
/// is simply unreachable through it. Rather than vendoring libzstd/liblz4 (a new binary
/// dependency to build, sign, notarize and keep patched), this module drives two tools
/// that are already part of every supported macOS install:
///
///   * `/usr/bin/tar` — Apple's bsdtar 3.5.3 on libarchive 3.7.4, which *does* carry
///     zstd and lz4 filters (`--zstd`, `--lz4`) for both reading and writing.
///   * `/usr/bin/aa`  — the Apple Archive tool, which reads and writes `.aar`/`.yaa`,
///     the native macOS container (and the format `ditto --arch`-style tooling emits).
///
/// The result is zero third-party code, nothing extra to ship, and formats that behave
/// identically to what the user gets from Terminal.
///
/// MEASURED PLATFORM BEHAVIOUR
/// ---------------------------
/// Everything below was verified against bsdtar 3.5.3 / libarchive 3.7.4 and the macOS
/// `aa` tool, because several plausible-sounding assumptions turn out to be false:
///
///   * `ZSTD_CLEVEL` is **ignored** by this libarchive — level 1 and level 19 produce
///     byte-identical output. The switch that actually works is
///     `--options zstd:compression-level=N` (measured 148338 / 111455 bytes for the same
///     input at levels 1 / 19). The env var is still exported as a harmless forward-
///     compatible hint, but `--options` is what does the work.
///   * lz4 accepts only levels 1–2. Level 3 and up fail with "High compression not
///     included in this build", so no level is passed for lz4 at all.
///   * bsdtar octal-escapes non-ASCII file names (`\321\204…`) unless it runs in a UTF-8
///     locale, so every listing runs with `LC_ALL`/`LANG` forced to `en_US.UTF-8`, and
///     the parser *still* un-escapes defensively.
///   * `aa list` takes `-i <archive>` (its `-a` flag selects a compression algorithm, not
///     the archive) and its `-v` only raises stderr verbosity. Structured output comes
///     from `-list-format json`, which is what this module parses.
///   * bsdtar can *write* a raw single-file stream (`--format raw`) but cannot *read* one
///     back — see `ExtendedFormat.isSingleFile` and `extract(at:to:token:progress:)`.
enum ExtendedFormat: String, CaseIterable {

    /// tar wrapped in a zstd stream — the general-purpose modern archive.
    case tarZstd = "tar.zst"
    /// tar wrapped in an lz4 stream — very fast, low ratio.
    case tarLz4 = "tar.lz4"
    /// A bare zstd stream holding exactly one file.
    case zstd = "zst"
    /// A bare lz4 stream holding exactly one file.
    case lz4 = "lz4"
    /// Apple Archive, the native macOS container.
    case appleArchive = "aar"

    var displayName: String {
        switch self {
        case .tarZstd: return "TAR + Zstandard"
        case .tarLz4: return "TAR + LZ4"
        case .zstd: return L("Zstandard (single file)")
        case .lz4: return L("LZ4 (single file)")
        case .appleArchive: return L("Apple Archive")
        }
    }

    /// Extension appended when the user has not typed one, without a leading dot.
    var fileExtension: String { rawValue }

    /// Raw zstd/lz4 streams carry exactly one file and no names or metadata;
    /// the tar variants and Apple Archive hold a whole tree.
    var isSingleFile: Bool {
        switch self {
        case .zstd, .lz4: return true
        case .tarZstd, .tarLz4, .appleArchive: return false
        }
    }

    /// True when the container itself stores file names (so a real listing is possible).
    var hasFileNames: Bool { !isSingleFile }

    /// Every spelling that maps to this format, longest first so that `.tar.zst`
    /// is matched before the `.zst` that it ends with.
    var recognisedSuffixes: [String] {
        switch self {
        case .tarZstd: return [".tar.zst", ".tar.zstd", ".tzst", ".tzstd"]
        case .tarLz4: return [".tar.lz4", ".tlz4"]
        case .zstd: return [".zst", ".zstd"]
        case .lz4: return [".lz4"]
        case .appleArchive: return [".aar", ".yaa", ".appledouble.aar"]
        }
    }

    /// Recognise a format from a file URL. Extension-based: these containers are
    /// identified by name here, exactly as 7zz's own format table does.
    static func detect(url: URL) -> ExtendedFormat? {
        detect(path: url.path)
    }

    /// Recognise a format from a path string.
    ///
    /// Matching is longest-suffix-first, so `archive.tar.zst` resolves to `.tarZstd`
    /// and never to the `.zstd` whose suffix it also ends with.
    static func detect(path: String) -> ExtendedFormat? {
        let name = (path as NSString).lastPathComponent.lowercased()
        var best: (format: ExtendedFormat, length: Int)?
        for format in ExtendedFormat.allCases {
            for suffix in format.recognisedSuffixes where name.hasSuffix(suffix) {
                if best == nil || suffix.count > best!.length {
                    best = (format, suffix.count)
                }
            }
        }
        return best?.format
    }

    /// For a single-file stream, the name the payload should get once unpacked:
    /// the archive name minus its compression suffix.
    func payloadName(forArchivePath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        // Short tar forms unpack to a .tar ("x.tlz4" → "x.tar")
        for short in [".tlz4", ".tzst", ".tzstd"] where lower.hasSuffix(short) {
            return String(name.dropLast(short.count)) + ".tar"
        }
        for suffix in recognisedSuffixes where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// Runs `/usr/bin/tar` and `/usr/bin/aa` with the same discipline `SevenZipWrapper`
/// applies to 7zz: arguments as an array (never a shell string), `--` or `-C` so that
/// names starting with `-` can never be read as switches, cancellation through
/// `OperationToken`, and async/await over a continuation rather than `waitUntilExit`.
enum ExtendedArchiver {

    // MARK: - Tool paths

    private static let tarPath = "/usr/bin/tar"
    private static let appleArchivePath = "/usr/bin/aa"

    /// A UTF-8 locale is mandatory for listings: in the C locale bsdtar renders every
    /// non-ASCII byte of a file name as a `\NNN` octal escape.
    private static var utf8Environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    // MARK: - Capability probes

    /// Cached results of the availability probes. Probing spawns a process, so each
    /// answer is computed once and reused; the UI calls these on every menu build.
    private static let probeCache = ProbeCache()

    /// True when `/usr/bin/aa` exists and answers. Lets the UI hide Apple Archive on a
    /// machine that somehow lacks the tool instead of failing at save time.
    static var isAppleArchiveAvailable: Bool {
        probeCache.value(for: "aa") {
            FileManager.default.isExecutableFile(atPath: appleArchivePath)
                && probeSucceeds(executable: appleArchivePath, arguments: ["list", "-i", "/dev/null"])
        }
    }

    /// True when this machine's bsdtar really has the zstd filter compiled in.
    /// The probe compresses an empty file list through the filter to `/dev/null`, which
    /// exercises the codec itself rather than just the argument parser.
    static var isZstdAvailable: Bool {
        probeCache.value(for: "zstd") {
            FileManager.default.isExecutableFile(atPath: tarPath)
                && probeSucceeds(executable: tarPath,
                                 arguments: ["--zstd", "-cf", "/dev/null", "-T", "/dev/null"])
        }
    }

    /// True when this machine's bsdtar really has the lz4 filter compiled in.
    static var isLz4Available: Bool {
        probeCache.value(for: "lz4") {
            FileManager.default.isExecutableFile(atPath: tarPath)
                && probeSucceeds(executable: tarPath,
                                 arguments: ["--lz4", "-cf", "/dev/null", "-T", "/dev/null"])
        }
    }

    /// Formats this machine can actually produce, for populating the format picker.
    static var availableFormats: [ExtendedFormat] {
        ExtendedFormat.allCases.filter { format in
            switch format {
            case .tarZstd, .zstd: return isZstdAvailable
            case .tarLz4, .lz4: return isLz4Available
            case .appleArchive: return isAppleArchiveAvailable
            }
        }
    }

    /// Thread-safe memo for the capability probes.
    private final class ProbeCache {
        private let lock = NSLock()
        private var values: [String: Bool] = [:]

        func value(for key: String, compute: () -> Bool) -> Bool {
            lock.lock()
            if let cached = values[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            let result = compute()
            lock.lock()
            values[key] = result
            lock.unlock()
            return result
        }
    }

    /// Synchronous, short-lived probe. Never used for real work — only to answer
    /// "does this tool exist and does this codec work here?".
    private static func probeSucceeds(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Dispatch

    /// Returns the extended format handling this path, or nil when 7zz should take it.
    ///
    /// A nil result is the signal to fall through to `SevenZipWrapper`; `.7z`, `.zip`
    /// and friends are deliberately not recognised here.
    ///
    /// macOS's tar has no zstd or lz4 code of its own — it runs a `zstd`/`lz4` program
    /// from Homebrew when one exists, and fails otherwise (always so in the sandboxed
    /// App Store build). Without those tools `.tar.zst` goes to 7zz, which reads it the
    /// way it reads `.tar.gz` (the inner `.tar` is opened as a nested archive), and
    /// `.tar.lz4` is decoded in-process like any `.lz4` stream.
    static func canHandle(path: String) -> ExtendedFormat? {
        guard let format = ExtendedFormat.detect(path: path) else { return nil }
        switch format {
        case .tarZstd: return isZstdAvailable ? .tarZstd : nil
        case .tarLz4: return isLz4Available ? .tarLz4 : .lz4
        default: return format
        }
    }

    // MARK: - Listing

    /// List an extended archive's contents.
    ///
    /// tar variants are listed with `-tvf` and the verbose output is parsed; Apple
    /// Archives are listed as JSON. A raw zstd/lz4 stream stores no directory at all,
    /// so one synthetic entry is returned with the payload's name and size 0 — the
    /// uncompressed size is genuinely unknowable without decompressing the whole stream.
    static func list(at path: String) async throws -> [ArchiveEntry] {
        guard let format = canHandle(path: path) else {
            throw SevenZipError.invalidArchive
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SevenZipError.archiveNotFound
        }

        switch format {
        case .tarZstd, .tarLz4:
            let output = try await runTool(
                executable: tarPath,
                arguments: [filterFlag(for: format), "-t", "-v", "-f", absolutePath(path)],
                environment: utf8Environment
            )
            return parseTarListing(output)

        case .appleArchive:
            let output = try await runTool(
                executable: appleArchivePath,
                arguments: ["list", "-i", absolutePath(path), "-list-format", "json"]
            )
            if let entries = parseAppleArchiveJSON(output) {
                return entries
            }
            // Older `aa` builds may not know -list-format; fall back to the plain
            // one-path-per-line listing, which carries no sizes or dates.
            let plain = try await runTool(
                executable: appleArchivePath,
                arguments: ["list", "-i", absolutePath(path)]
            )
            return parseAppleArchivePlain(plain)

        case .zstd, .lz4:
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return [ArchiveEntry(
                path: format.payloadName(forArchivePath: path),
                size: 0, // a raw stream does not record its uncompressed size
                compressedSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                modified: attributes?[.modificationDate] as? Date,
                isDirectory: false,
                crc: nil,
                encrypted: false
            )]
        }
    }

    // MARK: - Extraction

    /// Extract an extended archive into `destination`.
    ///
    /// Raw single-file `.zst` / `.lz4` streams cannot be read by bsdtar (it only writes
    /// them via `--format raw`), so `.zst` goes through the bundled 7zz, which has a zstd
    /// decoder, and `.lz4` through the in-process `LZ4FrameDecoder`. Neither needs any
    /// tool the user would have to install.
    static func extract(
        at path: String,
        to destination: String,
        token: OperationToken? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) async throws {
        guard let format = canHandle(path: path) else {
            throw SevenZipError.invalidArchive
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw SevenZipError.archiveNotFound
        }

        try FileManager.default.createDirectory(
            atPath: destination, withIntermediateDirectories: true, attributes: nil
        )

        switch format {
        case .tarZstd, .tarLz4:
            // Knowing the entry count up front turns the name stream into a real
            // percentage. The count costs one extra decompression pass, so it is only
            // taken for archives small enough that the second read is cheap.
            var total = 0
            if progress != nil, compressedSize(of: path) <= progressPrescanLimit {
                total = (try? await list(at: path))?.count ?? 0
            }

            var seen = 0
            _ = try await runTool(
                executable: tarPath,
                arguments: [filterFlag(for: format), "-x", "-v",
                            "-f", absolutePath(path), "-C", absolutePath(destination)],
                environment: utf8Environment,
                token: token,
                onLine: progress.map { handler in
                    { line in
                        let name = unescapeTarName(line.trimmingCharacters(in: .whitespaces))
                        guard !name.isEmpty else { return }
                        seen += 1
                        report(handler, processed: seen, total: total, name: name)
                    }
                }
            )

        case .appleArchive:
            // `aa list` reads metadata only, so pre-counting here is genuinely cheap.
            var total = 0
            if progress != nil { total = (try? await list(at: path))?.count ?? 0 }

            var seen = 0
            _ = try await runTool(
                executable: appleArchivePath,
                arguments: ["extract", "-i", absolutePath(path),
                            "-d", absolutePath(destination), "-v"],
                token: token,
                onLine: progress.map { handler in
                    { line in
                        let name = line.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        seen += 1
                        report(handler, processed: seen, total: total, name: name)
                    }
                }
            )

        case .zstd:
            // The bundled 7zz decodes zstd frames, so no extra tool is needed. It names
            // the output after the archive, which is not always what `payloadName`
            // picks (".zstd" files), so it unpacks into a private folder first.
            let outputPath = (destination as NSString)
                .appendingPathComponent(format.payloadName(forArchivePath: path))
            let staging = (destination as NSString)
                .appendingPathComponent(".tajarchive-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: staging) }

            progress?(0, (outputPath as NSString).lastPathComponent)
            try await SevenZipWrapper.runProcess(
                arguments: ["e", "-y", "-o\(staging)", "-bsp1", "--", absolutePath(path)],
                password: nil, token: token
            ) { percent, _ in progress?(percent, (outputPath as NSString).lastPathComponent) }

            let produced = try FileManager.default.contentsOfDirectory(atPath: staging)
            guard let first = produced.first else { throw SevenZipError.invalidArchive }
            if FileManager.default.fileExists(atPath: outputPath) {
                try FileManager.default.removeItem(atPath: outputPath)
            }
            try FileManager.default.moveItem(
                atPath: (staging as NSString).appendingPathComponent(first), toPath: outputPath)
            progress?(100, (outputPath as NSString).lastPathComponent)

        case .lz4:
            // Nothing in macOS reads a bare LZ4 frame (bsdtar only writes them), so the
            // frame is decoded in-process — see `LZ4FrameDecoder`.
            let outputPath = (destination as NSString)
                .appendingPathComponent(format.payloadName(forArchivePath: path))
            let name = (outputPath as NSString).lastPathComponent
            progress?(0, name)
            try await Task.detached(priority: .userInitiated) {
                try LZ4FrameDecoder.decompress(
                    from: URL(fileURLWithPath: path),
                    to: URL(fileURLWithPath: outputPath),
                    isCancelled: { token?.isCancelled ?? false },
                    progress: { fraction in progress?(fraction * 100, name) }
                )
            }.value
            progress?(100, name)
        }
    }

    // MARK: - Creation

    /// Create an extended archive from `sourcePaths`.
    ///
    /// `level` follows the app's 0–9 `CompressionLevel` scale and is mapped onto whatever
    /// the target tool actually understands (see `zstdLevel` and `appleArchiveAlgorithm`).
    ///
    /// Path safety: names are never concatenated into a shell string. When every source
    /// shares one parent, tar is given `-C <parent> --` followed by bare names, so a file
    /// called `-rf` is a name and not a switch. When sources span several directories,
    /// repeated `-C <dir> ./<name>` pairs are used instead — `--` cannot be repeated,
    /// but a `./` prefix is equally unambiguous.
    static func create(
        at destination: String,
        from sourcePaths: [String],
        format: ExtendedFormat,
        level: Int = 5,
        workingDirectory: URL? = nil,
        token: OperationToken? = nil,
        progress: ((Double, String) -> Void)? = nil
    ) async throws {
        guard !sourcePaths.isEmpty else {
            throw SevenZipError.commandFailed(L("Nothing selected to compress."))
        }

        switch format {
        case .zstd, .lz4:
            try await createRawStream(
                at: destination, from: sourcePaths, format: format,
                level: level, token: token, progress: progress
            )
        case .tarZstd, .tarLz4:
            try await createTar(
                at: destination, from: sourcePaths, format: format,
                level: level, workingDirectory: workingDirectory,
                token: token, progress: progress
            )
        case .appleArchive:
            try await createAppleArchive(
                at: destination, from: sourcePaths, level: level,
                workingDirectory: workingDirectory, token: token, progress: progress
            )
        }
    }

    private static func createTar(
        at destination: String,
        from sourcePaths: [String],
        format: ExtendedFormat,
        level: Int,
        workingDirectory: URL?,
        token: OperationToken?,
        progress: ((Double, String) -> Void)?
    ) async throws {
        var args = [filterFlag(for: format)]
        args.append(contentsOf: levelOptions(for: format, level: level))
        args.append(contentsOf: ["-c", "-v", "-f", absolutePath(destination)])

        // Prefer one common parent: it yields clean stored names and lets `--` guard
        // every positional at once.
        let explicitParent = workingDirectory?.path
        if let parent = explicitParent ?? commonParent(of: sourcePaths) {
            args.append(contentsOf: ["-C", absolutePath(parent), "--"])
            args.append(contentsOf: sourcePaths.map { ($0 as NSString).lastPathComponent })
        } else {
            // Mixed parents: repeat -C per item. `--` must NOT be used here because it
            // would swallow the following -C as a literal file name.
            for source in sourcePaths {
                let parent = (source as NSString).deletingLastPathComponent
                let name = (source as NSString).lastPathComponent
                args.append(contentsOf: ["-C", absolutePath(parent), "./" + name])
            }
        }

        let total = countFiles(in: sourcePaths)
        var seen = 0
        _ = try await runTool(
            executable: tarPath,
            arguments: args,
            environment: utf8Environment,
            token: token,
            onLine: progress.map { handler in
                { line in
                    let name = unescapeTarName(line.trimmingCharacters(in: .whitespaces))
                    guard !name.isEmpty else { return }
                    seen += 1
                    report(handler, processed: seen, total: total, name: name)
                }
            }
        )
    }

    /// A raw stream holds exactly one file, so anything else is rejected up front —
    /// the same contract `SevenZipWrapper` enforces for GZip/BZip2/XZ.
    private static func createRawStream(
        at destination: String,
        from sourcePaths: [String],
        format: ExtendedFormat,
        level: Int,
        token: OperationToken?,
        progress: ((Double, String) -> Void)?
    ) async throws {
        guard sourcePaths.count == 1, let source = sourcePaths.first else {
            throw SevenZipError.commandFailed(
                L("The %@ format holds a single file only. Use TAR + Zstandard, TAR + LZ4, ZIP or 7z for several files or folders.", format.displayName)
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) else {
            throw SevenZipError.archiveNotFound
        }
        if isDirectory.boolValue {
            throw SevenZipError.commandFailed(
                L("The %@ format cannot hold a folder. Use TAR + Zstandard or TAR + LZ4 instead.", format.displayName)
            )
        }

        let parent = (source as NSString).deletingLastPathComponent
        let name = (source as NSString).lastPathComponent

        var args = [filterFlag(for: format)]
        args.append(contentsOf: levelOptions(for: format, level: level))
        // `--format raw` emits the compressed bytes with no tar wrapper at all.
        args.append(contentsOf: ["--format", "raw", "-c", "-f", absolutePath(destination),
                                 "-C", absolutePath(parent), "--", name])

        progress?(0, name)
        _ = try await runTool(
            executable: tarPath, arguments: args,
            environment: utf8Environment, token: token
        )
        progress?(100, name)
    }

    /// Apple Archive packs the *contents* of one directory, so a multi-item selection is
    /// staged into a temporary directory first (hard links where possible, so nothing is
    /// actually copied on the same volume). This mirrors how `SevenZipWrapper.updateArchive`
    /// stages files for its "add to folder" case.
    ///
    /// The obvious alternative — `aa archive -include-path <name>` — is deliberately not
    /// used: its prefix match is byte-exact, so a name the app holds in NFC silently fails
    /// to match the NFD form APFS stores, and the file is dropped from the archive without
    /// any error. Staging sidesteps Unicode normalisation entirely.
    private static func createAppleArchive(
        at destination: String,
        from sourcePaths: [String],
        level: Int,
        workingDirectory: URL?,
        token: OperationToken?,
        progress: ((Double, String) -> Void)?
    ) async throws {
        let fileManager = FileManager.default
        var stagingURL: URL?
        defer { if let staging = stagingURL { try? fileManager.removeItem(at: staging) } }

        var args = ["archive"]
        args.append(contentsOf: ["-a", appleArchiveAlgorithm(for: level)])

        if sourcePaths.count == 1, let only = sourcePaths.first {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: only, isDirectory: &isDirectory) else {
                throw SevenZipError.archiveNotFound
            }
            if isDirectory.boolValue {
                // Archive this directory's contents directly — no staging needed.
                args.append(contentsOf: ["-d", absolutePath(only)])
            } else {
                // A lone file: -d parent -i name stores exactly that one entry.
                args.append(contentsOf: [
                    "-d", absolutePath((only as NSString).deletingLastPathComponent),
                    "-i", (only as NSString).lastPathComponent
                ])
            }
        } else {
            let staging = fileManager.temporaryDirectory
                .appendingPathComponent("tajarchive-aar-" + UUID().uuidString)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            stagingURL = staging
            for source in sourcePaths {
                let target = staging.appendingPathComponent((source as NSString).lastPathComponent)
                let sourceURL = URL(fileURLWithPath: source)
                // Hard-linking keeps staging free on the same volume; copy is the fallback
                // for cross-volume selections and directories.
                if (try? fileManager.linkItem(at: sourceURL, to: target)) == nil {
                    try fileManager.copyItem(at: sourceURL, to: target)
                }
            }
            args.append(contentsOf: ["-d", staging.path])
        }

        args.append(contentsOf: ["-o", absolutePath(destination), "-v"])

        let total = countFiles(in: sourcePaths)
        var seen = 0
        _ = try await runTool(
            executable: appleArchivePath,
            arguments: args,
            token: token,
            onLine: progress.map { handler in
                { line in
                    let name = line.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    seen += 1
                    report(handler, processed: seen, total: total, name: name)
                }
            }
        )
    }

    // MARK: - Tool arguments

    private static func filterFlag(for format: ExtendedFormat) -> String {
        switch format {
        case .tarZstd, .zstd: return "--zstd"
        case .tarLz4, .lz4: return "--lz4"
        case .appleArchive: return ""
        }
    }

    /// Compression-level switches for bsdtar.
    ///
    /// zstd is driven by `--options zstd:compression-level=N` (1…22) because this
    /// libarchive ignores `ZSTD_CLEVEL`. lz4 gets no level at all: bsdtar's lz4 filter
    /// is built without LZ4_HC, so anything above 2 fails outright with
    /// "High compression not included in this build", and 1–2 are indistinguishable
    /// in practice — not worth risking a hard failure over.
    private static func levelOptions(for format: ExtendedFormat, level: Int) -> [String] {
        switch format {
        case .tarZstd, .zstd:
            return ["--options", "zstd:compression-level=\(zstdLevel(for: level))"]
        case .tarLz4, .lz4, .appleArchive:
            return []
        }
    }

    /// Maps the app's 0–9 `CompressionLevel` scale onto zstd's 1–22 scale.
    private static func zstdLevel(for level: Int) -> Int {
        switch level {
        case ..<1: return 1        // Store — zstd has no true store mode
        case 1: return 1           // Fastest
        case 2...3: return 3       // Fast (also zstd's own default)
        case 4...5: return 7       // Normal
        case 6...7: return 12      // Maximum
        default: return 19         // Ultra — 22 needs far more memory for little gain
        }
    }

    /// Apple Archive has no numeric level, only a codec choice, so the level maps onto
    /// the codec that matches the user's speed/ratio intent.
    private static func appleArchiveAlgorithm(for level: Int) -> String {
        switch level {
        case ..<1: return "raw"    // Store — genuinely no compression
        case 1...3: return "lz4"   // Fastest
        case 4...6: return "lzfse" // Normal — Apple's balanced default
        default: return "lzma"     // Maximum / Ultra
        }
    }

    // MARK: - Path helpers

    /// Absolute, standardised path. Absolute paths always begin with "/", which is what
    /// makes them safe to hand to `aa`, whose CLI has no `--` end-of-options marker.
    private static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// The single parent shared by every source, or nil when they are spread around.
    private static func commonParent(of paths: [String]) -> String? {
        let parents = Set(paths.map { absolutePath(($0 as NSString).deletingLastPathComponent) })
        return parents.count == 1 ? parents.first : nil
    }

    /// Archives above this size skip the extra listing pass used to turn the name
    /// stream into a percentage — decompressing twice is not worth a smoother bar.
    private static let progressPrescanLimit: Int64 = 64 * 1024 * 1024

    private static func compressedSize(of path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Number of filesystem items under `paths`, used as the denominator for progress.
    private static func countFiles(in paths: [String]) -> Int {
        let fileManager = FileManager.default
        var count = 0
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            count += 1
            if isDirectory.boolValue,
               let enumerator = fileManager.enumerator(atPath: path) {
                while enumerator.nextObject() != nil { count += 1 }
            }
        }
        return count
    }

    /// Emits a progress update. Percentages stay below 100 until the process actually
    /// exits, and a zero/unknown total reports 0 so the UI can show an indeterminate bar
    /// rather than a bar that lies.
    private static func report(
        _ handler: @escaping (Double, String) -> Void,
        processed: Int, total: Int, name: String
    ) {
        let percent: Double = total > 0
            ? min(99.0, Double(processed) / Double(total) * 100.0)
            : 0
        DispatchQueue.main.async { handler(percent, name) }
    }

    // MARK: - Process runner

    /// Runs a system tool and returns its stdout.
    ///
    /// Mirrors `SevenZipWrapper.runProcess`: arguments as an array, cancellation through
    /// `OperationToken`, and a continuation resumed only once the process has exited *and*
    /// both pipes have hit EOF. `onLine` receives complete lines from stdout and stderr
    /// as they arrive — bsdtar and `aa` both write verbose file names to stderr, so both
    /// streams feed the progress handler.
    @discardableResult
    private static func runTool(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        token: OperationToken? = nil,
        onLine: ((String) -> Void)? = nil
    ) async throws -> String {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // An empty element would be passed through as an empty argument, which bsdtar
        // reads as an empty file name.
        process.arguments = arguments.filter { !$0.isEmpty }
        if let environment = environment { process.environment = environment }
        if let currentDirectory = currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // None of these tools should ever prompt; EOF on stdin guarantees they cannot hang.
        process.standardInput = FileHandle.nullDevice

        AppLogger.shared.log(
            message: "▶️ \((executable as NSString).lastPathComponent) "
                   + "\(process.arguments?.joined(separator: " ") ?? "")"
        )

        let runState = RunState()
        let collector = PipeCollector()
        let wantsLines = onLine != nil

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                runState.markOutEOF()
            } else {
                for line in collector.append(data, isError: false, splitLines: wantsLines) { onLine?(line) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                runState.markErrEOF()
            } else {
                for line in collector.append(data, isError: true, splitLines: wantsLines) { onLine?(line) }
            }
        }
        process.terminationHandler = { _ in runState.markExited() }

        // A token that was already cancelled must not reach `attach`: terminating a
        // Process that has never been launched raises an Objective-C exception, which
        // no Swift `catch` can intercept. Bail out before anything is spawned.
        if token?.isCancelled == true { throw SevenZipError.cancelled }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runState.setContinuation(continuation)
            do {
                try process.run()
                // Attach only once the process really exists. `attach` re-checks the
                // cancelled flag under its own lock, so a cancel arriving in this window
                // still terminates the process rather than being lost.
                token?.attach(process)
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                runState.failEarly(error)
            }
        }

        let stdoutData = collector.stdout
        let output = String(decoding: stdoutData, as: UTF8.self)
        let errorOutput = String(decoding: collector.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if token?.isCancelled == true { throw SevenZipError.cancelled }

        if process.terminationStatus == 0 {
            AppLogger.shared.log(
                message: "✅ \((executable as NSString).lastPathComponent) finished "
                       + "[\(stdoutData.count) bytes output]"
            )
            return output
        }

        AppLogger.shared.log(
            message: "❌ \((executable as NSString).lastPathComponent) failed "
                   + "(status \(process.terminationStatus)): \(errorOutput)",
            level: .error
        )
        throw SevenZipError.commandFailed(
            errorOutput.isEmpty
                ? L("%@ stopped with error code %d.", (executable as NSString).lastPathComponent, Int(process.terminationStatus))
                : errorOutput
        )
    }

    /// Lock-protected completion state: resumes the continuation exactly once, after the
    /// process exited AND both pipes reached EOF. Same shape as `SevenZipWrapper.RunState`.
    private final class RunState {
        private let lock = NSLock()
        private var exited = false
        private var outEOF = false
        private var errEOF = false
        private var continuation: CheckedContinuation<Void, Error>?
        private var earlyError: Error?

        func setContinuation(_ c: CheckedContinuation<Void, Error>) {
            lock.lock()
            continuation = c
            if let err = earlyError {
                continuation = nil
                lock.unlock()
                c.resume(throwing: err)
                return
            }
            let done = exited && outEOF && errEOF
            if done { continuation = nil }
            lock.unlock()
            if done { c.resume() }
        }

        func failEarly(_ error: Error) {
            lock.lock()
            if let c = continuation {
                continuation = nil
                lock.unlock()
                c.resume(throwing: error)
            } else {
                earlyError = error
                lock.unlock()
            }
        }

        func markExited() { advance { self.exited = true } }
        func markOutEOF() { advance { self.outEOF = true } }
        func markErrEOF() { advance { self.errEOF = true } }

        private func advance(_ mutate: () -> Void) {
            lock.lock()
            mutate()
            guard exited && outEOF && errEOF, let c = continuation else {
                lock.unlock()
                return
            }
            continuation = nil
            lock.unlock()
            c.resume()
        }
    }

    // MARK: - Listing parsers

    /// Matches one `tar -tvf` row:
    ///   `drwxr-xr-x  0 owner group     0 Aug 15 14:57 folder/`
    ///   `-rw-r--r--  0 owner group    15 Jan 15  2020 file.txt`
    /// Captures: type char, mode, owner, group, size, date, name.
    private static let tarListingRegex = try? NSRegularExpression(
        pattern: #"^([dlbcps\-])([rwxSsTt\-]{9})[\.\+@]?\s+\d+\s+(\S+)\s+(\S+)\s+(\d+)\s+(\w{3}\s+\d+\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$"#
    )

    static func parseTarListing(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        guard let regex = tarListingRegex else { return entries }

        output.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, options: [], range: range),
                  match.numberOfRanges == 8 else { return }

            func capture(_ index: Int) -> String {
                guard let r = Range(match.range(at: index), in: line) else { return "" }
                return String(line[r])
            }

            let typeChar = capture(1)
            let size = Int64(capture(5)) ?? 0
            let dateText = capture(6)
            var name = capture(7)

            // A symlink row reads "link -> target"; keep only the entry's own name.
            if typeChar == "l", let arrow = name.range(of: " -> ") {
                name = String(name[..<arrow.lowerBound])
            }

            name = unescapeTarName(name)
            // Directories carry a trailing slash; "./" prefixes are an artefact of how
            // the archive was created and mean nothing to the user.
            let isDirectory = (typeChar == "d") || name.hasSuffix("/")
            name = normalisedEntryPath(name)
            guard !name.isEmpty else { return }

            entries.append(ArchiveEntry(
                path: name,
                size: isDirectory ? 0 : size,
                compressedSize: 0, // a tar stream is compressed as a whole, not per entry
                modified: parseTarDate(dateText),
                isDirectory: isDirectory,
                crc: nil,
                encrypted: false
            ))
        }
        return entries
    }

    /// Parses `aa list -list-format json`. Entry shape:
    /// `{"TYP":"F","PAT":"dir/file.txt","MOD":420,"MTM":1786787833.78,"DAT":15}`
    /// where TYP is D/F/L/…, DAT is the payload size and MTM a Unix timestamp.
    static func parseAppleArchiveJSON(_ output: String) -> [ArchiveEntry]? {
        guard let data = output.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return nil }

        var entries: [ArchiveEntry] = []
        for item in array {
            // The archive root is listed as an entry with an empty path; it is not a
            // file the user put in, so it is dropped.
            guard let path = item["PAT"] as? String, !path.isEmpty else { continue }
            let type = (item["TYP"] as? String) ?? "F"
            let size = (item["DAT"] as? NSNumber)?.int64Value ?? 0
            let modified = (item["MTM"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }

            entries.append(ArchiveEntry(
                path: normalisedEntryPath(path),
                size: size,
                compressedSize: 0, // aa does not report a per-entry compressed size
                modified: modified,
                isDirectory: type == "D",
                crc: nil,
                encrypted: false
            ))
        }
        return entries
    }

    /// Fallback for an `aa` build without `-list-format`: one path per line, no metadata.
    /// A trailing slash is the only directory hint available here.
    static func parseAppleArchivePlain(_ output: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        output.enumerateLines { line, _ in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return }
            entries.append(ArchiveEntry(
                path: normalisedEntryPath(path),
                size: 0,
                compressedSize: 0,
                modified: nil,
                isDirectory: path.hasSuffix("/"),
                crc: nil,
                encrypted: false
            ))
        }
        return entries
    }

    /// Strips the "./" prefix and trailing slash that tar uses, leaving the path the
    /// user actually recognises.
    private static func normalisedEntryPath(_ path: String) -> String {
        var result = path
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Reverses bsdtar's `safe_fprintf` escaping.
    ///
    /// In a UTF-8 locale bsdtar prints names verbatim and this is a no-op, which is the
    /// normal path since every invocation here forces `LC_ALL=en_US.UTF-8`. It still runs
    /// as a safety net: under any other locale each non-ASCII *byte* arrives as `\NNN`
    /// octal, so the escapes are decoded back into bytes and re-read as UTF-8 — decoding
    /// per byte rather than per character is what makes multi-byte names survive.
    static func unescapeTarName(_ name: String) -> String {
        guard name.contains("\\") else { return name }

        var bytes: [UInt8] = []
        let characters = Array(name.utf8)
        var index = 0
        while index < characters.count {
            let byte = characters[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < characters.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let next = characters[index + 1]
            if next == UInt8(ascii: "\\") {
                bytes.append(next)
                index += 2
            } else if next >= UInt8(ascii: "0"), next <= UInt8(ascii: "7"),
                      index + 3 < characters.count {
                let digits = characters[(index + 1)...(index + 3)]
                if digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "7") }) {
                    let value = digits.reduce(0) { $0 * 8 + Int($1 - UInt8(ascii: "0")) }
                    if value <= 0xFF {
                        bytes.append(UInt8(value))
                        index += 4
                        continue
                    }
                }
                bytes.append(byte)
                index += 1
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses the two shapes `ls`-style listings use: `Aug 15 14:57` for anything within
    /// the last six months, `Jan 15  2020` otherwise. The first shape omits the year, so
    /// it is read as the current year and pulled back twelve months when that would place
    /// the entry in the future.
    static func parseTarDate(_ text: String, now: Date = Date()) -> Date? {
        let normalised = text.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        if normalised.contains(":") {
            formatter.dateFormat = "MMM d HH:mm yyyy"
            let year = Calendar.current.component(.year, from: now)
            guard let date = formatter.date(from: "\(normalised) \(year)") else { return nil }
            if date.timeIntervalSince(now) > 86_400 {
                return Calendar.current.date(byAdding: .year, value: -1, to: date)
            }
            return date
        }

        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: normalised)
    }
}

// MARK: - LZ4 frame decoder

/// Streaming decoder for the LZ4 frame format — the `.lz4` files written by the `lz4`
/// command-line tool and by bsdtar's `--lz4 --format raw`. macOS can write these but
/// ships nothing that reads them back, so the app decodes them itself.
///
/// Handles concatenated frames, skippable frames, linked and independent blocks and the
/// legacy frame. Header, block and content checksums are skipped rather than verified.
enum LZ4FrameDecoder {

    enum DecodeError: LocalizedError {
        case notLZ4
        case corrupt
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notLZ4: return L("This is not an LZ4 file.")
            case .corrupt: return L("The LZ4 data is damaged or incomplete.")
            case .cancelled: return L("The operation was cancelled.")
            }
        }
    }

    private static let frameMagic: UInt32 = 0x184D_2204
    private static let legacyMagic: UInt32 = 0x184C_2102
    private static let skippableMagic: ClosedRange<UInt32> = 0x184D_2A50...0x184D_2A5F
    private static let historySize = 64 * 1024
    private static let legacyBlockSize = 8 * 1024 * 1024

    static func decompress(
        from source: URL,
        to destination: URL,
        isCancelled: () -> Bool,
        progress: (Double) -> Void
    ) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let totalSize = max((attributes?[.size] as? NSNumber)?.int64Value ?? 1, 1)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        var finished = false
        defer {
            try? output.close()
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }

        var reader = Reader(handle: input)
        var frames = 0
        while let magic = try reader.readUInt32IfAvailable() {
            switch magic {
            case frameMagic:
                try decodeFrame(&reader, output: output, isCancelled: isCancelled) { offset in
                    progress(Double(offset) / Double(totalSize))
                }
            case legacyMagic:
                try decodeLegacyFrame(&reader, output: output, isCancelled: isCancelled) { offset in
                    progress(Double(offset) / Double(totalSize))
                }
            case skippableMagic:
                try reader.skip(Int(try reader.readUInt32()))
            default:
                throw frames == 0 ? DecodeError.notLZ4 : DecodeError.corrupt
            }
            frames += 1
        }
        guard frames > 0 else { throw DecodeError.notLZ4 }
        finished = true
    }

    private static func decodeFrame(
        _ reader: inout Reader,
        output: FileHandle,
        isCancelled: () -> Bool,
        report: (Int64) -> Void
    ) throws {
        let flags = try reader.readByte()
        let blockDescriptor = try reader.readByte()
        guard flags >> 6 == 1 else { throw DecodeError.corrupt }
        let independentBlocks = flags & 0x20 != 0
        let hasBlockChecksum = flags & 0x10 != 0
        let hasContentSize = flags & 0x08 != 0
        let hasContentChecksum = flags & 0x04 != 0
        let hasDictionaryID = flags & 0x01 != 0
        let sizeCode = Int((blockDescriptor >> 4) & 0x07)
        guard (4...7).contains(sizeCode) else { throw DecodeError.corrupt }
        let maximumBlockSize = 1 << (8 + 2 * sizeCode)

        if hasContentSize { try reader.skip(8) }
        if hasDictionaryID { try reader.skip(4) }
        try reader.skip(1) // header checksum

        var history: [UInt8] = []
        while true {
            if isCancelled() { throw DecodeError.cancelled }
            let header = try reader.readUInt32()
            if header == 0 { break } // end mark
            let isStored = header & 0x8000_0000 != 0
            let size = Int(header & 0x7FFF_FFFF)
            guard size <= maximumBlockSize else { throw DecodeError.corrupt }
            let block = try reader.read(size)
            if hasBlockChecksum { try reader.skip(4) }

            let decoded: [UInt8]
            if isStored {
                decoded = block
            } else {
                decoded = try decodeBlock(block, history: independentBlocks ? [] : history,
                                          maximumOutput: maximumBlockSize)
            }
            output.write(Data(decoded))
            if !independentBlocks {
                history = decoded.count >= historySize
                    ? Array(decoded.suffix(historySize))
                    : Array((history + decoded).suffix(historySize))
            }
            report(reader.offset)
        }
        if hasContentChecksum { try reader.skip(4) }
    }

    /// The legacy frame: independent 8 MB blocks, each prefixed by its compressed size,
    /// running until end of file or until the next frame's magic number.
    private static func decodeLegacyFrame(
        _ reader: inout Reader,
        output: FileHandle,
        isCancelled: () -> Bool,
        report: (Int64) -> Void
    ) throws {
        while let size = try reader.peekUInt32IfAvailable() {
            if size == frameMagic || size == legacyMagic || skippableMagic.contains(size) { return }
            if isCancelled() { throw DecodeError.cancelled }
            _ = try reader.readUInt32()
            guard size <= UInt32(legacyBlockSize) else { throw DecodeError.corrupt }
            let block = try reader.read(Int(size))
            output.write(Data(try decodeBlock(block, history: [], maximumOutput: legacyBlockSize)))
            report(reader.offset)
        }
    }

    /// Decodes one LZ4 block. `history` is the tail of the previous block's output, which
    /// matches in a linked block may reach back into.
    static func decodeBlock(_ source: [UInt8], history: [UInt8], maximumOutput: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: history.count + maximumOutput)
        let end: Int = try buffer.withUnsafeMutableBufferPointer { out in
            guard let base = out.baseAddress else { throw DecodeError.corrupt }
            history.withUnsafeBufferPointer { past in
                if let pastBase = past.baseAddress { base.update(from: pastBase, count: past.count) }
            }
            return try source.withUnsafeBufferPointer { input in
                try decodeSequences(input, into: base, start: history.count, capacity: out.count)
            }
        }
        return Array(buffer[history.count..<end])
    }

    private static func decodeSequences(
        _ input: UnsafeBufferPointer<UInt8>,
        into output: UnsafeMutablePointer<UInt8>,
        start: Int,
        capacity: Int
    ) throws -> Int {
        guard let source = input.baseAddress else { return start }
        let inputEnd = input.count
        var ip = 0
        var op = start

        func readLength(_ initial: Int) throws -> Int {
            var length = initial
            guard initial == 15 else { return length }
            while true {
                guard ip < inputEnd else { throw DecodeError.corrupt }
                let byte = Int(source[ip])
                ip += 1
                length += byte
                if byte != 255 { return length }
            }
        }

        while ip < inputEnd {
            let token = Int(source[ip])
            ip += 1

            let literalLength = try readLength(token >> 4)
            guard literalLength <= inputEnd - ip, literalLength <= capacity - op else {
                throw DecodeError.corrupt
            }
            if literalLength > 0 {
                (output + op).update(from: source + ip, count: literalLength)
                ip += literalLength
                op += literalLength
            }
            if ip >= inputEnd { break } // the last sequence carries literals only

            guard inputEnd - ip >= 2 else { throw DecodeError.corrupt }
            let offset = Int(source[ip]) | (Int(source[ip + 1]) << 8)
            ip += 2
            guard offset > 0, offset <= op else { throw DecodeError.corrupt }

            let matchLength = try readLength(token & 0x0F) + 4
            guard matchLength <= capacity - op else { throw DecodeError.corrupt }
            let from = op - offset
            if offset >= matchLength {
                (output + op).update(from: output + from, count: matchLength)
            } else {
                // Overlapping copy repeats the last `offset` bytes; must go byte by byte.
                for index in 0..<matchLength { output[op + index] = output[from + index] }
            }
            op += matchLength
        }
        return op
    }

    /// Buffered little-endian reader over a file handle.
    private struct Reader {
        let handle: FileHandle
        private var buffer: [UInt8] = []
        private var position = 0
        private(set) var offset: Int64 = 0
        private static let chunkSize = 1 << 20

        init(handle: FileHandle) { self.handle = handle }

        private mutating func fill(_ count: Int) throws -> Bool {
            while buffer.count - position < count {
                let chunk = try handle.read(upToCount: Reader.chunkSize) ?? Data()
                if chunk.isEmpty { return false }
                buffer = Array(buffer[position...]) + chunk
                position = 0
            }
            return true
        }

        mutating func readByte() throws -> UInt8 {
            guard try fill(1) else { throw DecodeError.corrupt }
            defer { position += 1; offset += 1 }
            return buffer[position]
        }

        mutating func peekUInt32IfAvailable() throws -> UInt32? {
            guard try fill(4) else {
                if buffer.count > position { throw DecodeError.corrupt }
                return nil
            }
            return UInt32(buffer[position]) | UInt32(buffer[position + 1]) << 8
                | UInt32(buffer[position + 2]) << 16 | UInt32(buffer[position + 3]) << 24
        }

        mutating func readUInt32IfAvailable() throws -> UInt32? {
            guard let value = try peekUInt32IfAvailable() else { return nil }
            position += 4
            offset += 4
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard let value = try readUInt32IfAvailable() else { throw DecodeError.corrupt }
            return value
        }

        mutating func read(_ count: Int) throws -> [UInt8] {
            guard try fill(count) else { throw DecodeError.corrupt }
            defer { position += count; offset += Int64(count) }
            return Array(buffer[position..<(position + count)])
        }

        mutating func skip(_ count: Int) throws {
            var remaining = count
            while remaining > 0 {
                let step = min(remaining, Reader.chunkSize)
                _ = try read(step)
                remaining -= step
            }
        }
    }
}
