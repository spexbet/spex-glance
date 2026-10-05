import Foundation

/// Kalshi sends money and contract counts as fixed-point strings ("0.6300", "12.00") and a
/// few older fields as integers. `Flex` swallows string / int / double so a type change on
/// their side degrades one field instead of failing the whole decode.
public struct Flex: Codable, Equatable, Sendable {
    public var value: Double?

    public init(_ v: Double?) { value = v }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        if let i = try? c.decode(Int.self) { value = Double(i); return }
        if let s = try? c.decode(String.self) { value = Double(s); return }
        value = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - Wire types (only the fields we use; everything optional so a schema change
// degrades a field, not the whole decode). Field names verified against docs.kalshi.com, Oct 2026.

/// GET /api_keys — every key on the account with its scopes. Used to verify the key handed to
/// Spex Glance is read-only before we accept it, and again on launch.
public struct ApiKeysResponse: Codable, Sendable {
    public var api_keys: [ApiKeyInfo]
}
public struct ApiKeyInfo: Codable, Sendable {
    public var api_key_id: String
    public var name: String?
    /// "read", "write", "read::portfolio_balance", "write::trade", "write::transfer", …
    public var scopes: [String]?

    /// The only scopes a Spex Glance key may carry: Kalshi's "Read all data" box and the two
    /// read-side granular scopes it auto-includes (Portfolio balance, Read block trades).
    /// "Full access" and the write-side granular boxes — Trade, Transfers, Accept block trades —
    /// are refused, as is any scope we've never seen.
    public static let allowedScopes: Set<String> = ["read", "read::portfolio_balance", "read::block_trade_accept"]

    /// Scopes on this key that Spex Glance does not accept, in Kalshi's UI wording.
    public var disallowedScopes: [String] {
        (scopes ?? []).filter { !Self.allowedScopes.contains($0.lowercased()) }.map(Self.label)
    }
    public var hasReadScope: Bool { (scopes ?? []).contains { $0.lowercased() == "read" } }
    public var isReadOnlyKey: Bool { hasReadScope && disallowedScopes.isEmpty }

    static func label(_ scope: String) -> String {
        switch scope.lowercased() {
        case "write": return "Full access"
        case "write::trade": return "Trade"
        case "write::transfer": return "Transfers"
        case "write::block_trade_accept": return "Accept block trades"
        case "write::fcm_risk": return "FCM risk"
        default: return scope
        }
    }
}

public struct BalanceResponse: Codable, Sendable {
    /// Kalshi still returns both: `balance` in integer cents and `balance_dollars` as the exact
    /// fixed-point string (direct-member balances can carry sub-cent amounts). Prefer the string.
    public var balance: Flex?
    public var balance_dollars: Flex?
    /// Integer cents; Kalshi has no dollar-string twin for this one.
    public var portfolio_value: Flex?

    public var balanceDollars: Double? {
        balance_dollars?.value ?? balance?.value.map { $0 / 100 }
    }
    public var portfolioValueDollars: Double? {
        portfolio_value?.value.map { $0 / 100 }
    }
}

public struct MarketPosition: Codable, Sendable {
    public var ticker: String
    /// Positive = YES contracts, negative = NO contracts (fixed-point string, 2 decimals).
    public var position_fp: Flex?
    /// What the position cost in total (fixed-point dollars).
    public var market_exposure_dollars: Flex?
    public var realized_pnl_dollars: Flex?
    public var fees_paid_dollars: Flex?

    public var contractsSigned: Double { position_fp?.value ?? 0 }
    public var exposureDollars: Double { market_exposure_dollars?.value ?? 0 }
    public var realizedDollars: Double? { realized_pnl_dollars?.value }
    public var feesDollars: Double? { fees_paid_dollars?.value }
}

public struct PositionsResponse: Codable, Sendable {
    public var market_positions: [MarketPosition]
    public var cursor: String?
}

public struct Order: Codable, Sendable {
    public var order_id: String?
    public var ticker: String
    public var status: String?
    /// Canonical direction: the outcome you profit from, and the same bit in book vocabulary.
    public var outcome_side: String?  // "yes" | "no"
    public var book_side: String?     // "bid" | "ask"
    /// Deprecated by Kalshi (May 2026) but still sent; read only when the canonical pair is absent.
    public var side: String?          // "yes" | "no"
    public var action: String?        // "buy" | "sell"
    public var yes_price_dollars: Flex?
    public var no_price_dollars: Flex?
    public var remaining_count_fp: Flex?

    public var isYes: Bool { (outcome_side ?? side ?? "yes").lowercased() == "yes" }
    public var isBuy: Bool {
        if let b = book_side { return b.lowercased() == "bid" }
        return (action ?? "buy").lowercased() == "buy"
    }
    /// Contracts still resting. 0 when Kalshi omits the field rather than guessing from the initial size.
    public var remaining: Double { remaining_count_fp?.value ?? 0 }
    /// Limit price for the side of the order, in dollars.
    public var priceDollars: Double? {
        isYes ? yes_price_dollars?.value : no_price_dollars?.value
    }
}

public struct OrdersResponse: Codable, Sendable {
    public var orders: [Order]
    public var cursor: String?
}

public struct Market: Codable, Sendable {
    public var ticker: String
    public var event_ticker: String?
    public var title: String?          // deprecated by Kalshi; still sent, used only as a last-resort name
    public var yes_sub_title: String?
    public var no_sub_title: String?
    public var status: String?
    public var result: String?         // "yes" / "no" once settled, else empty ("scalar" exists, not in sports)
    /// "default" or "floor" (Kalshi, Sep 2026). A floor market can pay a NO holder something,
    /// so Won/Lost can't be computed from `result` alone. Not used by sports series today.
    public var settlement_bounds_type: String?
    public var close_time: String?
    /// Kalshi sets this to roughly game start + 3h; used to infer the start time.
    public var expected_expiration_time: String?
    public var last_price_dollars: Flex?
    public var yes_bid_dollars: Flex?
    public var yes_ask_dollars: Flex?
    /// Set on combo (multivariate / parlay) markets: the legs this contract is built from.
    public var mve_collection_ticker: String?
    public var mve_selected_legs: [MVELeg]?
    public var isCombo: Bool { !(mve_selected_legs ?? []).isEmpty }
}

public struct MVELeg: Codable, Sendable {
    public var event_ticker: String?
    public var market_ticker: String
    public var side: String?           // "yes" / "no"
}

/// `GET /milestones?related_event_ticker=…` (public). Kalshi's structured game record: the
/// scheduled start, an end once the game is over, and a provider status whose vocabulary varies
/// by sport ("not_started", "SCH", "live", "inprogress", "closed", "WOV"…).
public struct Milestone: Codable, Sendable {
    public var id: String?
    /// "football_game", "baseball_game", "tennis_tournament_singles", …
    public var type: String?
    public var title: String?
    public var start_date: String?
    public var end_date: String?
    /// When the record (and its status) was last touched. Tennis statuses can sit unchanged
    /// for hours after a match starts, so a status is only trusted while this is recent.
    public var last_updated_ts: String?
    public var details: MilestoneDetails?
    public var primary_event_tickers: [String]?
    public var related_event_tickers: [String]?
}
public struct MilestoneDetails: Codable, Sendable {
    public var status: String?
    /// Team sports: structured-target ids for each side (names via /structured_targets/{id}).
    public var home_team_id: String?
    public var away_team_id: String?
    /// Tennis: first/second competitor in title order.
    public var first_competitor_id: String?
    public var second_competitor_id: String?
}

/// `GET /structured_targets/{id}` — a team or player. Only the names are read.
public struct StructuredTargetResponse: Codable, Sendable {
    public var structured_target: StructuredTarget
}
public struct StructuredTarget: Codable, Sendable {
    public var name: String?
    public var details: StructuredTargetDetails?
}
public struct StructuredTargetDetails: Codable, Sendable {
    public var abbreviation: String?
}

/// `GET /live_data/batch` — one entry per milestone; `details` differs by sport.
public struct LiveDatasResponse: Decodable, Sendable {
    public var live_datas: [LiveDataEntry]?
}
public struct LiveDataEntry: Decodable, Sendable {
    public var type: String
    public var milestone_id: String
    public var details: [String: JSONValue]
}

/// Untyped JSON, for Kalshi's per-sport live-data shapes.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    public var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    public var double: Double? { if case .number(let n) = self { return n }; return string.flatMap(Double.init) }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
}
public struct MilestonesResponse: Codable, Sendable {
    public var milestones: [Milestone]
    public var cursor: String?
}

/// `GET /account/limits`. Only the tier name is read; rates are 0.4.0's business.
public struct AccountLimitsResponse: Codable, Sendable {
    /// basic / advanced / expert / premier / paragon / prime / prestige
    public var usage_tier: String?
}

public struct MarketsResponse: Codable, Sendable {
    public var markets: [Market]
    public var cursor: String?
}

public struct Event: Codable, Sendable {
    public var event_ticker: String
    public var title: String?
    public var sub_title: String?
    public var category: String?
    public var series_ticker: String?
}

public struct EventResponse: Codable, Sendable {
    public var event: Event
}

/// Series carry the category/tag metadata Kalshi uses for discovery.
/// Sports series look like: category "Sports", tags ["Baseball"].
/// GET /portfolio/settlements — one row per market you held when it settled.
/// Field names verified against docs.kalshi.com, Sep 30 2026.
public struct SettlementsResponse: Codable, Sendable {
    public var settlements: [Settlement]
    public var cursor: String?
}
public struct Settlement: Codable, Sendable {
    public var ticker: String
    public var event_ticker: String?
    /// "yes" | "no" | "scalar"
    public var market_result: String?
    public var yes_count_fp: Flex?
    public var yes_total_cost_dollars: Flex?
    public var no_count_fp: Flex?
    public var no_total_cost_dollars: Flex?
    /// INTEGER CENTS. The one field on this endpoint with no `_dollars` twin — divide by 100.
    public var revenue: Flex?
    /// Fixed-point dollars.
    public var fee_cost: Flex?
    public var settled_time: String?
    /// Per-contract payout in cents, nullable.
    public var value: Flex?

