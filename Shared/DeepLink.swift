import Foundation

/// spexglance:// links. The widget uses them so a tap opens (or brings forward) the one Glance
/// window, on Positions, with the tapped game expanded. Nothing here opens a browser.
public enum DeepLink: Equatable {
    case positions
    case game(String)

    public static let scheme = "spexglance"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .positions:
            c.host = "positions"
        case .game(let id):
            c.host = "game"
            c.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return c.url!
    }

    public init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host {
        case "game":
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty else { self = .positions; return }
            self = .game(id)
        default:
            self = .positions
        }
    }
}
