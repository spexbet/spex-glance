import SwiftUI

import AppKit

/// The Spex mark (round spectacles over a rising zig-zag arrow) knocked out of a
/// solid rounded square, the same silhouette as the app icon. Rendered as a macOS
/// template image: the tile takes the menu bar's tint and the mark shows through.
/// Geometry matches docs/logo/spex-mark.svg (1024 space; divide by 16 for the 64×64 grid).
enum MenuBarIcon {
    /// Normal: a template image, so the tile takes the menu bar's tint.
    static let image: NSImage = render(color: nil)

    /// Health tints. A colored image is not a template, so the menu bar shows the color as-is.
    private static var tinted: [String: NSImage] = [:]
    static func image(tint: NSColor?) -> NSImage {
        guard let tint else { return image }
        let key = tint.description
        if let cached = tinted[key] { return cached }
        let img = render(color: tint)
        tinted[key] = img
        return img
    }

    private static func render(color: NSColor?) -> NSImage {
        let disc: CGFloat = 18          // disc diameter, points
        let width: CGFloat = 21         // extra 3pt of air before the P&L text
        let inset: CGFloat = 2.6        // padding between disc edge and mark
        let img = NSImage(size: NSSize(width: width, height: disc), flipped: true) { _ in
            (color ?? NSColor.black).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: disc, height: disc),
                         xRadius: disc * 0.24, yRadius: disc * 0.24).fill()

            // Knock the mark out of the disc.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let s = (disc - inset * 2) / 64.0
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: inset + x * s, y: inset + y * s) }

            let stroke = NSBezierPath()
            stroke.lineWidth = 6.0 * s
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            stroke.appendOval(in: NSRect(x: inset + (19 - 11) * s, y: inset + (20 - 11) * s, width: 22 * s, height: 22 * s))
            stroke.appendOval(in: NSRect(x: inset + (45 - 11) * s, y: inset + (20 - 11) * s, width: 22 * s, height: 22 * s))
            stroke.move(to: p(31, 18))
            stroke.curve(to: p(33, 18), controlPoint1: p(31.5, 15), controlPoint2: p(32.5, 15))
            stroke.move(to: p(8, 17));  stroke.line(to: p(4, 11))
            stroke.move(to: p(56, 17)); stroke.line(to: p(60, 11))
            stroke.move(to: p(13.1, 52.29))
            stroke.line(to: p(22.88, 47.66)); stroke.line(to: p(28.23, 52.49))
            stroke.line(to: p(38.15, 46.88)); stroke.line(to: p(46.65, 44.09))
            stroke.stroke()

            let head = NSBezierPath()
            head.move(to: p(55.05, 39.7)); head.line(to: p(44.0, 39.71)); head.line(to: p(48.18, 49.12)); head.close()
            head.fill()
            return true
        }
        img.isTemplate = color == nil
        return img
    }
}
