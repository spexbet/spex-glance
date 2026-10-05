import Foundation

/// One settled market, sports only, ready to render on the Settled tab and to sum for the
/// realized P&L chart. Built from GET /portfolio/settlements; nothing here is stored beyond a
/// cache of what Kalshi already holds.
public struct SettledBet: Codable, Identifiable, Equatable, Sendable {
    public var id: String { ticker + "|" + String(Int(settledAt.timeIntervalSince1970)) }
    public var ticker: String
    public var eventTicker: String?
    /// "Chicago vs Vegas · Sep 29" when the event is known, else the ticker.
    public var gameTitle: String
    public var sport: String?
    /// "Yes · Vegas" / "No · Over 8.5 runs" — same wording as an open position.
    public var sideLabel: String
    public enum Outcome: String, Codable, Sendable { case won, lost, mixed, scalar }
    public var outcome: Outcome
    /// What Kalshi paid out (0 on a loss).
    public var revenue: Double
    /// What the contracts cost, both sides.
    public var cost: Double
    public var fee: Double
    public var settledAt: Date

    /// Profit before fees; `net(includeFees: true)` is what actually hit the balance.
    public func net(includeFees: Bool) -> Double { revenue - cost - (includeFees ? fee : 0) }
}

/// The settled-markets ledger for one Kalshi environment. Cached in the App Group so launch is
/// instant; refreshed incrementally.
public struct Ledger: Codable, Equatable, Sendable {
    public var environment: KalshiEnvironment
    public var fetchedAt: Date
    /// Newest first.
    public var items: [SettledBet]
    /// How many rows carry real names (markets/events were looked up); older rows show tickers.
    public var namedCount: Int = 0

    public var lastSettledAt: Date? { items.first?.settledAt }

    /// Cumulative realized P&L, oldest → newest, for a step chart. `from` restricts to settlements
    /// at or after that instant (the series then starts from 0 at that point).
    public func cumulative(includeFees: Bool, from: Date? = nil, sport: String? = nil) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        var total = 0.0
        for b in items.reversed() {
            if let from, b.settledAt < from { continue }
            if let sport, !sport.isEmpty, b.sport != sport { continue }
            total += b.net(includeFees: includeFees)
            out.append((b.settledAt, total))
        }
        return out
    }
}

public enum LedgerBuilder {
    /// How many of the newest settlements get real market/event names. Everything older is
    /// labelled by ticker, which keeps a years-old account to a few requests.
    public static let namedLimit = 200

    /// Full build the first time; afterwards only settlements newer than the cached ledger
    /// (with an hour of overlap, deduped) are fetched.
    public static func build(client: KalshiClient, existing: Ledger?) async throws -> Ledger {
        let env = client.credential.environment
        let prior = (existing?.environment == env) ? existing : nil
        let since = prior?.lastSettledAt.map { $0.addingTimeInterval(-3600) }
        let raw = try await client.settlements(since: since)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }

        // Sports classification: series ticker is the event ticker up to the first "-"
        // (KXNHLGAME-26OCT02ANAVGK → KXNHLGAME), looked up in the shared series cache.
        func seriesTicker(_ eventTicker: String?) -> String? {
            guard let et = eventTicker, let r = et.range(of: "-") else { return eventTicker }
            return String(et[..<r.lowerBound])
        }
        var series = MetaCache.loadSeries()
        let needed = Set(raw.compactMap { seriesTicker($0.event_ticker) })
        let missing = needed.subtracting(series.keys)
        let fetched: [(String, Series)] = try await fetchConcurrently(Array(missing), limit: 4) { try await client.series($0) }
        for (st, sr) in fetched { series[st] = SeriesMeta(isSports: sr.isSports, sport: sr.sport) }
        MetaCache.saveSeries(series)

        let sports = raw.filter { series[seriesTicker($0.event_ticker) ?? ""]?.isSports == true }

        // Names for the newest rows: markets in one batch, events via the shared cache.
        let newest = sports.sorted { (date($0.settled_time) ?? .distantPast) > (date($1.settled_time) ?? .distantPast) }
        let toName = Array(newest.prefix(namedLimit))
        let markets = toName.isEmpty ? [] : try await client.markets(tickers: toName.map(\.ticker))
        let marketByTicker = Dictionary(markets.map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })
        var events = MetaCache.loadEvents()
        let missingEvents = Set(toName.compactMap(\.event_ticker)).subtracting(events.keys)
        let fetchedEvents: [(String, Event)] = try await fetchConcurrently(Array(missingEvents), limit: 4) { try await client.event($0) }
        for (et, ev) in fetchedEvents {
            var title = ev.title ?? et
            if let d = EventTitleParser.dateTag(in: ev.sub_title) { title += " · " + d }
            events[et] = EventMeta(title: title, seriesTicker: ev.series_ticker, seenAt: Date())
        }
        MetaCache.saveEvents(events)

        let named = Set(toName.map(\.ticker))
        var fresh: [SettledBet] = []
        for st in sports {
            guard let at = date(st.settled_time) else { continue }
            let m = named.contains(st.ticker) ? marketByTicker[st.ticker] : nil
            let evTitle = st.event_ticker.flatMap { events[$0]?.title }
            let winner = EventTitleParser.isWinnerSeries(seriesTicker(st.event_ticker))
            let game = evTitle.map { EventTitleParser.split(title: $0, isWinner: winner).game } ?? m?.title ?? st.ticker
            let yesName = m?.yes_sub_title ?? st.ticker
            let outcome: SettledBet.Outcome
            switch (st.market_result ?? "").lowercased() {
            case "scalar": outcome = .scalar
            case "yes": outcome = st.heldYes && st.heldNo ? .mixed : (st.heldYes ? .won : .lost)
            case "no": outcome = st.heldYes && st.heldNo ? .mixed : (st.heldNo ? .won : .lost)
            default: outcome = .mixed
            }
            let side = st.heldYes && st.heldNo ? "Yes + No · " + yesName : (st.heldYes ? "Yes · " : "No · ") + yesName
            fresh.append(SettledBet(ticker: st.ticker, eventTicker: st.event_ticker, gameTitle: game,
                                    sport: series[seriesTicker(st.event_ticker) ?? ""]?.sport,
                                    sideLabel: side, outcome: outcome,
                                    revenue: st.revenueDollars, cost: st.costDollars, fee: st.feeDollars, settledAt: at))
        }

        // Merge with what we had: new rows win on the same id (names may have improved).
        var byID: [String: SettledBet] = [:]
        for b in prior?.items ?? [] { byID[b.id] = b }
        for b in fresh { byID[b.id] = b }
        let items = byID.values.sorted { $0.settledAt > $1.settledAt }
        return Ledger(environment: env, fetchedAt: Date(), items: items,
                      namedCount: max(prior?.namedCount ?? 0, min(items.count, namedLimit)))
    }
}

public enum LedgerCache {
    static let key = "ledger.v1"
    public static func save(_ l: Ledger) {
        if let d = try? JSONEncoder().encode(l) { SnapshotCache.defaults.set(d, forKey: key) }
    }
    public static func load() -> Ledger? {
        guard let d = SnapshotCache.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Ledger.self, from: d)
    }
    public static func clear() { SnapshotCache.defaults.removeObject(forKey: key) }
}
