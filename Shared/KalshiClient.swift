import Foundation

public enum KalshiError: Error, LocalizedError {
    case http(Int, String)
    case transport(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg):
            switch code {
            case 401: return "Kalshi rejected the key (401). Check the Key ID and that the key is still active."
            case 403: return "Forbidden (403). The key may lack read access."
            case 429: return "Rate limited (429). Try again in a minute."
            default: return "Kalshi returned \(code): \(msg)"
            }
        case .transport(let s): return s
        case .notConnected: return "No Kalshi key on file. Open the app and tap Connect Kalshi."
        }
    }

    /// A URLSession failure in plain English. The common local causes (VPN, DNS, no route) get
    /// one line each that says where to look; anything else passes through Apple's wording.
    public static func transport(from error: Error) -> KalshiError {
        let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).code)
        let known: String? = {
            switch code {
            case .cannotFindHost, .dnsLookupFailed:
                return localDNS
            case .cannotConnectToHost:
                return "Can't connect to Kalshi — a VPN, firewall or proxy may be blocking it."
            case .notConnectedToInternet:
                return "This Mac isn't connected to the internet."
            case .timedOut:
                return "Kalshi didn't answer in time — the network may be slow, or a VPN is in the way."
            case .networkConnectionLost:
                return "The connection to Kalshi dropped. Retrying on the next refresh."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "Couldn't open a secure connection to Kalshi — a VPN or network filter may be interfering."
            case .internationalRoamingOff, .dataNotAllowed:
                return "This Mac's network doesn't allow data right now."
            default:
                return nil
            }
        }()
        return .transport(known ?? "Network error: \(error.localizedDescription)")
    }

    static let localDNS = "Can't look up Kalshi's address — check your VPN or DNS."

    /// True for failures that start on this Mac or its network (DNS, VPN, no route, timeouts),
    /// as opposed to Kalshi answering with an error. These tint the Health dot amber, not red.
    public static func isLocalNetwork(_ message: String) -> Bool {
        let local = [localDNS, "Can't connect to Kalshi", "isn't connected to the internet",
                     "didn't answer in time", "connection to Kalshi dropped",
                     "secure connection to Kalshi", "doesn't allow data", "Network error:"]
        return local.contains { message.contains($0) }
    }

    /// True when Kalshi refused the key itself (401/403) — something only the user can fix. Red.
    public static func isKeyProblem(_ message: String) -> Bool {
        message.contains("(401)") || message.contains("(403)")
    }
}

/// Minimal, read-only Kalshi Trade API v2 client. Portfolio and account requests are signed
/// with the credential's private key. Kalshi's public game data (milestones, structured targets,
/// live scoreboards — `security: []` in its OpenAPI spec) goes unsigned, so it doesn't draw on
/// the account's read-token budget. No write endpoints exist here on purpose.
public struct KalshiClient: Sendable {
    public let credential: KalshiCredential
    private let session: URLSession

    public init(credential: KalshiCredential, session: URLSession = .shared) {
        self.credential = credential
        self.session = session
    }

    // MARK: Endpoints

    public func balance() async throws -> BalanceResponse {
        try await get("/portfolio/balance")
    }

    /// The account's API usage tier and rate buckets. One call per launch, 10 read tokens.
    public func accountLimits() async throws -> AccountLimitsResponse {
        try await get("/account/limits")
    }

    /// The game record behind an event: real start time, end time, status. Prefers the milestone
    /// that lists the event as primary. Nil when Kalshi has none (futures, some leagues).
    public func milestone(forEvent ticker: String) async throws -> Milestone? {
        let r: MilestonesResponse = try await get("/milestones", query: ["related_event_ticker": ticker, "limit": "10"], signed: false)
        return r.milestones.first { ($0.primary_event_tickers ?? []).contains(ticker) } ?? r.milestones.first
    }

    /// A team or player record: name and abbreviation. Cached forever by the caller.
    public func structuredTarget(_ id: String) async throws -> StructuredTarget {
        let r: StructuredTargetResponse = try await get("/structured_targets/\(id)", signed: false)
        return r.structured_target
    }

    /// Live scoreboards for up to 100 games in one request (`milestone_ids` repeated).
    public func liveData(milestoneIDs: [String]) async throws -> [LiveDataEntry] {
        var out: [LiveDataEntry] = []
        for chunk in milestoneIDs.chunked(100) {
            let r: LiveDatasResponse = try await get("/live_data/batch", repeated: ("milestone_ids", chunk), signed: false)
            out += r.live_datas ?? []
        }
        return out
    }

    /// The account's API keys and their scopes.
    public func apiKeys() async throws -> [ApiKeyInfo] {
        let r: ApiKeysResponse = try await get("/api_keys")
        return r.api_keys
    }

