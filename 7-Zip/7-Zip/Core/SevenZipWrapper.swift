import Foundation
import UniformTypeIdentifiers

/// Cancellation and pause handle for a running 7zz operation.
/// Thread-safe: `cancel()` / `setPaused(_:)` may be called from any thread (e.g. the
/// buttons of a progress window).
final class OperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var isCancelled = false
    private(set) var isPaused = false

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let cancelled = isCancelled
        let paused = isPaused
        lock.unlock()
        if cancelled {
            p.terminate()
        } else if paused, p.isRunning {
            kill(p.processIdentifier, SIGSTOP)
        }
    }

    /// Freezes the running engine process (SIGSTOP) or lets it continue (SIGCONT),
    /// like the Pause button of 7-Zip's progress dialog.
    func setPaused(_ paused: Bool) {
        lock.lock()
        isPaused = paused
        let p = process
        lock.unlock()
        if let p = p, p.isRunning {
            kill(p.processIdentifier, paused ? SIGSTOP : SIGCONT)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let wasPaused = isPaused
        isPaused = false
        let p = process
        lock.unlock()
        // A stopped process cannot act on SIGTERM until it runs again.
        if wasPaused, let p = p, p.isRunning { kill(p.processIdentifier, SIGCONT) }
        p?.terminate()
        // Grace period, then force-kill if 7zz ignores SIGTERM
        if let pid = p?.processIdentifier {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                if p?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
    }
}

/// Gathers a child process's stdout and stderr. Each pipe's readability handler runs on
/// its own queue, so the buffers live behind a lock.
final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var pendingOut = ""
    private var pendingErr = ""

    /// Appends a chunk; with `splitLines`, returns the lines that chunk completed.
    @discardableResult
    func append(_ data: Data, isError: Bool, splitLines: Bool = false) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if isError { err.append(data) } else { out.append(data) }
        guard splitLines else { return [] }
        var buffer = (isError ? pendingErr : pendingOut) + String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        if isError { pendingErr = buffer } else { pendingOut = buffer }
        return lines
    }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
}

/// Result of an archive integrity test
struct ArchiveTestResult {
    let passed: Bool
    let files: Int
    let details: String
}

/// Result of a hash calculation
struct HashResult {
    let algorithm: HashAlgorithm
    /// Per-file results in listing order
    let files: [(name: String, size: Int64, hash: String)]
    /// Aggregate hash over all data ("<ALGO> for data:")
    let aggregate: String?
}

/// File types the app opens as archives — one list shared by Finder's "Open With",
/// the open panel, double-click in the browser and the drop handler.
/// The Finder extension keeps its own copy (FinderSync.archiveExtensions).
enum ArchiveTypes {
    static let openableExtensions: Set<String> = [
        "taj", "7z", "zip", "zipx", "rar", "r00", "001",
        "tar", "gz", "gzip", "tgz", "tpz", "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "lzma", "z", "taz",
        "zst", "zstd", "tzst", "lz4", "tlz4", "aar", "yaa",
        "cab", "arj", "lzh", "lha", "wim", "swm", "esd", "cpio", "rpm", "deb", "xar", "msi", "chm",
        "iso", "dmg", "vhd", "vhdx", "vmdk", "qcow2", "squashfs", "cramfs"
    ]

    static func isArchive(path: String) -> Bool {
        if ExtendedArchiver.canHandle(path: path) != nil { return true }
        return openableExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isArchive(url: URL) -> Bool { isArchive(path: url.path) }
}

/// Wrapper around the bundled 7zz command-line tool.
///
/// Security invariants:
/// - Passwords are NEVER passed via argv (visible in `ps`). Read operations let 7zz
///   prompt ("Enter password:") and the password is written to its stdin; create/update
///   operations pass a bare `-p` switch which forces the same stdin prompt.
/// - Positional arguments are always preceded by `--` so file names starting with "-"
///   cannot be parsed as switches.
class SevenZipWrapper {

    // MARK: - Static Properties

    /// Path to bundled 7zz binary
    static var binaryPath: String {
        if let path = Bundle.main.path(forResource: "7zz", ofType: nil) {
            return path
        }
        // Fallback for development
        for candidate in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"] {
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return "/usr/local/bin/7zz"
    }

