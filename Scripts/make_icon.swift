import AppKit
import CoreGraphics

// TajArchive icon: emerald squircle, cream archive box with a gold zipper,
// gold crown under an arc of seven stars (the crown and stars of Tajikistan's emblem;
// "taj" means crown). Drawn in a 1024-unit design space at any pixel size.

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func linear(_ ctx: CGContext, _ path: CGPath, _ top: CGColor, _ bottom: CGColor, _ y0: CGFloat, _ y1: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func star(center: CGPoint, outer: CGFloat, inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<10 {
        let r = i % 2 == 0 ? outer : inner
        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
        let pt = CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {
    let gold = (top: rgb(0xFFE38F), bottom: rgb(0xD69A1F))
    let goldEdge = rgb(0xA8730E)

    // Squircle with drop shadow
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x0B6B53))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, tile, rgb(0x17A27C), rgb(0x085440), 100, 924)
    // soft top highlight
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let hl = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 512, y: 980), startRadius: 0, endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])
    ctx.restoreGState()

    // Archive box body
    let body = CGPath(roundedRect: CGRect(x: 292, y: 190, width: 440, height: 300), cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x000000, 0.30))
    ctx.addPath(body); ctx.setFillColor(rgb(0xEFE4C8)); ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, body, rgb(0xFFF9EA), rgb(0xE3D5B0), 190, 490)

    // Lid
    let lid = CGPath(roundedRect: CGRect(x: 270, y: 466, width: 484, height: 100), cornerWidth: 30, cornerHeight: 30, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.25))
    ctx.addPath(lid); ctx.setFillColor(rgb(0xF7EED6)); ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, lid, rgb(0xFFFDF6), rgb(0xEADCB8), 466, 566)

    // Zipper track and teeth
    let track = CGPath(roundedRect: CGRect(x: 486, y: 206, width: 52, height: 352), cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.addPath(track); ctx.setFillColor(rgb(0xCDB98C)); ctx.fillPath()
    var y: CGFloat = 214
    var left = true
    while y < 540 {
        let tooth = CGPath(roundedRect: CGRect(x: left ? 488 : 508, y: y, width: 28, height: 13), cornerWidth: 5, cornerHeight: 5, transform: nil)
        linear(ctx, tooth, gold.top, gold.bottom, y, y + 13)
        y += 19
        left.toggle()
    }
    // Zipper pull
    let pull = CGPath(roundedRect: CGRect(x: 478, y: 404, width: 68, height: 120), cornerWidth: 22, cornerHeight: 22, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 8, color: rgb(0x000000, 0.30))
    ctx.addPath(pull); ctx.setFillColor(gold.bottom); ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, pull, gold.top, gold.bottom, 404, 524)
    ctx.addPath(pull); ctx.setStrokeColor(goldEdge); ctx.setLineWidth(4); ctx.strokePath()
    let hole = CGPath(roundedRect: CGRect(x: 497, y: 424, width: 30, height: 48), cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(hole); ctx.setFillColor(rgb(0x7A5408)); ctx.fillPath()

    // Crown
    let crown = CGMutablePath()
    crown.move(to: CGPoint(x: 410, y: 636))
    crown.addLine(to: CGPoint(x: 384, y: 760))
    crown.addLine(to: CGPoint(x: 460, y: 692))
    crown.addLine(to: CGPoint(x: 512, y: 792))
    crown.addLine(to: CGPoint(x: 564, y: 692))
    crown.addLine(to: CGPoint(x: 640, y: 760))
    crown.addLine(to: CGPoint(x: 614, y: 636))
    crown.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x000000, 0.30))
    ctx.addPath(crown); ctx.setFillColor(gold.bottom); ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, crown, gold.top, gold.bottom, 636, 792)
    ctx.addPath(crown); ctx.setStrokeColor(goldEdge); ctx.setLineWidth(5); ctx.setLineJoin(.round); ctx.strokePath()
    for tip in [CGPoint(x: 384, y: 760), CGPoint(x: 512, y: 792), CGPoint(x: 640, y: 760)] {
        let ball = CGPath(ellipseIn: CGRect(x: tip.x - 17, y: tip.y - 17, width: 34, height: 34), transform: nil)
        linear(ctx, ball, gold.top, gold.bottom, tip.y - 17, tip.y + 17)
        ctx.addPath(ball); ctx.setStrokeColor(goldEdge); ctx.setLineWidth(4); ctx.strokePath()
    }
    let band = CGPath(roundedRect: CGRect(x: 398, y: 592, width: 228, height: 52), cornerWidth: 14, cornerHeight: 14, transform: nil)
    linear(ctx, band, gold.top, gold.bottom, 592, 644)
    ctx.addPath(band); ctx.setStrokeColor(goldEdge); ctx.setLineWidth(5); ctx.strokePath()
    for x in [450.0, 512.0, 574.0] as [CGFloat] {
        let gem = CGPath(ellipseIn: CGRect(x: x - 12, y: 606, width: 24, height: 24), transform: nil)
        ctx.addPath(gem); ctx.setFillColor(rgb(0xC8102E)); ctx.fillPath()
        let shine = CGPath(ellipseIn: CGRect(x: x - 6, y: 618, width: 7, height: 6), transform: nil)
        ctx.addPath(shine); ctx.setFillColor(rgb(0xFFFFFF, 0.7)); ctx.fillPath()
    }

    // Seven stars on an arc
    let center = CGPoint(x: 512, y: 640)
    let radius: CGFloat = 228
    for i in 0..<7 {
        let angle = (165.0 - Double(i) * 25.0) * Double.pi / 180
        let c = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        let s = star(center: c, outer: 27, inner: 11)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: rgb(0x000000, 0.25))
        ctx.addPath(s); ctx.setFillColor(gold.bottom); ctx.fillPath()
        ctx.restoreGState()
        linear(ctx, s, gold.top, gold.bottom, c.y - 27, c.y + 27)
    }
}

func render(pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (name, px) in [("icon_16x16@1x", 16), ("icon_16x16@2x", 32), ("icon_32x32@1x", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128@1x", 128), ("icon_128x128@2x", 256), ("icon_256x256@1x", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512@1x", 512), ("icon_512x512@2x", 1024)] {
    render(pixels: px, to: out.appendingPathComponent(name + ".png"))
}
print("rendered")
