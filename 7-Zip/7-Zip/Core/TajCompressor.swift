import Foundation
import CommonCrypto

// MARK: - TajCompress Format v2 — Solid Mode

/// Magic bytes: "TAJ\x02"
private let kTajMagic: [UInt8] = [0x54, 0x41, 0x4A, 0x02]
private let kTajVersion: UInt16 = 2
private let kDefaultBlockSize: UInt32 = 4_194_304 // 4 MB
/// Header flags bit: solid stream is AES-encrypted (password required to extract).
/// Note: entry NAMES stay visible in the outer file table (like ZIP/AES) — the UI must
/// not offer "encrypt file names" for this format.
let kTajFlagEncrypted: UInt16 = 0x0001

// MARK: - Format Structures

/// 48-byte file header for solid mode
struct TajHeader {
    var magic: [UInt8] = kTajMagic        // 4 bytes
    var version: UInt16 = kTajVersion     // 2 bytes
    var flags: UInt16 = 0                 // 2 bytes
    var blockSize: UInt32 = kDefaultBlockSize // 4 bytes
    var fileCount: UInt32 = 0             // 4 bytes
    var uniqueBlockCount: UInt32 = 0      // 4 bytes
    var solidOriginalSize: UInt64 = 0     // 8 bytes — decompressed size of solid stream
    var blockTableOffset: UInt64 = 0      // 8 bytes
    var fileTableOffset: UInt64 = 0       // 8 bytes
    // Solid data starts at byte 48, ends at blockTableOffset
    // Total header: 48 bytes

    static let headerSize = 48
}

/// Block table entry — describes one unique data block in the solid stream
struct TajBlockEntry {
    var sha256: Data              // 32 bytes — dedup fingerprint
    var decompressedOffset: UInt64 // offset within the decompressed solid stream
    var originalSize: UInt32      // size of the block
    // Total: 44 bytes per entry
}

/// File table entry — describes one file in the archive
struct TajFileEntry {
    var path: String
    var originalSize: UInt64
    var modifiedDate: UInt64
    var permissions: UInt16
    var isDirectory: Bool
    var blockIndices: [UInt32]   // indices into the unique block table
    var crc32: UInt32
}

/// Data type classification
enum TajDataType {
    case text, executable, alreadyCompressed, binary
}

// MARK: - Errors

enum TajCompressorError: LocalizedError {
    case invalidFormat(String)
    case corruptedArchive
    case decompressionFailed(String)
    case compressionFailed(String)
    case fileNotFound(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return L("Invalid TAJ format: %@", msg)
        case .corruptedArchive: return L("Archive is corrupted")
        case .decompressionFailed(let msg): return L("Decompression failed: %@", msg)
        case .compressionFailed(let msg): return L("Compression failed: %@", msg)
        case .fileNotFound(let path): return L("File not found: %@", path)
        case .checksumMismatch(let file): return L("Checksum mismatch: %@", file)
        }
    }
}

// MARK: - Data Classifier

class DataClassifier {
    private static let compressedMagics: [[UInt8]] = [
        [0xFF, 0xD8, 0xFF],           [0x89, 0x50, 0x4E, 0x47],
        [0x50, 0x4B, 0x03, 0x04],     [0x1F, 0x8B],
        [0x42, 0x5A, 0x68],           [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00],
        [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C],
        [0x52, 0x61, 0x72, 0x21],
        [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70],
        [0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70],
        [0x1A, 0x45, 0xDF, 0xA3],     [0x66, 0x4C, 0x61, 0x43],
        [0x4F, 0x67, 0x67, 0x53],     [0x49, 0x44, 0x33], // MP3 ID3
    ]

    static func classify(_ data: Data) -> TajDataType {
        guard data.count >= 4 else { return .binary }
        let bytes = Array(data.prefix(16))

        for magic in compressedMagics {
            if bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic {
                return .alreadyCompressed
            }
        }

        let sampleSize = min(data.count, 4096)
        let sample = data.prefix(sampleSize)
        var printableCount = 0
        for byte in sample {
            if (byte >= 0x20 && byte <= 0x7E) || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                printableCount += 1
            }
        }
        if Double(printableCount) / Double(sampleSize) >= 0.75 { return .text }
        return .binary
    }
}

// MARK: - SHA-256 & CRC32