    /// Supported archive types for Open Panel
    static var supportedArchiveTypes: [UTType] {
        var seen = Set<String>()
        return ArchiveTypes.openableExtensions.sorted()
            .compactMap { UTType(filenameExtension: $0) }
            .filter { seen.insert($0.identifier).inserted }
    }

    // MARK: - Archive Operations

    /// List contents of an archive
    static func listArchive(at path: String, password: String? = nil) async throws -> [ArchiveEntry] {
        if path.lowercased().hasSuffix(".taj") {
            return try TajArchiveReader().listArchive(at: path)
        }
        // Formats the 7-Zip engine has no codec for (lz4, Apple Archive, and tar.zst
        // when Homebrew's zstd is around) go through ExtendedArchiver.
        if ExtendedArchiver.canHandle(path: path) != nil {
            return try await ExtendedArchiver.list(at: path)
        }
        let output = try await runProcess(
            arguments: ["l", "-slt", "--", path],
            password: password
        )
        return parseListOutput(output, archivePath: path)
    }

    /// Archive-level properties from the `l -slt` header block (Type, Method, Solid, Blocks,
    /// Physical Size, Headers Size, ...) in output order.
    static func archiveProperties(at path: String, password: String? = nil) async throws -> [(String, String)] {
        let output = try await runProcess(
            arguments: ["l", "-slt", "--", path],
            password: password
        )
        var props: [(String, String)] = []
        var inHeader = false
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("----------") { break }
            if line.hasPrefix("Listing archive:") { inHeader = true; continue }
            guard inHeader, let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                props.append((key, value))
            }
        }
        return props
    }

    /// Extract archive to destination
    static func extractArchive(
        at sourcePath: String,
        to destinationPath: String,
        password: String? = nil,
        overwriteMode: OverwriteMode = .ask,
        flatten: Bool = false,
        token: OperationToken? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        if sourcePath.lowercased().hasSuffix(".taj") {
            try await TajArchiveReader().extractArchive(at: sourcePath, to: destinationPath, password: password, progressHandler: progressHandler)
            return
        }
        if ExtendedArchiver.canHandle(path: sourcePath) != nil {
            try await ExtendedArchiver.extract(at: sourcePath, to: destinationPath, token: token) { percent, file in
                progressHandler?(percent, file)
            }
            return
        }

        var args = [flatten ? "e" : "x", "-o\(destinationPath)", "-bsp1"]
        if !overwriteMode.flag.isEmpty { args.append(overwriteMode.flag) }
        args.append(contentsOf: ["--", sourcePath])

        _ = try await runProcess(arguments: args, password: password, token: token, progressHandler: progressHandler)
    }

    /// Extract specific files from archive to destination
    static func extractFiles(
        from sourcePath: String,
        files: [String],
        to destinationPath: String,
        password: String? = nil,
        overwriteMode: OverwriteMode = .ask,
        flatten: Bool = false,
        token: OperationToken? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        // Formats 7zz cannot read: unpack everything privately, then copy the chosen items.
        if ExtendedArchiver.canHandle(path: sourcePath) != nil {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appendingPathComponent("tajarchive-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staging) }
            try await ExtendedArchiver.extract(at: sourcePath, to: staging.path, token: token) { percent, file in
                progressHandler?(percent, file)
            }
            for file in files {
                let source = staging.appendingPathComponent(file)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = URL(fileURLWithPath: destinationPath)
                    .appendingPathComponent(flatten ? source.lastPathComponent : file)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    if overwriteMode == .skipExisting { continue }
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: source, to: target)
            }
            return
        }

        var args = [flatten ? "e" : "x", "-o\(destinationPath)", "-bsp1"]
        if !overwriteMode.flag.isEmpty { args.append(overwriteMode.flag) }
        args.append("--")
        args.append(sourcePath)
        args.append(contentsOf: files)

        _ = try await runProcess(arguments: args, password: password, token: token, progressHandler: progressHandler)
    }

    /// Delete specific files from archive
    static func deleteFiles(
        from sourcePath: String,
        files: [String],
        password: String? = nil
    ) async throws {
        var args = ["d", "--", sourcePath]
        args.append(contentsOf: files)
        _ = try await runProcess(arguments: args, password: password, passwordSwitch: password != nil)
    }

    /// Rename an entry inside an archive (7zz `rn`)
    static func renameEntry(
        in archivePath: String,
        from oldPath: String,
        to newPath: String,
        password: String? = nil
    ) async throws {
        let args = ["rn", "--", archivePath, oldPath, newPath]
        _ = try await runProcess(arguments: args, password: password, passwordSwitch: password != nil)
    }

    /// Update existing archive with new files, optionally placing them inside a folder.
    ///
    /// `workingDirectoryOverride` + `storedName` are used when writing an edited file
    /// back: the file already sits at its in-archive path inside a temp tree, so 7zz
    /// only needs to be pointed at that root and given the relative name.
    static func updateArchive(
        at destinationPath: String,
        with sourcePaths: [String],
        inFolder folder: String = "",
        password: String? = nil,
        token: OperationToken? = nil,
        workingDirectoryOverride: URL? = nil,
        storedName: String? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        if let workingDirectory = workingDirectoryOverride, let name = storedName {
            var args = ["u", "-bsp1"]
            if password != nil { args.append("-p") }
            args.append(contentsOf: ["--", destinationPath, name])
            _ = try await runProcess(arguments: args, password: password,
                                     currentDirectoryURL: workingDirectory,
                                     token: token, progressHandler: progressHandler)
            return
        }

        var args = ["u", "-bsp1"]
        var tempBaseURL: URL? = nil
        var cwd: URL? = nil
        let fileManager = FileManager.default

        var positional: [String]
        if !folder.isEmpty {
            // Stage files under a temp dir mirroring the target in-archive folder
            let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            tempBaseURL = tempDir
            let targetFolderURL = tempDir.appendingPathComponent(folder)
            try fileManager.createDirectory(at: targetFolderURL, withIntermediateDirectories: true, attributes: nil)
            for sourcePath in sourcePaths {
                let sourceURL = URL(fileURLWithPath: sourcePath)
                let destURL = targetFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
                try fileManager.copyItem(at: sourceURL, to: destURL)
            }
            positional = [destinationPath, "."]
            cwd = tempDir
        } else {
            positional = [destinationPath]
            positional.append(contentsOf: sourcePaths)
        }

        if password != nil { args.append("-p") }
        args.append("--")
        args.append(contentsOf: positional)

        defer {
            if let tempBaseURL = tempBaseURL {
                try? fileManager.removeItem(at: tempBaseURL)
            }
        }

        _ = try await runProcess(arguments: args, password: password, currentDirectoryURL: cwd, token: token, progressHandler: progressHandler)
    }

    /// Create an archive with the full option set of the Add-to-Archive dialog.
    /// Returns the path of the produced file, which differs from `destinationPath`
    /// when a self-extracting archive was requested.
    @discardableResult
    static func createArchive(
        at destinationPath: String,
        from sourcePaths: [String],
        workingDirectory: URL? = nil,
        format: ArchiveFormat = .sevenZip,
        settings: CompressionSettings = CompressionSettings(),
        password: String? = nil,
        token: OperationToken? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> String {

        if format == .taj {
            try await TajArchiveWriter().createArchive(
                at: destinationPath,
                from: sourcePaths,
                password: password,
                encryptHeaders: settings.encryptHeaders,
                progressHandler: progressHandler
            )
            return destinationPath
        }

        // GZip, BZip2, XZ compress a single file only
        let isSingleFileArchiver = (format == .gzip || format == .bzip2 || format == .xz)
        if isSingleFileArchiver {
            if sourcePaths.count > 1 {
                throw SevenZipError.commandFailed(L("The %@ format holds a single file only. Use TAR, ZIP or 7z for several files or folders.", format.displayName))
            } else if let first = sourcePaths.first {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw SevenZipError.commandFailed(L("The %@ format cannot hold a folder. Use TAR, ZIP or 7z instead.", format.displayName))
                }
            }
        }

        let archiveExists = FileManager.default.fileExists(atPath: destinationPath)
        let command = archiveExists ? settings.updateMode.command : "a"

        var args = [command, "-t\(format.rawValue)", "-mx=\(settings.level.rawValue)", "-bsp1"]

        if archiveExists, let updateSwitch = settings.updateMode.updateSwitch {
            args.append(updateSwitch)
        }

        let method = settings.method
        if let method = method, method != .tajAuto, settings.level != .store {
            args.append("-m0=\(method.flag)")

            if let dictionary = settings.dictionary, !dictionary.isEmpty, method.hasConfigurableDictionary {
                // PPMd calls its working buffer "mem", every other method calls it "d"
                args.append(method == .ppmd ? "-mmem=\(dictionary)" : "-md=\(dictionary)")
            }
            if let wordSize = settings.wordSize {
                args.append(method == .ppmd ? "-mo=\(wordSize)" : "-mfb=\(wordSize)")
            }
        }

        if format.supportsSolidBlocks && settings.level != .store {
            args.append("-ms=\(settings.solidBlock.rawValue)")
        }

        if settings.threadCount > 0 {
            args.append("-mmt=\(settings.threadCount)")
        } else {
            args.append("-mmt=on")
        }

        if let pathFlag = settings.pathMode.flag {
            args.append(pathFlag)
        }

        if !settings.volumeSize.isEmpty && format.supportsVolumes {
            args.append("-v\(settings.volumeSize)")
        }

        // Store symlinks as links rather than following them into duplicate content
        if settings.storeSymlinks && (format == .sevenZip || format == .tar) {
            args.append("-snl")
        }

        if password != nil {
            args.append("-p")
            if settings.encryptHeaders && format.supportsHeaderEncryption {
                args.append("-mhe=on")
            }
            if format == .zip {
                args.append("-mem=\(settings.encryptionMethod.rawValue)")
            }
        }

        if settings.deleteAfter {
            args.append("-sdel")
        }

        // Free-form parameters go last so they can override anything above
        let customArgs = settings.customParameters
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
        args.append(contentsOf: customArgs)

        args.append("--")
        args.append(destinationPath)

        // With a working directory, pass bare names so absolute paths aren't stored
        if workingDirectory != nil && settings.pathMode == .relative {
            args.append(contentsOf: sourcePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        } else {
            args.append(contentsOf: sourcePaths)
        }

        _ = try await runProcess(arguments: args, password: password, currentDirectoryURL: workingDirectory, token: token, progressHandler: progressHandler)

        if settings.createSFX && format.supportsSFX {
            progressHandler?(99, L("Building self-extracting archive…"))
            let sfxPath = try SFXBuilder.makeSelfExtracting(archivePath: destinationPath, format: format)
            try? FileManager.default.removeItem(atPath: destinationPath)
            return sfxPath
        }

        return destinationPath
    }

    /// Add or update files in an existing archive (at archive root or a subfolder)
    static func addFiles(
        to archivePath: String,
        sourcePaths: [String],
        inFolder folder: String = "",
        password: String? = nil,
        token: OperationToken? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        try await updateArchive(
            at: archivePath,
            with: sourcePaths,
            inFolder: folder,
            password: password,
            token: token,
            progressHandler: progressHandler
        )
    }

    /// Test archive integrity. Throws on password-required; returns a structured result otherwise.
    static func testArchive(at path: String, password: String? = nil) async throws -> ArchiveTestResult {
        do {
            let output = try await runProcess(arguments: ["t", "--", path], password: password)
            let passed = output.contains("Everything is Ok")
            var files = 0
            if let match = output.range(of: "Files: ") {
                let tail = output[match.upperBound...].prefix(while: { $0.isNumber })
                files = Int(tail) ?? 0
            }
            return ArchiveTestResult(passed: passed, files: files, details: output)
        } catch SevenZipError.passwordRequired {
            throw SevenZipError.passwordRequired
        } catch SevenZipError.cancelled {
            throw SevenZipError.cancelled
        } catch SevenZipError.commandFailed(let message) {
            // Exit code 2 = real integrity failure — report as a failed test, not an app error
            return ArchiveTestResult(passed: false, files: 0, details: message)
        }
    }

    /// Calculate hashes of files with the given algorithm
    static func calculateHash(
        of paths: [String],
        algorithm: HashAlgorithm = .sha256,
        token: OperationToken? = nil
    ) async throws -> HashResult {
        var args = ["h", "-scrc\(algorithm.rawValue)", "--"]
        args.append(contentsOf: paths)
        let output = try await runProcess(arguments: args, password: nil, token: token)
        return parseHashOutput(output, algorithm: algorithm)
    }

    // MARK: - Process Runner

    /// Runs 7zz. `password` is supplied via stdin when 7zz prompts ("Enter password").
    /// `passwordSwitch` appends a bare `-p` (needed for create/update so 7zz *asks*;
    /// read operations prompt on their own when the archive needs a password).
    @discardableResult
    static func runProcess(
        arguments: [String],
        password: String?,
        passwordSwitch: Bool = false,
        currentDirectoryURL: URL? = nil,
        token: OperationToken? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        if let cwd = currentDirectoryURL { process.currentDirectoryURL = cwd }

        var finalArgs = arguments
        // Bare -p must precede "--"
        if passwordSwitch && !finalArgs.contains("-p") {
            if let ddIndex = finalArgs.firstIndex(of: "--") {
                finalArgs.insert("-p", at: ddIndex)
            } else {
                finalArgs.append("-p")
            }
        }
        if !finalArgs.contains(where: { $0.hasPrefix("-mmt") }) {
            if let ddIndex = finalArgs.firstIndex(of: "--") {
                finalArgs.insert("-mmt=on", at: ddIndex)
            } else {
                finalArgs.append("-mmt=on")
            }
        }
        process.arguments = finalArgs

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Password delivery: 7zz fully buffers its "Enter password:" prompt when stdout
        // is a pipe, so prompt-detection would deadlock. Instead the password is written
        // to stdin UP FRONT (twice, for a potential Verify prompt) and the write end is
        // closed; 7zz reads the line whenever it asks. With no password, stdin is
        // /dev/null — a needed prompt hits EOF, 7zz exits, and the flushed output
        // reveals "Enter password", which maps to .passwordRequired below.
        var inPipe: Pipe? = nil
        if password != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Log the command without any secrets (password never appears in argv by design)
        AppLogger.shared.log(message: "▶️ 7zz \(finalArgs.joined(separator: " "))")

        let runState = RunState()
        let collector = PipeCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                runState.markOutEOF()
            } else {
                collector.append(data, isError: false)
                if let handler = progressHandler {
                    parseProgressData(String(decoding: data, as: UTF8.self), handler: handler)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                runState.markErrEOF()
            } else {
                collector.append(data, isError: true)
            }
        }
        process.terminationHandler = { _ in
            runState.markExited()
        }

        // Never attach before launching: terminate() on a Process that has not run
        // raises an Objective-C exception that Swift cannot catch.
        if token?.isCancelled == true {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw SevenZipError.cancelled
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runState.setContinuation(continuation)
            do {
                try process.run()
                token?.attach(process)
                if let password = password, let pipe = inPipe {
                    let line = password + "\n"
                    if let data = (line + line).data(using: .utf8) {
                        try? pipe.fileHandleForWriting.write(contentsOf: data)
                    }
                    try? pipe.fileHandleForWriting.close()
                }
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                runState.failEarly(error)
            }
        }

        let fullOutput = String(decoding: collector.stdout, as: UTF8.self)
        let errorOutput = String(decoding: collector.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if token?.isCancelled == true {
            throw SevenZipError.cancelled
        }

        let lowerFull = fullOutput.lowercased()
        let lowerErr = errorOutput.lowercased()

        let promptedWithoutPassword = password == nil &&
            (lowerFull.contains("enter password") || lowerErr.contains("enter password"))

        if promptedWithoutPassword ||
           lowerErr.contains("wrong password") || lowerErr.contains("cannot open encrypted archive") ||
           lowerFull.contains("wrong password") || lowerFull.contains("cannot open encrypted archive") {
            throw SevenZipError.passwordRequired
        }

        if process.terminationStatus == 0 || process.terminationStatus == 1 { // 1 = warning
            AppLogger.shared.log(message: "✅ 7zz finished [\(fullOutput.utf8.count) bytes output]")
            return fullOutput
        } else {
            AppLogger.shared.log(message: "❌ 7zz failed (status \(process.terminationStatus)): \(errorOutput)", level: .error)
            throw SevenZipError.commandFailed(errorOutput.isEmpty ? L("The 7-Zip engine stopped with error code %d.", Int(process.terminationStatus)) : errorOutput)
        }
    }

    /// Lock-protected completion state: resumes the continuation exactly once,
    /// after the process exited AND both pipes reached EOF.
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

    // MARK: - Output Parsing

    private static func parseProgressData(_ data: String, handler: @escaping (Double, String) -> Void) {
        // 7zz updates progress in-line using \r
        let rawFragments = data.components(separatedBy: ["\r", "\n"])

        for fragment in rawFragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let percentRange = trimmed.range(of: "%") {
                let beforePercent = trimmed[..<percentRange.lowerBound]
                let components = beforePercent.components(separatedBy: .whitespaces)

                if let lastComponent = components.last, let percent = Double(lastComponent) {
                    var fileName = ""
                    let afterPercent = trimmed[percentRange.upperBound...]

                    if let plusIndex = afterPercent.range(of: "+ ") {
                        fileName = String(afterPercent[plusIndex.upperBound...])
                    } else if let minusIndex = afterPercent.range(of: "- ") {
                        fileName = String(afterPercent[minusIndex.upperBound...])
                    }

                    DispatchQueue.main.async {
                        handler(percent, fileName)
                    }
                }
            }
        }
    }

    /// zstd streams list their single item without a "Path =" line: name it after the
    /// archive, minus the compression suffix ("x.tar.zst" → "x.tar", "x.tzst" → "x.tar").
    private static func unnamedPayloadName(for archivePath: String?) -> String {
        guard let archivePath = archivePath else { return "data" }
        let name = (archivePath as NSString).lastPathComponent
        let lower = name.lowercased()
        for short in [".tzst", ".tzstd"] where lower.hasSuffix(short) {
            return String(name.dropLast(short.count)) + ".tar"
        }
        for suffix in [".zst", ".zstd"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return (name as NSString).deletingPathExtension
    }

    private static func parseListOutput(_ output: String, archivePath: String? = nil) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(5000)

        // -slt prints an archive-info header block (which itself contains "Path = <archive>")
        // and only then a "----------" separator followed by the real entry records.
        var inEntries = false

        var currentPath: String = ""
        var currentSize: Int64 = 0
        var currentPackedSize: Int64 = 0
        var currentModified: Date? = nil
        var currentIsDirectory = false
        var currentCRC: String? = nil
        var currentEncrypted = false

        var sawField = false

        func flush() {
            if currentPath.isEmpty && sawField {
                currentPath = unnamedPayloadName(for: archivePath)
            }
            sawField = false
            if !currentPath.isEmpty {
                entries.append(ArchiveEntry(
                    path: currentPath,
                    size: currentSize,
                    compressedSize: currentPackedSize,
                    modified: currentModified,
                    isDirectory: currentIsDirectory,
                    crc: currentCRC,
                    encrypted: currentEncrypted
                ))
            }
            currentPath = ""
            currentSize = 0
            currentPackedSize = 0
            currentModified = nil
            currentIsDirectory = false
            currentCRC = nil
            currentEncrypted = false
        }

        output.enumerateLines { line, _ in
            if !inEntries {
                if line.hasPrefix("----------") { inEntries = true }
                return
            }
            if line.isEmpty {
                flush()
            } else if let eqIndex = line.firstIndex(of: "=") {
                let keyLen = line.distance(from: line.startIndex, to: eqIndex)
                let key = line.prefix(keyLen).trimmingCharacters(in: .whitespaces)
                let valRaw = line.suffix(from: line.index(after: eqIndex)).trimmingCharacters(in: .whitespaces)

                sawField = true
                switch key {
                case "Path": currentPath = valRaw
                case "Size": currentSize = Int64(valRaw) ?? 0
                case "Packed Size": currentPackedSize = Int64(valRaw) ?? 0
                case "Modified": currentModified = parseDate(valRaw)
                case "Folder": if valRaw == "+" { currentIsDirectory = true }
                case "Attributes": if valRaw.contains("D") { currentIsDirectory = true }
                case "CRC": currentCRC = valRaw.isEmpty ? nil : valRaw
                case "Encrypted": currentEncrypted = (valRaw == "+")
                default: break
                }
            }
        }
        flush()

        return entries
    }

    private static func parseHashOutput(_ output: String, algorithm: HashAlgorithm) -> HashResult {
        // Format:
        //   <ALGO>   Size  Name
        //   ----...  ----  ----
        //   <hash>   <size>  <name>
        //   ----...  ----  ----
        //   <hash>   <size>              <- aggregate row (no name)
        //   ...
        //   <ALGO> for data: <hash>
        var files: [(name: String, size: Int64, hash: String)] = []
        var aggregate: String? = nil
        var dashLinesSeen = 0

        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("----") {
                dashLinesSeen += 1
                return
            }
            if trimmed.isEmpty { return }

            if let range = trimmed.range(of: "for data:") {
                let value = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { aggregate = String(value) }
                return
            }

            guard dashLinesSeen == 1 else { return } // rows between the two dashed lines

            // hash <ws> size <ws> name (name may contain spaces)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let size = Int64(parts[1]) else { return }
            let hash = String(parts[0])
            let name = parts[2...].joined(separator: " ")
            files.append((name: name, size: size, hash: hash))
        }

        return HashResult(algorithm: algorithm, files: files, aggregate: aggregate)
    }

    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 7zz prints local times, and 25.01 appends up to seven fractional digits
    /// ("2026-10-17 07:08:20.7019034"), so only the first 19 characters are parsed.
    private static func parseDate(_ dateString: String) -> Date? {
        guard dateString.count >= 19 else { return nil }
        return listDateFormatter.date(from: String(dateString.prefix(19)))
    }
}