    public var revenueDollars: Double { (revenue?.value ?? 0) / 100 }
    public var costDollars: Double { (yes_total_cost_dollars?.value ?? 0) + (no_total_cost_dollars?.value ?? 0) }
    public var feeDollars: Double { fee_cost?.value ?? 0 }
    public var heldYes: Bool { (yes_count_fp?.value ?? 0) > 0 }
    public var heldNo: Bool { (no_count_fp?.value ?? 0) > 0 }
}

public struct Series: Codable, Sendable {
    public var ticker: String
    public var title: String?
    public var category: String?
    public var categories: [String]?
    public var tags: [String]?

    public var isSports: Bool {
        let all = ([category] + (categories ?? [])).compactMap { $0?.lowercased() }
        return all.contains("sports")
    }
    /// "Baseball", "Tennis", "Hockey"… — first tag, which is the sport for sports series.
    public var sport: String? { tags?.first }
}

public struct SeriesResponse: Codable, Sendable {
    public var series: Series
}

public struct KalshiErrorBody: Codable, Sendable {
    public var code: String?
    public var message: String?
    public var details: String?
}

// MARK: - Exchange status (public endpoints, no key needed)

/// GET /exchange/status — whether Kalshi is taking state changes and permitting trades,
/// overall and per exchange shard.
public struct ExchangeStatusResponse: Codable, Sendable {
    public var exchange_active: Bool
    public var trading_active: Bool
    /// ISO 8601; set during maintenance, "not guaranteed and can be extended".
    public var exchange_estimated_resume_time: String?
    public var exchange_index_statuses: [ExchangeIndexStatus]?
}
public struct ExchangeIndexStatus: Codable, Sendable {
    public var exchange_index: Int
    public var description: String?
    public var exchange_active: Bool
    public var trading_active: Bool
}

/// GET /exchange/schedule — only the maintenance windows are used.
public struct ExchangeScheduleResponse: Codable, Sendable {
    public var schedule: ExchangeSchedule?
}
public struct ExchangeSchedule: Codable, Sendable {
    public var maintenance_windows: [MaintenanceWindow]?
}
public struct MaintenanceWindow: Codable, Sendable {
    public var start_datetime: String
    public var end_datetime: String
}
