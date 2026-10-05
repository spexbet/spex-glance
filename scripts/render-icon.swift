#!/usr/bin/env swift
// Renders the Spex Glance app icon (paper ground, cobalt disc, cream mark) into
// App/Assets.xcassets/AppIcon.appiconset. Run from the repo root:  swift scripts/render-icon.swift
// Geometry matches docs/logo/spex-mark.svg in the Haruspex repo (64×64 space).
import AppKit

let paper  = NSColor(srgbRed: 0xF6/255, green: 0xF1/255, blue: 0xE4/255, alpha: 1)
let cobalt = NSColor(srgbRed: 0x1E/255, green: 0x5E/255, blue: 0xFF/255, alpha: 1)
let cream  = NSColor(srgbRed: 0xFF/255, green: 0xF4/255, blue: 0xD6/255, alpha: 1)

func drawMark(ox: CGFloat, oy: CGFloat, s: CGFloat, color: NSColor) {
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * s, y: oy + y * s) }
    color.setStroke(); color.setFill()
    let path = NSBezierPath()
    path.lineWidth = 6.2 * s
    path.lineCapStyle = .round; path.lineJoinStyle = .round
    path.appendOval(in: NSRect(x: ox + 8 * s, y: oy + 9 * s, width: 22 * s, height: 22 * s))
    path.appendOval(in: NSRect(x: ox + 34 * s, y: oy + 9 * s, width: 22 * s, height: 22 * s))
    path.move(to: p(31, 18)); path.curve(to: p(33, 18), controlPoint1: p(31.5, 15), controlPoint2: p(32.5, 15))
    path.move(to: p(8, 17));  path.line(to: p(4, 11))
    path.move(to: p(56, 17)); path.line(to: p(60, 11))
    path.move(to: p(12, 55)); path.line(to: p(21, 49)); path.line(to: p(27, 53)); path.line(to: p(36, 46)); path.line(to: p(44, 42))
    path.stroke()
    let head = NSBezierPath()
    head.move(to: p(53, 38)); head.line(to: p(42, 39)); head.line(to: p(47, 48)); head.close()
    head.fill()
}

/// insetFrac: transparent margin around the squircle (macOS ≈ 0.098, iOS 0). radiusFrac of the squircle side.
func render(size: Int, insetFrac: CGFloat, radiusFrac: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.setShouldAntialias(true)
    // flip so y grows downward like the SVG
    let t = NSAffineTransform(); t.translateX(by: 0, yBy: CGFloat(size)); t.scaleX(by: 1, yBy: -1); t.concat()

    let N = CGFloat(size), inset = N * insetFrac, side = N - 2 * inset
    paper.setFill()
    NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side),
                 xRadius: side * radiusFrac, yRadius: side * radiusFrac).fill()
    let r = side * 58 / 160, c = N / 2
    cobalt.setFill()
    NSBezierPath(ovalIn: NSRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r)).fill()
    let s = side * 1.22 / 160
    drawMark(ox: c - 32 * s, oy: c - 30 * s, s: s, color: cream)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = "App/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    print("wrote \(name)")
}
for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    save(render(size: pt * scale, insetFrac: 0.098, radiusFrac: 0.225), "mac-\(pt)@\(scale)x.png")
}
