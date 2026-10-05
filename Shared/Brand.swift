import SwiftUI
import AppKit
import CoreText

/// Palette D4 and the Spex display face, shared by the app and the widget so both read as one
/// product. No Kalshi colors anywhere. Ember is for alerts only.
public enum Brand {
    public static let cobalt = Color(red: 0x1E / 255, green: 0x5E / 255, blue: 0xFF / 255)
    public static let cream = Color(red: 0xFF / 255, green: 0xF4 / 255, blue: 0xD6 / 255)
    public static let navy = Color(red: 0x0B / 255, green: 0x1E / 255, blue: 0x44 / 255)
    public static let ember = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x3D / 255)
    /// Paper in light mode, navy in dark mode — the window ground.
    public static let ground = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x0B / 255, green: 0x1E / 255, blue: 0x44 / 255, alpha: 1)
            : NSColor(red: 0xF6 / 255, green: 0xF1 / 255, blue: 0xE4 / 255, alpha: 1)
    })
    /// A card on the ground: a touch lighter than navy in dark mode, white-ish on paper.
    public static let card = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x14 / 255, green: 0x2C / 255, blue: 0x5C / 255, alpha: 1)
            : NSColor(red: 0xFF / 255, green: 0xFC / 255, blue: 0xF4 / 255, alpha: 1)
    })

    /// Space Grotesk (SIL OFL), bundled. The app loads it through ATSApplicationFontsPath; the
    /// widget extension registers it from its own bundle the first time it's asked for.
    public static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        registerFontsOnce
        let name = weight == .bold ? "SpaceGrotesk-Bold" : weight == .medium ? "SpaceGrotesk-Medium" : "SpaceGrotesk-Regular"
        return .custom(name, size: size)
    }

    private static let registerFontsOnce: Void = {
        for name in ["SpaceGrotesk-Regular", "SpaceGrotesk-Medium", "SpaceGrotesk-Bold"] {
            guard NSFont(name: name, size: 12) == nil,
                  let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// Kalshi API usage tier, as `GET /account/limits` names it.
public enum APIUsageTier: String, CaseIterable, Sendable {
    case basic, advanced, expert, premier, paragon, prime, prestige
    public var label: String { rawValue.capitalized }

    /// One cobalt ramp from D4: the more earned, the bolder. Basic is deliberately unstyled so
    /// it never reads as an upgrade nag. (fill, text, outline, ring) per appearance.
    public struct Style { public let fill: Color?; public let text: Color; public let outline: Color?; public let ring: Color? }
    public func style(dark: Bool) -> Style {
        func hex(_ v: UInt32) -> Color {
            Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        switch (self, dark) {
        case (.basic, _):        return Style(fill: nil, text: .secondary, outline: nil, ring: nil)
        case (.advanced, false): return Style(fill: nil, text: Brand.cobalt, outline: Brand.cobalt, ring: nil)
        case (.advanced, true):  return Style(fill: nil, text: hex(0x9DB8FF), outline: hex(0x7FA2FF), ring: nil)
        case (.expert, false):   return Style(fill: hex(0xB5C5EC), text: Brand.navy, outline: nil, ring: nil)
        case (.expert, true):    return Style(fill: hex(0x11317C), text: Brand.cream, outline: nil, ring: nil)
        case (.premier, false):  return Style(fill: hex(0x7499F4), text: Brand.navy, outline: nil, ring: nil)
        case (.premier, true):   return Style(fill: hex(0x1644B4), text: Brand.cream, outline: nil, ring: nil)
        case (.paragon, _):      return Style(fill: Brand.cobalt, text: Brand.cream, outline: nil, ring: nil)
        case (.prime, false):    return Style(fill: Brand.navy, text: Brand.cream, outline: nil, ring: nil)
        case (.prime, true):     return Style(fill: Brand.cream, text: Brand.navy, outline: nil, ring: nil)
        case (.prestige, false): return Style(fill: Brand.navy, text: Brand.cream, outline: nil, ring: Brand.cobalt)
        case (.prestige, true):  return Style(fill: Brand.cream, text: Brand.navy, outline: nil, ring: hex(0x7FA2FF))
        }
    }
}