extension Data {
    var sha256: Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(count), &hash)
        }
        return Data(hash)
    }

    var crc32: UInt32 {
        return withUnsafeBytes { buffer -> UInt32 in
            let ptr = buffer.bindMemory(to: UInt8.self)
            var crc: UInt32 = 0xFFFFFFFF
            for i in 0..<count {
                let tableIndex = Int((crc ^ UInt32(ptr[i])) & 0xFF)
                crc = CRC32Table.table[tableIndex] ^ (crc >> 8)
            }
            return crc ^ 0xFFFFFFFF
        }
    }
}

private enum CRC32Table {
    static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1 == 1) ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
            }
            table[i] = crc
        }
        return table
    }()
}

// MARK: - TajArchiveWriter (Solid Mode)

class TajArchiveWriter {

    private let blockSize: Int

    init(blockSize: Int = Int(kDefaultBlockSize)) {
        self.blockSize = blockSize
    }

    func createArchive(
        at destinationPath: String,
        from sourcePaths: [String],
        password: String? = nil,
        encryptHeaders: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default

        // ── 1. Enumerate all files ──
        var dirEntries: [TajFileEntry] = []
        var allFilePaths: [(relativePath: String, absolutePath: String)] = []

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sourcePath, isDirectory: &isDir) else {
                throw TajCompressorError.fileNotFound(sourcePath)
            }

            if isDir.boolValue {
                let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                guard let enumerator = fm.enumerator(at: sourceURL, includingPropertiesForKeys: resourceKeys) else { continue }

                let dirRelative = sourceURL.lastPathComponent
                dirEntries.append(TajFileEntry(
                    path: dirRelative, originalSize: 0, modifiedDate: 0,
                    permissions: 0o755, isDirectory: true, blockIndices: [], crc32: 0
                ))

                while let fileURL = enumerator.nextObject() as? URL {
                    let relativePath = dirRelative + "/" + fileURL.path.replacingOccurrences(of: sourceURL.path + "/", with: "")
                    let resourceKeySet: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
                    let values = try fileURL.resourceValues(forKeys: resourceKeySet)

                    if values.isDirectory == true {
                        dirEntries.append(TajFileEntry(
                            path: relativePath, originalSize: 0,
                            modifiedDate: UInt64(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                            permissions: 0o755, isDirectory: true, blockIndices: [], crc32: 0
                        ))
                    } else {
                        allFilePaths.append((relativePath, fileURL.path))
                    }
                }
            } else {
                allFilePaths.append((sourceURL.lastPathComponent, sourcePath))
            }
        }

        // ── 2. Split files into blocks, hash, deduplicate ──
        var uniqueBlockMap: [Data: UInt32] = [:]   // sha256 → unique index
        var uniqueBlockData: [Data] = []            // ordered unique block data
        var fileEntries: [TajFileEntry] = dirEntries

        var totalBytesProcessed: Int64 = 0
        var totalBytes: Int64 = 0
        for (_, absPath) in allFilePaths {
            if let attrs = try? fm.attributesOfItem(atPath: absPath),
               let size = attrs[.size] as? NSNumber {
                totalBytes += size.int64Value
            }
        }

        var dedupSavings: Int64 = 0

        for (relPath, absPath) in allFilePaths {
            guard let fileData = fm.contents(atPath: absPath) else {
                throw TajCompressorError.fileNotFound(absPath)
            }

            let attrs = try fm.attributesOfItem(atPath: absPath)
            let modDate = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let fileCRC = fileData.crc32

            var blockIndices: [UInt32] = []

            var offset = 0
            while offset < fileData.count {
                let end = min(offset + blockSize, fileData.count)
                let blockData = Data(fileData[offset..<end])
                let blockHash = blockData.sha256

                if let existingIdx = uniqueBlockMap[blockHash] {
                    blockIndices.append(existingIdx)
                    dedupSavings += Int64(blockData.count)
                } else {
                    let newIdx = UInt32(uniqueBlockData.count)
                    uniqueBlockMap[blockHash] = newIdx
                    uniqueBlockData.append(blockData)
                    blockIndices.append(newIdx)
                }

                offset = end
                totalBytesProcessed += Int64(blockData.count)
                let progress = Double(totalBytesProcessed) / Double(max(totalBytes, 1)) * 50.0
                DispatchQueue.main.async { progressHandler?(progress, L("Analyzing: %@", relPath)) }
            }

            fileEntries.append(TajFileEntry(
                path: relPath, originalSize: UInt64(fileData.count),
                modifiedDate: UInt64(modDate), permissions: perms,
                isDirectory: false, blockIndices: blockIndices, crc32: fileCRC
            ))
        }

