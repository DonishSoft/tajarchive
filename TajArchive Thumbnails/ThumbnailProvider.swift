import QuickLookThumbnailing
import AppKit

/// Draws Finder thumbnails for archive files.
///
/// Without this, every archive shows the same generic document icon and a folder of
/// mixed downloads is unreadable at a glance. Here each archive gets a document shape
/// carrying its format badge, and — for containers we can inspect cheaply — the number
/// of files inside. Nothing here decompresses anything: a ZIP central directory and a
/// 7z start header are both a bounded read at a known offset, so the thumbnail is fast
/// even for multi-gigabyte archives.
class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let url = request.fileURL
        let badge = Self.badgeText(for: url)
        let count = Self.entryCount(for: url)
        let tint = Self.tint(for: badge)
        let size = request.maximumSize

        // The "current context" variant hands over a context already scaled for the
        // display (Retina included), so drawing happens in points over the full size.
        let reply = QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            Self.draw(size: size, badge: badge, count: count, tint: tint)
            return true
        })
        handler(reply, nil)
    }

    // MARK: - Drawing

    private static func draw(size: CGSize, badge: String, count: Int?, tint: NSColor) {
        let side = min(size.width, size.height)
        let pageRect = NSRect(x: (size.width - side * 0.78) / 2, y: side * 0.08,
                              width: side * 0.78, height: side * 0.84)
        let corner = side * 0.08

        // Page with a soft shadow, so it reads on white and dark Finder backgrounds alike
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = side * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
        shadow.set()
        let page = NSBezierPath(roundedRect: pageRect, xRadius: corner, yRadius: corner)
        NSColor.white.setFill()
        page.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Coloured band carrying the format name
        let bandHeight = pageRect.height * 0.32
        let bandRect = NSRect(x: pageRect.minX, y: pageRect.minY, width: pageRect.width, height: bandHeight)
        NSGraphicsContext.saveGraphicsState()
        page.addClip()
        tint.setFill()
        bandRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Zipper teeth down from the top edge, so the icon says "archive" even at 32 pt
        let toothWidth = pageRect.width * 0.11
        let toothHeight = pageRect.height * 0.035
        let toothStep = toothHeight * 1.7
        tint.withAlphaComponent(0.55).setFill()
        var toothY = pageRect.maxY - toothHeight
        for index in 0..<5 {
            let offset = (index % 2 == 0 ? -1 : 1) * toothWidth * 0.32
            let tooth = NSRect(x: pageRect.midX - toothWidth / 2 + offset, y: toothY,
                               width: toothWidth, height: toothHeight)
            NSBezierPath(roundedRect: tooth, xRadius: toothHeight / 2, yRadius: toothHeight / 2).fill()
            toothY -= toothStep
        }
        let zipperBottom = toothY + toothStep

        // Format badge
        let badgeFont = NSFont.systemFont(ofSize: bandHeight * 0.5, weight: .heavy)
        let badgeString = NSAttributedString(string: badge, attributes: [.font: badgeFont, .foregroundColor: NSColor.white])
        let badgeSize = badgeString.size()
        let badgeScale = min(1, (bandRect.width * 0.86) / max(badgeSize.width, 1))
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: bandRect.midX, yBy: bandRect.midY)
        transform.scale(by: badgeScale)
        transform.concat()
        badgeString.draw(at: NSPoint(x: -badgeSize.width / 2, y: -badgeSize.height / 2))
        NSGraphicsContext.restoreGraphicsState()

        // Number of entries — digits and a symbol, so it needs no translation
        guard let count = count, side >= 64 else { return }
        let freeTop = zipperBottom - pageRect.height * 0.04
        let freeBottom = bandRect.maxY + pageRect.height * 0.04
        guard freeTop > freeBottom else { return }
        let textFont = NSFont.monospacedDigitSystemFont(ofSize: min(pageRect.height * 0.13, freeTop - freeBottom), weight: .semibold)
        let color = NSColor.black.withAlphaComponent(0.55)
        let text = NSAttributedString(string: NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                                      attributes: [.font: textFont, .foregroundColor: color])
        let textSize = text.size()
        var symbolWidth: CGFloat = 0
        var symbol: NSImage?
        let configuration = NSImage.SymbolConfiguration(pointSize: textFont.pointSize * 0.8, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: "doc.on.doc.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            symbol = image
            symbolWidth = image.size.width + textFont.pointSize * 0.25
        }
        let totalWidth = symbolWidth + textSize.width
        let originX = pageRect.midX - totalWidth / 2
        let centerY = (freeTop + freeBottom) / 2
        if let symbol = symbol {
            symbol.draw(in: NSRect(x: originX, y: centerY - symbol.size.height / 2,
                                   width: symbol.size.width, height: symbol.size.height))
        }
        text.draw(at: NSPoint(x: originX + symbolWidth, y: centerY - textSize.height / 2))
    }

    // MARK: - Metadata

    private static func badgeText(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "7z": return "7Z"
        case "taj": return "TAJ"
        case "zip", "zipx": return "ZIP"
        case "rar": return "RAR"
        case "tar": return "TAR"
        case "gz", "tgz": return "GZ"
        case "bz2", "tbz2": return "BZ2"
        case "xz", "txz": return "XZ"
        case "zst", "tzst": return "ZST"
        case "lz4": return "LZ4"
        case "aar", "yaa": return "AAR"
        case "iso": return "ISO"
        case "cab": return "CAB"
        case "001": return "001"
        default: return ext.uppercased().isEmpty ? "ARC" : String(ext.uppercased().prefix(4))
        }
    }

    private static func tint(for badge: String) -> NSColor {
        switch badge {
        case "7Z":  return NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.64, alpha: 1)
        case "TAJ": return NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.62, alpha: 1)
        case "ZIP": return NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.10, alpha: 1)
        case "RAR": return NSColor(calibratedRed: 0.60, green: 0.20, blue: 0.24, alpha: 1)
        case "TAR", "GZ", "BZ2", "XZ", "ZST", "LZ4":
            return NSColor(calibratedRed: 0.19, green: 0.47, blue: 0.40, alpha: 1)
        default:    return NSColor(calibratedRed: 0.35, green: 0.38, blue: 0.44, alpha: 1)
        }
    }

    /// Reads just enough of the container to report how many files it holds.
    /// Returns nil for formats where that would mean decompressing.
    private static func entryCount(for url: URL) -> Int? {
        switch url.pathExtension.lowercased() {
        case "zip", "zipx": return zipEntryCount(url)
        case "taj": return tajEntryCount(url)
        default: return nil
        }
    }

    /// ZIP: the end-of-central-directory record lives in the last 64 KB.
    private static func zipEntryCount(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 22 else { return nil }

        let tailLength = Int(min(fileSize, 65_557))
        guard let offset = UInt64(exactly: fileSize - UInt64(tailLength)) else { return nil }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: tailLength), data.count >= 22 else { return nil }

        let bytes = [UInt8](data)
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                let count = Int(bytes[index + 10]) | Int(bytes[index + 11]) << 8
                return count == 0xFFFF ? nil : count   // ZIP64: not worth a second seek here
            }
            index -= 1
        }
        return nil
    }

    /// TAJ: the file count sits in the fixed 48-byte header.
    private static func tajEntryCount(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 48), header.count == 48 else { return nil }
        let bytes = [UInt8](header)
        guard bytes[0] == 0x54, bytes[1] == 0x41, bytes[2] == 0x4A else { return nil }
        let count = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
        return Int(exactly: count)
    }
}
