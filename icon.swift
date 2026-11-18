// Draws the app icon and writes AppIcon.icns next to this file:  swift icon.swift
// A monochrome shield, left half solid, on a graphite tile. The shape is our own path, not an SF Symbol:
// Apple's licence does not allow SF Symbols in app icons.
import AppKit

let side: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// The tile: macOS icons leave a 100 px margin and round the corners at about 22.5% of the tile.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let graphite = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 0.27, alpha: 1).cgColor, NSColor(white: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(graphite, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 183.5, cornerHeight: 183.5, transform: nil))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()

// The shield: a peak at the top centre, shoulders a little lower, straight sides, a point at the bottom.
let (cx, w, h): (CGFloat, CGFloat, CGFloat) = (side / 2, 400, 470)
let y0 = (side - h) / 2 - 6
func half(_ sign: CGFloat) -> [(CGPoint, CGPoint, CGPoint)] { // three curves from the top centre down one side to the point
    func p(_ dx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: cx + sign * dx * w / 2, y: y0 + fy * h) }
    return [(p(0.42, 0.93), p(0.74, 0.86), p(1, 0.84)), // top centre → shoulder
            (p(1, 0.70), p(1, 0.58), p(1, 0.50)), // shoulder → side
            (p(1, 0.22), p(0.42, 0.07), p(0, 0))] // side → bottom point
}
// The left side is drawn once and mirrored for the right.
let left = CGMutablePath()
left.move(to: CGPoint(x: cx, y: y0 + h))
for (a, b, end) in half(-1) { left.addCurve(to: end, control1: a, control2: b) }
let outline = CGMutablePath()
outline.addPath(left)
outline.addPath(left, transform: CGAffineTransform(translationX: 2 * cx, y: 0).scaledBy(x: -1, y: 1))

// Left half solid.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: cx, height: side))
let closed = CGMutablePath()
closed.addPath(left)
closed.addLine(to: CGPoint(x: cx, y: y0 + h))
closed.closeSubpath()
ctx.addPath(closed)
ctx.clip()
let ivory = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 0.80, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ivory, start: CGPoint(x: 0, y: y0 + h), end: CGPoint(x: 0, y: y0), options: [])
ctx.restoreGState()

// The outline of both halves.
ctx.addPath(outline)
ctx.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor)
ctx.setLineWidth(30)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
ctx.strokePath()
ctx.flush()

// 1024 px master → the sizes an .icns needs.
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("Zaslon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: side, height: side))
master.addRepresentation(rep)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: small)
    NSGraphicsContext.current!.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.current!.flushGraphics()
    try! small.representation(using: .png, properties: [:])!
        .write(to: set.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
try! rep.representation(using: .png, properties: [:])!.write(to: here.appendingPathComponent("icon.png"))
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", set.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "wrote AppIcon.icns and icon.png" : "iconutil failed")