    /// Verdict on whether *this* credential's key is a plain Read key.
    public enum KeyScopeCheck: Sendable, Equatable {
        /// Only "Read" is checked on Kalshi's key page.
        case readOnly
        /// Something under Granular Access is checked (Trade / Transfers / Accept block trades), or Read is missing.
        case notReadOnly(extras: [String], missingRead: Bool)
        case unknown(String)
    }
    public func checkOwnKeyScope() async -> KeyScopeCheck {
        do {
            let keys = try await apiKeys()
            guard let mine = keys.first(where: { $0.api_key_id.lowercased() == credential.keyID.lowercased() }) else {
                return .unknown("Kalshi didn't list this key ID")
            }
            if mine.isReadOnlyKey { return .readOnly }
            return .notReadOnly(extras: Array(Set(mine.disallowedScopes)).sorted(), missingRead: !mine.hasReadScope)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    /// One sentence a person can act on, for the wizard and the launch banner.
    public static func scopeProblem(extras: [String], missingRead: Bool) -> String {
        var parts: [String] = []
        if !extras.isEmpty { parts.append("has \(extras.joined(separator: ", ")) checked") }
        if missingRead { parts.append("doesn't have Read all data checked") }
        return "This key " + parts.joined(separator: " and ") + ". Spex Glance only accepts a key with Read all data checked and nothing else — on Kalshi, delete it and create a new key that way."
    }

    /// Only positions with non-zero contracts.
    public func openPositions() async throws -> [MarketPosition] {
        var all: [MarketPosition] = []
        var cursor: String? = nil
        repeat {
            var q = ["count_filter": "position", "limit": "200"]
            if let c = cursor { q["cursor"] = c }
            let page: PositionsResponse = try await get("/portfolio/positions", query: q)
            all += page.market_positions
            cursor = (page.cursor?.isEmpty == false) ? page.cursor : nil
        } while cursor != nil
        return all.filter { ($0.position_fp?.value ?? 0) != 0 }
    }

    public func restingOrders() async throws -> [Order] {
        var all: [Order] = []
        var cursor: String? = nil
        repeat {
            var q = ["status": "resting", "limit": "200"]
            if let c = cursor { q["cursor"] = c }
            let page: OrdersResponse = try await get("/portfolio/orders", query: q)
            all += page.orders
            cursor = (page.cursor?.isEmpty == false) ? page.cursor : nil
        } while cursor != nil
        return all
    }

    /// Every settlement, newest first as Kalshi returns them. `since` adds `min_ts` so an
    /// incremental refresh only pages what's new.
    public func settlements(since: Date? = nil) async throws -> [Settlement] {
        var all: [Settlement] = []
        var cursor: String? = nil
        repeat {
            var q = ["limit": "1000"]
            if let since { q["min_ts"] = String(Int(since.timeIntervalSince1970)) }
            if let c = cursor { q["cursor"] = c }
            let page: SettlementsResponse = try await get("/portfolio/settlements", query: q)
            all += page.settlements
            cursor = (page.cursor?.isEmpty == false) ? page.cursor : nil
        } while cursor != nil
        return all
    }

    /// Batch lookup. Kalshi accepts a comma-separated `tickers` filter; chunk to stay polite.
    public func markets(tickers: [String]) async throws -> [Market] {
        var out: [Market] = []
        for chunk in tickers.chunked(50) {
            let page: MarketsResponse = try await get("/markets", query: ["tickers": chunk.joined(separator: ","), "limit": "200"])
            out += page.markets
        }
        return out
    }

    public func event(_ ticker: String) async throws -> Event {
        let r: EventResponse = try await get("/events/\(ticker)")
        return r.event
    }

    public func series(_ ticker: String) async throws -> Series {
        let r: SeriesResponse = try await get("/series/\(ticker)")
        return r.series
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:],
                                   repeated: (String, [String])? = nil, signed: Bool = true) async throws -> T {
        let env = credential.environment
        let signedPath = env.apiPrefix + path            // NO query string in the signed text
        var comps = URLComponents(url: env.baseURL.appendingPathComponent(signedPath), resolvingAgainstBaseURL: false)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let (name, values) = repeated { items += values.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { comps.queryItems = items }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        if signed {
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let signature = try credential.sign(ts + "GET" + signedPath).base64EncodedString()
            req.setValue(credential.keyID, forHTTPHeaderField: "KALSHI-ACCESS-KEY")
            req.setValue(ts, forHTTPHeaderField: "KALSHI-ACCESS-TIMESTAMP")
            req.setValue(signature, forHTTPHeaderField: "KALSHI-ACCESS-SIGNATURE")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw KalshiError.transport(from: error)
        }
        guard let http = resp as? HTTPURLResponse else { throw KalshiError.transport("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = (try? JSONDecoder().decode(KalshiErrorBody.self, from: data))?.message
                ?? String(data: data, encoding: .utf8) ?? ""
            throw KalshiError.http(http.statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