        // ── 3. Sort unique blocks by data type for better solid compression ──
        // Group: text → binary → already-compressed (LZMA2 handles ordering well)
        let sortedIndices = (0..<uniqueBlockData.count).sorted { a, b in
            let typeA = DataClassifier.classify(uniqueBlockData[a])
            let typeB = DataClassifier.classify(uniqueBlockData[b])
            return typeOrder(typeA) < typeOrder(typeB)
        }

        // Build remapping: old index → new index
        var indexRemap = [UInt32](repeating: 0, count: uniqueBlockData.count)
        for (newIdx, oldIdx) in sortedIndices.enumerated() {
            indexRemap[oldIdx] = UInt32(newIdx)
        }

        // Remap file entries' block indices
        for i in 0..<fileEntries.count {
            fileEntries[i].blockIndices = fileEntries[i].blockIndices.map { indexRemap[Int($0)] }
        }

        // Reorder unique block data
        let reorderedBlocks = sortedIndices.map { uniqueBlockData[$0] }

        // ── 4. Concatenate unique blocks into solid buffer ──
        var solidBuffer = Data()
        var blockEntries: [TajBlockEntry] = []
        var blockHashes: [Data] = []

        for (i, blockData) in reorderedBlocks.enumerated() {
            let decompressedOffset = UInt64(solidBuffer.count)
            solidBuffer.append(blockData)

            let oldIdx = sortedIndices[i]
            // Find the hash for this old index
            let hash = uniqueBlockData[oldIdx].sha256

            blockEntries.append(TajBlockEntry(
                sha256: hash,
                decompressedOffset: decompressedOffset,
                originalSize: UInt32(blockData.count)
            ))
            blockHashes.append(hash)
        }

        let solidOriginalSize = UInt64(solidBuffer.count)

        DispatchQueue.main.async { progressHandler?(55.0, L("Compressing solid stream...")) }

        // ── 5. Compress solid buffer with 7zz (ONE call, LZMA2, solid mode) ──
        // With a password the inner 7z blob is AES-256-encrypted (and its own headers
        // hidden via -mhe), so the DATA needs the password to extract. Entry names in
        // the outer .taj file table remain visible, as in ZIP/AES.
        let compressedSolid = try await compressSolid(solidBuffer, password: password)

        DispatchQueue.main.async { progressHandler?(95.0, L("Writing archive...")) }

        // ── 6. Write .taj file ──
        let output = NSMutableData()

        // Placeholder header (48 bytes)
        output.append(Data(repeating: 0, count: TajHeader.headerSize))

        // Solid compressed data (the .7z blob)
        output.append(compressedSolid)

        // Block table
        let blockTableOffset = UInt64(output.length)
        for entry in blockEntries {
            output.append(entry.sha256)  // 32 bytes
            var offset = entry.decompressedOffset
            output.append(Data(bytes: &offset, count: 8))
            var size = entry.originalSize
            output.append(Data(bytes: &size, count: 4))
        }

        // File table
        let fileTableOffset = UInt64(output.length)
        for entry in fileEntries {
            let pathData = entry.path.data(using: .utf8) ?? Data()
            var pathLen = UInt16(pathData.count)
            output.append(Data(bytes: &pathLen, count: 2))
            output.append(pathData)
            var origSize = entry.originalSize
            output.append(Data(bytes: &origSize, count: 8))
            var modDate = entry.modifiedDate
            output.append(Data(bytes: &modDate, count: 8))
            var perms = entry.permissions
            output.append(Data(bytes: &perms, count: 2))
            var isDir: UInt8 = entry.isDirectory ? 1 : 0
            output.append(Data(bytes: &isDir, count: 1))
            var blockCount = UInt32(entry.blockIndices.count)
            output.append(Data(bytes: &blockCount, count: 4))
            for var idx in entry.blockIndices {
                output.append(Data(bytes: &idx, count: 4))
            }
            var crc = entry.crc32
            output.append(Data(bytes: &crc, count: 4))
        }

