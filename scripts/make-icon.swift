// Draws the DBIDE app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // macOS icon grid: 824pt body inset 100pt, corner radius ~185pt.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(red: 0.16, green: 0.45, blue: 0.98, alpha: 1).cgColor,
                 NSColor(red: 0.33, green: 0.20, blue: 0.80, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924 * s), end: CGPoint(x: 1024 * s, y: 100 * s), options: [])

    // Database cylinder: three stacked discs.
    let cx = 512 * s, w = 440 * s, h = 120 * s
    let white = NSColor.white
    for (i, y) in [330.0, 480.0, 630.0].enumerated() {
        let top = CGFloat(y) * s
        let segH = 120 * s
        // Side band
        ctx.setFillColor(white.withAlphaComponent(i == 2 ? 1 : 0.92).cgColor)
        ctx.fill(CGRect(x: cx - w / 2, y: top, width: w, height: segH))
        ctx.fillEllipse(in: CGRect(x: cx - w / 2, y: top - h / 2, width: w, height: h))
        // Top ellipse of each segment (darker rim separates the discs)
        ctx.setFillColor(NSColor(red: 0.30, green: 0.42, blue: 0.95, alpha: 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - w / 2, y: top + segH - h / 2, width: w, height: h))
        ctx.setFillColor(white.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - w / 2 + 6 * s, y: top + segH - h / 2 + 6 * s, width: w - 12 * s, height: h - 12 * s))
    }
    // Prompt chevron on the front disc, hinting "query".
    ctx.setStrokeColor(NSColor(red: 0.22, green: 0.33, blue: 0.90, alpha: 1).cgColor)
    ctx.setLineWidth(26 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 430 * s, y: 420 * s))
    ctx.addLine(to: CGPoint(x: 480 * s, y: 390 * s))
    ctx.addLine(to: CGPoint(x: 430 * s, y: 360 * s))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 510 * s, y: 360 * s))
    ctx.addLine(to: CGPoint(x: 590 * s, y: 360 * s))
    ctx.strokePath()
    img.unlockFocus()
    return img
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        render(px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
