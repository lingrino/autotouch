// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// A squircle with a teal → deep blue gradient and three white fingertips over a left-right
// arrow: a three-finger swipe. Drawn with paths: SF Symbols may not be used in app icons.
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius, centered.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(srgbRed: 0.06, green: 0.22, blue: 0.55, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.68, blue: 0.72, alpha: 1)])!.draw(in: path, angle: 70)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    // Fingertips: the middle one a little higher, like a hand's.
    let r = s * 0.075
    for (dx, dy) in [(-0.19, 0.07), (0.0, 0.11), (0.19, 0.07)] as [(CGFloat, CGFloat)] {
        let c = NSPoint(x: body.midX + dx * s, y: body.midY + dy * s)
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    // A double-headed arrow underneath.
    let y = body.midY - 0.14 * s, left = body.midX - 0.27 * s, right = body.midX + 0.27 * s, h = 0.075 * s
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: left + h, y: y + h)); arrow.line(to: NSPoint(x: left, y: y)); arrow.line(to: NSPoint(x: left + h, y: y - h))
    arrow.move(to: NSPoint(x: left, y: y)); arrow.line(to: NSPoint(x: right, y: y))
    arrow.move(to: NSPoint(x: right - h, y: y + h)); arrow.line(to: NSPoint(x: right, y: y)); arrow.line(to: NSPoint(x: right - h, y: y - h))
    arrow.lineWidth = 0.05 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")