        // Write real header
        var header = TajHeader()
        if password != nil { header.flags |= kTajFlagEncrypted }
        header.fileCount = UInt32(fileEntries.count)
        header.uniqueBlockCount = UInt32(blockEntries.count)
        header.solidOriginalSize = solidOriginalSize
        header.blockTableOffset = blockTableOffset
        header.fileTableOffset = fileTableOffset

        let headerData = NSMutableData()
        headerData.append(Data(kTajMagic))
        var version = header.version
        headerData.append(Data(bytes: &version, count: 2))
        var flags = header.flags
        headerData.append(Data(bytes: &flags, count: 2))
        var bs = header.blockSize
        headerData.append(Data(bytes: &bs, count: 4))
        var fc = header.fileCount
        headerData.append(Data(bytes: &fc, count: 4))
        var ubc = header.uniqueBlockCount
        headerData.append(Data(bytes: &ubc, count: 4))
        var sos = header.solidOriginalSize
        headerData.append(Data(bytes: &sos, count: 8))
        var bto = header.blockTableOffset
        headerData.append(Data(bytes: &bto, count: 8))
        var fto = header.fileTableOffset
        headerData.append(Data(bytes: &fto, count: 8))

        output.replaceBytes(in: NSRange(location: 0, length: TajHeader.headerSize),
                           withBytes: headerData.bytes, length: TajHeader.headerSize)

        try (output as Data).write(to: URL(fileURLWithPath: destinationPath))

        let compressedSize = compressedSolid.count
        let ratio = Double(compressedSize) / Double(max(solidOriginalSize, 1)) * 100

        AppLogger.shared.log(message: "✅ TAJ archive created: \(destinationPath)")
        AppLogger.shared.log(message: "   Files: \(fileEntries.count), Unique blocks: \(blockEntries.count)")
        AppLogger.shared.log(message: "   Solid stream: \(ByteCountFormatter.string(fromByteCount: Int64(solidOriginalSize), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(compressedSize), countStyle: .file)) (\(String(format: "%.1f", ratio))%)")
        AppLogger.shared.log(message: "   Dedup savings: \(ByteCountFormatter.string(fromByteCount: dedupSavings, countStyle: .file))")

        DispatchQueue.main.async { progressHandler?(100.0, L("Complete")) }
    }

    private func typeOrder(_ type: TajDataType) -> Int {
        switch type {
        case .text: return 0
        case .executable: return 1
        case .binary: return 2
        case .alreadyCompressed: return 3
        }
    }

    // MARK: - Solid Compression via 7zz

    private func compressSolid(_ data: Data, password: String?) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("taj_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputFile = tempDir.appendingPathComponent("solid.bin")
        let archiveFile = tempDir.appendingPathComponent("solid.7z")

        try data.write(to: inputFile)

        var args = ["a", "-t7z", "-mx=9", "-ms=on", "-m0=LZMA2"]
        if password != nil { args.append("-mhe=on") }
        args.append(contentsOf: ["--", archiveFile.path, inputFile.path])

        do {
            _ = try await SevenZipWrapper.runProcess(
                arguments: args,
                password: password,
                passwordSwitch: password != nil
            )
        } catch let error as SevenZipError {
            throw TajCompressorError.compressionFailed(error.localizedDescription)
        }

        return try Data(contentsOf: archiveFile)
    }
}

// MARK: - TajArchiveReader (Solid Mode)

class TajArchiveReader {

    init() {}

    /// List contents of a .taj archive
    func listArchive(at path: String) throws -> [ArchiveEntry] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let header = try readHeader(from: data)
        let blockEntries = try readBlockTable(from: data, header: header)
        let fileEntries = try readFileTable(from: data, header: header)
        let isEncrypted = (header.flags & kTajFlagEncrypted) != 0