// MARK: - Supporting Types

enum SevenZipError: LocalizedError {
    case commandFailed(String)
    case archiveNotFound
    case passwordRequired
    case invalidArchive
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .archiveNotFound: return L("Archive not found")
        case .passwordRequired: return L("Password required")
        case .invalidArchive: return L("Invalid or corrupted archive")
        case .cancelled: return L("Operation cancelled")
        }
    }
}

enum ArchiveFormat: String, CaseIterable {
    // 7z leads the list because it is the default format of the dialog
    case sevenZip = "7z"
    case taj = "taj"
    case zip = "zip"
    case tar = "tar"
    case gzip = "gzip"
    case bzip2 = "bzip2"
    case xz = "xz"

    var displayName: String {
        switch self {
        case .taj: return L("TAJ (Adaptive)")
        case .sevenZip: return "7z"
        case .zip: return "ZIP"
        case .tar: return "TAR"
        case .gzip: return "GZip"
        case .bzip2: return "BZip2"
        case .xz: return "XZ"
        }
    }

    var extensionString: String {
        switch self {
        case .taj: return "taj"
        case .sevenZip: return "7z"
        case .zip: return "zip"
        case .tar: return "tar"
        case .gzip: return "gz"
        case .bzip2: return "bz2"
        case .xz: return "xz"
        }
    }
}

enum CompressionLevel: Int, CaseIterable, Codable {
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9

    var displayName: String {
        switch self {
        case .store: return L("Store (no compression)")
        case .fastest: return L("Fastest")
        case .fast: return L("Fast")
        case .normal: return L("Normal")
        case .maximum: return L("Maximum")
        case .ultra: return L("Ultra")
        }
    }
}

enum CompressionMethod: String, CaseIterable {
    case tajAuto = "Auto (Adaptive)"
    case lzma2 = "LZMA2"
    case lzma = "LZMA"
    case ppmd = "PPMd"
    case bzip2 = "BZip2"
    case deflate = "Deflate"
    case deflate64 = "Deflate64"

    var flag: String { rawValue }
}

enum OverwriteMode: String {
    case ask = ""
    case overwriteAll = "-aoa"
    case skipExisting = "-aos"
    case renameExtracting = "-aou"
    case renameExisting = "-aot"

    var flag: String { rawValue }
}

enum HashAlgorithm: String, CaseIterable {
    case crc32 = "CRC32"
    case crc64 = "CRC64"
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
    case blake2sp = "BLAKE2sp"
}
