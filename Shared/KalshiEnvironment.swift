import Foundation

/// Which Kalshi exchange a credential talks to.
public enum KalshiEnvironment: String, Codable, CaseIterable, Identifiable, Sendable {
    case demo
    case prod

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .demo: return "Demo"
        case .prod: return "Production"
        }
    }

    /// Host only. Paths are always prefixed with `apiPrefix`.
    public var baseURL: URL {
        switch self {
        case .demo: return URL(string: "https://demo-api.kalshi.co")!
        case .prod: return URL(string: "https://api.elections.kalshi.com")!
        }
    }

    /// The signed path always includes this prefix, e.g. `/trade-api/v2/portfolio/positions`.
    public var apiPrefix: String { "/trade-api/v2" }

    /// WebSocket endpoint. Handshake is signed as `timestampMs + "GET" + wsPath`.
    public var wsPath: String { "/trade-api/ws/v2" }
    public var wsURL: URL {
        switch self {
        case .demo: return URL(string: "wss://external-api-ws.demo.kalshi.co" + wsPath)!
        case .prod: return URL(string: "wss://external-api-ws.kalshi.com" + wsPath)!
        }
    }

    /// Where a user creates API keys in the browser.
    public var apiKeysPageURL: URL {
        switch self {
        case .demo: return URL(string: "https://demo.kalshi.co/account/profile")!
        case .prod: return URL(string: "https://kalshi.com/account/profile")!
        }
    }

    /// Kalshi's portfolio page (the "Open Kalshi portfolio" button).
    public var portfolioURL: URL {
        switch self {
        case .demo: return URL(string: "https://demo.kalshi.co/portfolio")!
        case .prod: return URL(string: "https://kalshi.com/portfolio")!
        }
    }
}

/// Identifiers shared between the app and the widget extension.
/// Keep these in sync with project.yml and the .entitlements files.
public enum SharedIDs {
    /// Bundle-id prefix. Change this in ONE place (project.yml) and here.
    public static let bundlePrefix = "bet.spex.glance"
    /// "<TeamID>.bet.spex.glance" — the macOS form, authorized by the code signature alone. Read
    /// from Info.plist where the build substitutes $(TeamIdentifierPrefix); the fallback only
    /// matters for an unsigned build and then nothing is shared with the widget anyway.
    public static let appGroup: String = {
        if let g = Bundle.main.object(forInfoDictionaryKey: "SpexAppGroup") as? String, !g.isEmpty, !g.contains("$(") { return g }
        return "group.\(bundlePrefix)"
    }()
    public static let widgetKind = "SpexGlanceOpenBets"
}