        return fileEntries.map { entry in
            var compressedTotal: Int64 = 0
            if !entry.isDirectory {
                for idx in entry.blockIndices {
                    if idx < blockEntries.count {
                        compressedTotal += Int64(blockEntries[Int(idx)].originalSize)
                    }
                }
            }

            return ArchiveEntry(
                path: entry.path,
                size: Int64(entry.originalSize),
                compressedSize: compressedTotal,
                modified: Date(timeIntervalSince1970: TimeInterval(entry.modifiedDate)),
                isDirectory: entry.isDirectory,
                crc: String(format: "%08X", entry.crc32),
                encrypted: isEncrypted && !entry.isDirectory
            )
        }
    }

    /// Extract all files from a .taj archive
    func extractArchive(
        at sourcePath: String,
        to destinationPath: String,
        password: String? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath), options: .alwaysMapped)
        let header = try readHeader(from: data)
        let blockEntries = try readBlockTable(from: data, header: header)
        let fileEntries = try readFileTable(from: data, header: header)

        if (header.flags & kTajFlagEncrypted) != 0 && password == nil {
            throw SevenZipError.passwordRequired
        }

        let fm = FileManager.default
        try fm.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)

        DispatchQueue.main.async { progressHandler?(5.0, L("Decompressing solid stream...")) }

        // ── 1. Extract solid compressed data and decompress ──
        let solidStart = TajHeader.headerSize
        let solidEnd = Int(header.blockTableOffset)
        let compressedSolid = Data(data[solidStart..<solidEnd])
        let solidBuffer = try await decompressSolid(compressedSolid, password: password)

        DispatchQueue.main.async { progressHandler?(50.0, L("Extracting files...")) }

        // ── 2. Create directories ──
        for entry in fileEntries {
            if entry.isDirectory {
                let dirPath = (destinationPath as NSString).appendingPathComponent(entry.path)
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }
        }

        // ── 3. Extract files ──
        let totalFiles = fileEntries.filter { !$0.isDirectory }.count
        var processedFiles = 0

        for entry in fileEntries {
            guard !entry.isDirectory else { continue }

            let filePath = (destinationPath as NSString).appendingPathComponent(entry.path)
            let parentDir = (filePath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parentDir) {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            }

            // Reassemble file from blocks by slicing the solid buffer
            var fileData = Data()
            fileData.reserveCapacity(Int(entry.originalSize))

            for blockIdx in entry.blockIndices {
                guard blockIdx < blockEntries.count else {
                    throw TajCompressorError.corruptedArchive
                }

                let block = blockEntries[Int(blockIdx)]
                let start = Int(block.decompressedOffset)
                let end = start + Int(block.originalSize)

                guard end <= solidBuffer.count else {
                    throw TajCompressorError.corruptedArchive
                }

                fileData.append(solidBuffer[start..<end])
            }

            // Truncate to exact size
            if fileData.count > Int(entry.originalSize) {
                fileData = fileData.prefix(Int(entry.originalSize))
            }

            // Verify CRC32
            if fileData.crc32 != entry.crc32 {
                throw TajCompressorError.checksumMismatch(entry.path)
            }

            // Write file
            try fileData.write(to: URL(fileURLWithPath: filePath))

            // Restore attributes
            var attrs: [FileAttributeKey: Any] = [:]
            if entry.modifiedDate > 0 {
                attrs[.modificationDate] = Date(timeIntervalSince1970: TimeInterval(entry.modifiedDate))
            }
            if entry.permissions > 0 {
                attrs[.posixPermissions] = NSNumber(value: entry.permissions)
            }
            if !attrs.isEmpty {
                try? fm.setAttributes(attrs, ofItemAtPath: filePath)
            }

            processedFiles += 1
            let progress = 50.0 + Double(processedFiles) / Double(max(totalFiles, 1)) * 50.0
            DispatchQueue.main.async { progressHandler?(progress, entry.path) }
        }

        AppLogger.shared.log(message: "✅ TAJ extraction complete: \(processedFiles) files to \(destinationPath)")
    }

    // MARK: - Format Parsing

    private func readHeader(from data: Data) throws -> TajHeader {
        guard data.count >= TajHeader.headerSize else {
            throw TajCompressorError.invalidFormat(L("File too small"))
        }

        let magic = Array(data[0..<4])
        guard magic == kTajMagic else {
            throw TajCompressorError.invalidFormat(L("Invalid magic bytes"))
        }

        var header = TajHeader()
        header.version = data.readUInt16(at: 4)
        header.flags = data.readUInt16(at: 6)
        header.blockSize = data.readUInt32(at: 8)
        header.fileCount = data.readUInt32(at: 12)
        header.uniqueBlockCount = data.readUInt32(at: 16)
        header.solidOriginalSize = data.readUInt64(at: 20)
        header.blockTableOffset = data.readUInt64(at: 28)
        header.fileTableOffset = data.readUInt64(at: 36)

        guard header.blockTableOffset >= UInt64(TajHeader.headerSize),
              header.blockTableOffset < UInt64(data.count),
              header.fileTableOffset >= header.blockTableOffset,
              header.fileTableOffset < UInt64(data.count),
              header.blockTableOffset <= UInt64(Int.max),
              header.fileTableOffset <= UInt64(Int.max),
              header.uniqueBlockCount <= 50_000_000,
              header.fileCount <= 50_000_000 else {
            throw TajCompressorError.corruptedArchive
        }

        return header
    }

    private func readBlockTable(from data: Data, header: TajHeader) throws -> [TajBlockEntry] {
        var entries: [TajBlockEntry] = []
        var offset = Int(header.blockTableOffset)

        for _ in 0..<header.uniqueBlockCount {
            guard offset + 44 <= data.count else {
                throw TajCompressorError.corruptedArchive
            }

            let sha256 = Data(data[offset..<offset+32])
            offset += 32
            let decompOffset = data.readUInt64(at: offset)
            offset += 8
            let origSize = data.readUInt32(at: offset)
            offset += 4

            entries.append(TajBlockEntry(
                sha256: sha256,
                decompressedOffset: decompOffset,
                originalSize: origSize
            ))
        }

        return entries
    }

    private func readFileTable(from data: Data, header: TajHeader) throws -> [TajFileEntry] {
        var entries: [TajFileEntry] = []
        var offset = Int(header.fileTableOffset)

        for _ in 0..<header.fileCount {
            guard offset + 2 <= data.count else {
                throw TajCompressorError.corruptedArchive
            }

            let pathLen = Int(data.readUInt16(at: offset))
            offset += 2

            guard offset + pathLen <= data.count else {
                throw TajCompressorError.corruptedArchive
            }

            let path = String(data: data[offset..<offset+pathLen], encoding: .utf8) ?? ""
            offset += pathLen

            guard offset + 29 <= data.count else {
                throw TajCompressorError.corruptedArchive
            }

            let origSize = data.readUInt64(at: offset); offset += 8
            let modDate = data.readUInt64(at: offset); offset += 8
            let perms = data.readUInt16(at: offset); offset += 2
            let isDir = data[offset] == 1; offset += 1
            let blockCount = Int(data.readUInt32(at: offset)); offset += 4

            guard offset + blockCount * 4 + 4 <= data.count else {
                throw TajCompressorError.corruptedArchive
            }

            var blockIndices: [UInt32] = []
            for _ in 0..<blockCount {
                blockIndices.append(data.readUInt32(at: offset))
                offset += 4
            }

            let crc = data.readUInt32(at: offset); offset += 4

            entries.append(TajFileEntry(
                path: path, originalSize: origSize, modifiedDate: modDate,
                permissions: perms, isDirectory: isDir, blockIndices: blockIndices, crc32: crc
            ))
        }

        return entries
    }

    // MARK: - Solid Decompression via 7zz

    private func decompressSolid(_ compressedData: Data, password: String?) async throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("taj_ext_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveFile = tempDir.appendingPathComponent("solid.7z")
        let outputDir = tempDir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        try compressedData.write(to: archiveFile)

        do {
            _ = try await SevenZipWrapper.runProcess(
                arguments: ["x", "-o\(outputDir.path)", "-aoa", "--", archiveFile.path],
                password: password
            )
        } catch SevenZipError.passwordRequired {
            throw SevenZipError.passwordRequired
        } catch let error as SevenZipError {
            throw TajCompressorError.decompressionFailed(error.localizedDescription)
        }

        let extractedFile = outputDir.appendingPathComponent("solid.bin")
        guard FileManager.default.fileExists(atPath: extractedFile.path) else {
            // Try to find the file (7zz might strip path)
            guard let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: nil) else {
                throw TajCompressorError.decompressionFailed(L("Cannot find extracted solid data"))
            }
            while let fileURL = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    return try Data(contentsOf: fileURL)
                }
            }
            throw TajCompressorError.decompressionFailed(L("No extracted file found"))
        }

        return try Data(contentsOf: extractedFile)
    }
}

// MARK: - Data Reading Helpers

extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        return subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        return subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
    }

    func readUInt64(at offset: Int) -> UInt64 {
        return subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}
