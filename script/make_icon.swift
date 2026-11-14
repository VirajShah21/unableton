import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent(".cache/Unableton.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = AffineTransform(scale: factor)
        (transform as NSAffineTransform).concat()
        let rect = NSRect(x: 88, y: 88, width: 848, height: 848)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 188, yRadius: 188)
        NSGradient(starting: NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.24, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor.white.withAlphaComponent(0.14).setStroke(); shape.lineWidth = 3; shape.stroke()
        let heights: [CGFloat] = [150, 320, 500, 370, 210]
        for (i, height) in heights.enumerated() {
            let bar = NSBezierPath(roundedRect: NSRect(x: 246 + CGFloat(i) * 112, y: (1024-height)/2, width: 72, height: height), xRadius: 36, yRadius: 36)
            (i == 2 ? NSColor(calibratedRed: 1, green: 0.62, blue: 0.26, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)).setFill()
            bar.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/Unableton.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { fatalError("iconutil failed") }
