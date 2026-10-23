// Draws the AUDAX app icon (voice bars on an indigo-violet tile) and writes AppIcon.icns.
// Run once: swift make-icon.swift  (needs iconutil, part of macOS). Original artwork:
// no SF Symbols, which Apple does not license for app icons.
import Cocoa

func render(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the tile is 824/1024 of the canvas, centred, with a soft shadow.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225,
                             yRadius: tile.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.17, green: 0.20, blue: 0.86, alpha: 1),
                        NSColor(red: 0.47, green: 0.22, blue: 0.93, alpha: 1),
                        NSColor(red: 0.78, green: 0.25, blue: 0.86, alpha: 1)])?
        .draw(in: shape, angle: -45)
    drawBars(in: tile)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func drawBars(in tile: NSRect) {
    let heights: [CGFloat] = [0.30, 0.56, 0.84, 0.62, 0.36]  // a voice, not a flat equaliser
    let barWidth = tile.width * 0.085, gap = tile.width * 0.055
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let height = tile.height * 0.62 * h
        let bar = NSRect(x: x, y: tile.midY - height / 2, width: barWidth, height: height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let png = render(size: base * scale) else { fatalError("render failed") }
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote AppIcon.icns" : "iconutil failed")
