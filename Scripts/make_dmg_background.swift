import AppKit

// Background for the TajArchive disk image window (660 × 400 pt): the app icon sits at
// (165, 180) and the Applications link at (495, 180), measured from the top-left, as
// configured in Scripts/dmg_settings.py. Everything important stays in the top 340 pt,
// because Finder may add a tab bar that hides the bottom of the window.
// Usage: swiftc -O make_dmg_background.swift -o /tmp/bg && /tmp/bg <output-folder>
//        tiffutil -cathidpicheck background.png background@2x.png -out dmg-background.tiff

let width: CGFloat = 660, height: CGFloat = 400
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat, to url: URL) {
    let pixelsWide = Int(width * scale), pixelsHigh = Int(height * scale)
    let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    // Soft paper-white gradient with a faint emerald glow at the top
    let background = NSGradient(colors: [color(0xF7F9F7), color(0xE9EFEC)])!
    background.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
    let glow = NSGradient(colors: [color(0x17A27C, 0.16), color(0x17A27C, 0)])!
    glow.draw(fromCenter: NSPoint(x: width / 2, y: height + 40), radius: 0,
              toCenter: NSPoint(x: width / 2, y: height + 40), radius: 340, options: [])

    // Title
    let title = NSAttributedString(string: "TajArchive", attributes: [
        .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: color(0x0B6B53)])
    let titleSize = title.size()
    title.draw(at: NSPoint(x: (width - titleSize.width) / 2, y: height - 62))

    // Arrow from the app (x 165) to Applications (x 495), at icon height (y = 400 - 180)
    let arrowY: CGFloat = height - 180
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 250, y: arrowY))
    path.curve(to: NSPoint(x: 400, y: arrowY), controlPoint1: NSPoint(x: 300, y: arrowY + 26),
               controlPoint2: NSPoint(x: 350, y: arrowY + 26))
    path.lineWidth = 6
    path.lineCapStyle = .round
    color(0x17A27C).setStroke()
    path.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 412, y: arrowY - 2))
    head.line(to: NSPoint(x: 388, y: arrowY + 16))
    head.line(to: NSPoint(x: 392, y: arrowY - 14))
    head.close()
    color(0x17A27C).setFill()
    head.fill()

    // Instructions, English and Russian
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let lines = NSAttributedString(string: "Drag TajArchive to the Applications folder\nПеретащите TajArchive в папку «Программы»", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color(0x3D4A45),
        .paragraphStyle: paragraph])
    lines.draw(in: NSRect(x: 40, y: 62, width: width - 80, height: 44))

    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
render(scale: 1, to: out.appendingPathComponent("background.png"))
render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
print("ok")
