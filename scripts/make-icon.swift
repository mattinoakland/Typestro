// make-icon.swift
// Draws the Typestro app icon (a white text cursor with a sparkle, on an indigo-to-violet rounded
// square, the macOS icon shape) at every size macOS wants and writes Resources/AppIcon.icns.
// Run with: swift scripts/make-icon.swift
//
// Re-run this if you change the look; the .icns is checked in so normal builds don't need it.

import AppKit

let outDir = "Resources"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

/// A symbol filled with a flat color.
func tinted(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        return nil
    }
    let image = NSImage(size: symbol.size)
    image.lockFocus()
    color.set()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    image.unlockFocus()
    return image
}

func render(_ pixels: Int) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()

    let s = CGFloat(pixels)
    // macOS icons leave a transparent margin around the squircle.
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.height * 0.225)

    // Soft shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient tile.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.49, green: 0.42, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.20, blue: 0.80, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    glyphShadow.shadowBlurRadius = s * 0.03
    glyphShadow.shadowOffset = NSSize(width: 0, height: -s * 0.02)
    glyphShadow.set()

    // The text cursor, a little left of center to leave room for the sparkle.
    if let cursor = tinted("character.cursor.ibeam", pointSize: s * 0.46, weight: .semibold, color: .white) {
        let origin = NSPoint(x: s * 0.46 - cursor.size.width / 2, y: s / 2 - cursor.size.height / 2)
        cursor.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    // The sparkle, top right: the AI part.
    if let sparkle = tinted("sparkle", pointSize: s * 0.2, weight: .bold, color: .white) {
        let origin = NSPoint(x: s * 0.74 - sparkle.size.width / 2, y: s * 0.70 - sparkle.size.height / 2)
        sparkle.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    image.unlockFocus()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// Name -> pixel size, as iconutil expects.
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! render(256).write(to: URL(fileURLWithPath: "\(outDir)/AppIcon-preview.png"))

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
task.launch()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "Wrote \(outDir)/AppIcon.icns" : "iconutil failed")
