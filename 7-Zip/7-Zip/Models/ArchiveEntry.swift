import Foundation

/// Represents a single entry (file or folder) in an archive
struct ArchiveEntry: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let size: Int64
    let compressedSize: Int64
    let modified: Date?
    let isDirectory: Bool
    let crc: String?
    let encrypted: Bool
    
    /// File/folder name without path
    var name: String {
        (path as NSString).lastPathComponent
    }
    
    /// Parent directory path
    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }
    
    /// File extension
    var fileExtension: String {
        (path as NSString).pathExtension
    }
    
    /// Compression ratio (0-100%)
    var compressionRatio: Double {
        guard size > 0 else { return 0 }
        return Double(size - compressedSize) / Double(size) * 100
    }
    
    /// Formatted file size
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    
    /// Formatted compressed size
    var formattedCompressedSize: String {
        ByteCountFormatter.string(fromByteCount: compressedSize, countStyle: .file)
    }
    
    /// Formatted modified date, short enough for the list column ("17.10.2026, 07:08")
    var formattedDate: String {
        guard let modified = modified else { return "" }
        return ArchiveEntry.dateFormatter.string(from: modified)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLocale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Compression options for creating archives
struct CompressionOptions {
    var format: ArchiveFormat = .sevenZip
    var compressionLevel: CompressionLevel = .normal
    var password: String?
    var encryptHeaders: Bool = false
    var splitVolumes: Bool = false
    var volumeSize: Int64 = 0
    var deleteAfterCompression: Bool = false
    var createSolidArchive: Bool = true
    var threadCount: Int = 0 // 0 = auto
}

/// Extraction options
struct ExtractionOptions {
    var destinationPath: String
    var password: String?
    var overwriteMode: OverwriteMode = .ask
    var preserveDirectoryStructure: Bool = true
    var deleteAfterExtraction: Bool = false
}
