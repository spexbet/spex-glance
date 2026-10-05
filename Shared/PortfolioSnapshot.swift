import Foundation

/// One open bet, ready to render. Sports only — non-sports positions are counted but dropped.
public struct OpenBet: Codable, Identifiable, Equatable, Sendable {
    public var id: String { ticker }
    public var ticker: String
    public var eventTicker: String?
    /// e.g. "Dodgers vs Giants" (event title) — falls back to the market title.
    public var eventTitle: String
    /// Identifies the *game*, shared by every market type on it (winner, spread, total, period…).
    /// Kalshi event tickers are SERIES-GAMEID, e.g. KXNHLGAME-26OCT02ANAVGK / KXNHLTOTAL-26OCT02ANAVGK.
    public var gameKey: String = ""
    /// "Chicago vs Vegas · Sep 29" — the game card title (no market qualifier).
    public var gameTitle: String = ""
    /// Market qualifier for non-winner markets, e.g. "2nd Period Winner", "Team Total". Nil for the game winner.
    public var qualifier: String? = nil
    /// Kalshi's own label for the YES outcome, e.g. "Vegas", "Over 8.5 runs scored". Shown as "Yes · Vegas" / "No · Vegas".
    public var label: String = ""
    /// True for the game-winner market (series ticker ends in GAME); legs read "San Diego to win".
    public var isWinnerMarket: Bool = false
    /// e.g. "Dodgers" — the side you hold.
    public var sideTitle: String
    /// Both sides of the market, for "Dodgers 63% — Giants 37%".
    public var yesTitle: String
    public var noTitle: String
    /// e.g. "Baseball", "Tennis", "Hockey" (Kalshi series tag).
    public var sport: String?
    public var isYes: Bool
    public var contracts: Double
    public var avgCostDollars: Double
    /// Locked-in P&L on this market (netted legs, earlier closes). From Kalshi, not computed.
    public var realizedPnL: Double?
    public var feesPaid: Double?
    /// Current value of the held side (mid of bid/ask, else last trade).
    public var currentDollars: Double?
    /// Live YES-side quote. Updated by the WebSocket ticker on macOS.
    public var yesBid: Double?
    public var yesAsk: Double?
    public var yesLast: Double?
    public var marketStatus: String?
    /// "yes" / "no" once Kalshi has decided the market (it stays in your positions until paid out).
    public var result: String? = nil
    /// Kalshi's `settlement_bounds_type` ("default" / "floor"). Optional so older caches decode.
    public var settlementBoundsType: String? = nil
    public var closeTime: Date?
    /// Scheduled start of the game (from the ticker, else expected expiration − 3h). Nil if unknown.
    public var startTime: Date? = nil
    /// Where the game itself stands, from Kalshi's milestone record. Nil when unknown — then
    /// "live" falls back to the clock (started, within six hours).
    public var gamePhase: GamePhase? = nil
    /// Kalshi milestone id for the game — the key into the snapshot's live scores.
    public var milestoneID: String? = nil
    /// Non-nil for a combo (Kalshi "multivariate" / parlay) contract: the legs it is built from.
    /// A combo pays $1 per contract only if every leg hits; its own quote is the combo price.
    public var legs: [ComboLeg]? = nil
    public var isCombo: Bool { legs != nil }

    public enum Outcome: Equatable, Sendable { case pending, won, lost }
    /// Decided by Kalshi's `result`; for a combo, by its legs (any miss = lost, all hit = won).
    public var outcome: Outcome {
        switch (result ?? "").lowercased() {
        case "yes": return isYes ? .won : .lost
        case "no": return isYes ? .lost : .won
        default:
            if let legs, !legs.isEmpty {
                if legs.contains(where: { $0.outcome == .missed }) { return isYes ? .lost : .won }
                if legs.allSatisfy({ $0.outcome == .hit }) { return isYes ? .won : .lost }
            }
            return .pending
        }
    }
    /// Decided, but the payout can't be read from yes/no: a floor-bounds market, or a result
    /// other than "yes"/"no". Shown as "Settled" with no computed payout rather than a wrong
    /// Won/Lost. Never true for sports markets today; this is insurance.
    public var isSettledUnpriced: Bool {
        let r = (result ?? "").lowercased()
        guard !r.isEmpty else { return false }
        return (settlementBoundsType ?? "").lowercased() == "floor" || (r != "yes" && r != "no")
    }
    public var isFinal: Bool {
        if isSettledUnpriced { return true }
        if outcome != .pending { return true }
        // Kalshi's game record says it's over; the market just hasn't been decided yet.
        if gamePhase == .ended, !isCombo { return true }
        let s = (marketStatus ?? "").lowercased()
        return s == "closed" || s == "settled" || s == "finalized" || s == "determined"
    }

    /// Market-implied probability that YES wins, 0…1.
    /// A decided market is 0 or 1. An empty book (bid 0 / ask $1 — closed markets, most combos)
    /// falls back to the last trade, or for a combo to the product of its legs' hit probabilities.
    public var yesProbability: Double? {
        if isSettledUnpriced { return nil }
        switch (result ?? "").lowercased() {
        case "yes": return 1
        case "no": return 0
        default: break
        }
        if let b = yesBid, let a = yesAsk, a >= b, a > 0 {
            let emptyBook = b <= 0.001 && a >= 0.999
            if !emptyBook && (!isCombo || (a - b) <= 0.20) { return (a + b) / 2 }
        }
        if let legs {
            let ps = legs.compactMap(\.hitProbability)
            if ps.count == legs.count { return ps.reduce(1, *) }
        }
        return yesLast
    }
    public var favoredIsYes: Bool? {
        guard let p = yesProbability else { return nil }
        return p >= 0.5
    }
    /// "Dodgers 63% — Giants 37%"
    public var matchupLine: String {
        guard let p = yesProbability else { return "\(yesTitle) — \(noTitle)" }
        let y = Int((p * 100).rounded()), n = 100 - y
        return "\(yesTitle) \(y)% — \(noTitle) \(n)%"
    }

    /// The team/outcome you are effectively backing: YES side title if YES, NO side title if NO.
    public var backing: String { isYes ? yesTitle : noTitle }

    /// Probability that *your* side pays, 0…1.
    public var sideProbability: Double? { yesProbability.map { isYes ? $0 : 1 - $0 } }
    /// What you paid in total including fees — matches Kalshi's "Cost".
    public var costDollars: Double { contracts * avgCostDollars + (feesPaid ?? 0) }
    /// "Yes · Vegas" / "No · Over 8.5 runs scored" — the position line, Kalshi style.
    public var positionLabel: String { (isYes ? "Yes · " : "No · ") + label }

    /// Apply a live tick. Returns true if anything changed.
    @discardableResult
    public mutating func applyTick(yesBid: Double?, yesAsk: Double?, last: Double?) -> Bool {
        var changed = false
        if let v = yesBid, v != self.yesBid { self.yesBid = v; changed = true }
        if let v = yesAsk, v != self.yesAsk { self.yesAsk = v; changed = true }
        if let v = last, v != self.yesLast { self.yesLast = v; changed = true }
        if changed, let p = yesProbability {
            currentDollars = isYes ? p : 1 - p
        }
        return changed
    }

    public var unrealizedPnL: Double? {
        guard let cur = currentDollars else { return nil }
        return contracts * (cur - avgCostDollars)
    }
    /// Payout if the held side wins.
    public var maxPayout: Double { contracts * 1.0 }
    public var isLive: Bool {
        if let legs { return legs.contains { $0.isLive } }
        return OpenBet.liveHeuristic(status: marketStatus, startTime: startTime, closeTime: closeTime, phase: gamePhase)
    }
    /// Started and not yet paid out: live now, or "Final · awaiting settlement". This is what the
    /// Positions "Live" checkbox keeps. A combo counts once any leg is live, or once it's decided.
    /// Settled markets leave /portfolio/positions, so they drop off on their own.
    public var isInPlay: Bool { isLive || isFinal }
    /// Live = market still active and the game is on. Kalshi's milestone says so when it can
    /// (ended / not started / in play); otherwise the clock decides: started, and less than six
    /// hours ago so a stale market doesn't glow forever. Without a start time, "closes within 4h".
    static func liveHeuristic(status: String?, startTime: Date?, closeTime: Date?, phase: GamePhase? = nil) -> Bool {
        let s = (status ?? "").lowercased()
        guard s == "active" || s == "open" else { return false }
        switch phase {
        case .ended, .scheduled: return false
        case .live: return true
        case nil: break
        }
        if let st = startTime {
            let since = Date().timeIntervalSince(st)
            return since >= 0 && since < 6 * 3600
        }
        guard let c = closeTime, c > Date() else { return false }
        return c.timeIntervalSinceNow < 4 * 3600
    }

    /// Combo legs feed in live quotes too. Returns true if anything changed.
    @discardableResult
    public mutating func applyLegTick(ticker: String, yesBid: Double?, yesAsk: Double?, last: Double?) -> Bool {
        guard var legs, let i = legs.firstIndex(where: { $0.ticker == ticker }) else { return false }
        let changed = legs[i].applyTick(yesBid: yesBid, yesAsk: yesAsk, last: last)
        if changed {
            self.legs = legs
            if let p = yesProbability { currentDollars = isYes ? p : 1 - p }
        }
        return changed
    }
}

/// One leg of a combo: a side of an ordinary market, with its own live quote and settlement.
public struct ComboLeg: Codable, Identifiable, Equatable, Sendable {
    public var id: String { ticker }
    public var ticker: String
    public var eventTitle: String
    /// The outcome this leg needs, e.g. "Vegas" (YES) or "Chicago" (NO on "Vegas wins").
    public var sideTitle: String
    public var isYes: Bool
    public var sport: String?
    public var gameKey: String = ""
    public var gameTitle: String = ""
    /// "San Diego to win" / "No · Edmonton wins by over 1.5 goals" — Kalshi's leg wording.
    public var label: String = ""
    public var yesBid: Double?
    public var yesAsk: Double?
    public var yesLast: Double?
    public var marketStatus: String?
    /// "yes" / "no" once Kalshi settles the leg's market.
    public var result: String?
    public var closeTime: Date?
    public var startTime: Date? = nil
    public var gamePhase: GamePhase? = nil
    public var milestoneID: String? = nil

    public enum Outcome: Equatable, Sendable { case pending, hit, missed }
    public var outcome: Outcome {
        switch (result ?? "").lowercased() {
        case "yes": return isYes ? .hit : .missed
        case "no": return isYes ? .missed : .hit
        default: return .pending
        }
    }
    public var yesProbability: Double? {
        if let b = yesBid, let a = yesAsk, a >= b, a > 0, !(b <= 0.001 && a >= 0.999) { return (a + b) / 2 }
        return yesLast
    }
    /// Probability this leg hits, from the leg market's own quote.
    public var hitProbability: Double? {
        switch outcome {
        case .hit: return 1
        case .missed: return 0
        case .pending: return yesProbability.map { isYes ? $0 : 1 - $0 }
        }
    }
    public var isLive: Bool { outcome == .pending && OpenBet.liveHeuristic(status: marketStatus, startTime: startTime, closeTime: closeTime, phase: gamePhase) }

    @discardableResult
    public mutating func applyTick(yesBid: Double?, yesAsk: Double?, last: Double?) -> Bool {
        var changed = false
        if let v = yesBid, v != self.yesBid { self.yesBid = v; changed = true }
        if let v = yesAsk, v != self.yesAsk { self.yesAsk = v; changed = true }
        if let v = last, v != self.yesLast { self.yesLast = v; changed = true }
        return changed
    }
}

public struct OpenOrder: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var ticker: String
    public var eventTitle: String
    public var sideTitle: String
    public var sport: String?
    public var isYes: Bool
    public var isBuy: Bool
    public var remaining: Double
    public var limitDollars: Double?
}

/// The whole thing the widget draws. Cached in the App Group so the widget
/// still renders something when offline.
public struct PortfolioSnapshot: Codable, Equatable, Sendable {
    public var environment: KalshiEnvironment
    public var fetchedAt: Date
    public var balanceDollars: Double?
    public var portfolioValueDollars: Double?
    public var bets: [OpenBet]
    public var orders: [OpenOrder]
    /// Positions held in non-sports markets (politics, econ, …). Not shown, just counted.
    public var hiddenNonSports: Int = 0
    public var errorMessage: String?
    /// Tickers behind `hiddenNonSports`, so a live push for one of them isn't mistaken for a new bet.
    /// Optional so a snapshot cached by an older build still decodes.
    public var hiddenTickers: [String]? = nil
    /// When a live push (price, fill, settlement) last changed this snapshot; nil until one does.
    /// `fetchedAt` stays the time of the last full REST load.
    public var liveUpdatedAt: Date? = nil
    /// Teams/players per milestone id, and the latest scoreboard per milestone id. Optional so
    /// older caches decode.
    public var games: [String: GameInfo]? = nil
    public var liveScores: [String: LiveScore]? = nil
    /// The most recent of the two, for "Updated …" labels.
    public var updatedAt: Date { max(fetchedAt, liveUpdatedAt ?? .distantPast) }

    public var totalUnrealized: Double {
        bets.compactMap(\.unrealizedPnL).reduce(0, +)
    }

    /// Every market ticker whose quote matters: held markets, resting orders, and combo legs.
    public var liveTickers: [String] {
        var t = bets.map(\.ticker) + orders.map(\.ticker)
        for b in bets { t += (b.legs ?? []).map(\.ticker) }
        return Array(Set(t))
    }

    /// Route a live tick to the held market and/or any combo leg on that ticker.
    @discardableResult
    public mutating func applyTick(ticker: String, yesBid: Double?, yesAsk: Double?, last: Double?) -> Bool {
        var changed = false
        for i in bets.indices {
            if bets[i].ticker == ticker { changed = bets[i].applyTick(yesBid: yesBid, yesAsk: yesAsk, last: last) || changed }
            if bets[i].isCombo { changed = bets[i].applyLegTick(ticker: ticker, yesBid: yesBid, yesAsk: yesAsk, last: last) || changed }
        }
        return changed
    }
    /// What a pushed position change means for the snapshot.
    public enum PositionChange: Equatable, Sendable {
        /// A held market's size/cost/P&L changed in place.
        case updated
        /// The position went to zero (sold out or paid out) and was removed.
        case closed
        /// A market we don't hold — a brand-new position. Needs a full load for its metadata.
        case unknown
        /// Nothing we track changed.
        case unchanged
    }

    /// Apply a `market_positions` push. Sign flips (YES→NO) are treated as unknown so the full
    /// load rebuilds the side titles.
    @discardableResult
    public mutating func applyPosition(ticker: String, contracts signed: Double, costDollars: Double?,
                                       realized: Double?, fees: Double?) -> PositionChange {
        guard let i = bets.firstIndex(where: { $0.ticker == ticker }) else {
            // A non-sports market we already skip: only a close-out matters (the hidden count moves).
            if hiddenTickers?.contains(ticker) == true { return signed == 0 ? .unknown : .unchanged }
            return signed == 0 ? .unchanged : .unknown
        }
        if signed == 0 {
            bets.remove(at: i)
            return .closed
        }
        let isYes = signed > 0
        guard isYes == bets[i].isYes else { return .unknown }
        let qty = abs(signed)
        var changed = false
        if qty != bets[i].contracts {
            bets[i].contracts = qty
            changed = true
        }
        if let cost = costDollars, qty > 0 {
            let avg = cost / qty
            if abs(avg - bets[i].avgCostDollars) > 0.00005 { bets[i].avgCostDollars = avg; changed = true }
        }
        if let r = realized, r != bets[i].realizedPnL { bets[i].realizedPnL = r; changed = true }
        if let f = fees, f != bets[i].feesPaid { bets[i].feesPaid = f; changed = true }
        return changed ? .updated : .unchanged
    }

    /// Apply a `user_orders` push. Returns true when the order is new to us (needs a full load
    /// for its names); false when it was updated or removed in place.
    @discardableResult
    public mutating func applyOrder(id: String, ticker: String, status: String, isYes: Bool?, isBuy: Bool?,
                                    yesPrice: Double?, remaining: Double?) -> Bool {
        let gone = status != "resting" || (remaining ?? 1) <= 0
        guard let i = orders.firstIndex(where: { $0.id == id }) else {
            return !gone   // a new resting order; a dead one we never showed is nothing
        }
        if gone { orders.remove(at: i); return false }
        if let r = remaining { orders[i].remaining = r }
        if let y = isYes { orders[i].isYes = y }
        if let b = isBuy { orders[i].isBuy = b }
        if let p = yesPrice { orders[i].limitDollars = orders[i].isYes ? p : 1 - p }
        return false
    }

    /// Apply a `market_lifecycle_v2` push for a market we hold, or a leg of a combo we hold.
    /// Returns true if anything changed. "determined" carries the result before payout, which
    /// is exactly when "Final · awaiting settlement" should become Won/Lost.
    @discardableResult
    public mutating func applyLifecycle(ticker: String, eventType: String, result: String?, closeTime: Date?) -> Bool {
        var changed = false
        for i in bets.indices {
            if bets[i].ticker == ticker {
                var betChanged = false
                switch eventType {
                case "determined", "settled":
                    if let r = result, !r.isEmpty, r != bets[i].result { bets[i].result = r; betChanged = true }
                    if bets[i].marketStatus != eventType { bets[i].marketStatus = eventType; betChanged = true }
                case "close_date_updated":
                    if let c = closeTime, c != bets[i].closeTime { bets[i].closeTime = c; betChanged = true }
                case "deactivated":
                    if bets[i].marketStatus != "inactive" { bets[i].marketStatus = "inactive"; betChanged = true }
                case "activated":
                    if bets[i].marketStatus != "active" { bets[i].marketStatus = "active"; betChanged = true }
                default: break
                }
                if betChanged {
                    if let p = bets[i].yesProbability { bets[i].currentDollars = bets[i].isYes ? p : 1 - p }
                    else if bets[i].isSettledUnpriced { bets[i].currentDollars = nil }
                    changed = true
                }
            }
            guard var legs = bets[i].legs, let j = legs.firstIndex(where: { $0.ticker == ticker }) else { continue }
            var legChanged = false
            switch eventType {
            case "determined", "settled":
                if let r = result, !r.isEmpty, r != legs[j].result { legs[j].result = r; legChanged = true }
                if legs[j].marketStatus != eventType { legs[j].marketStatus = eventType; legChanged = true }
            case "close_date_updated":
                if let c = closeTime, c != legs[j].closeTime { legs[j].closeTime = c; legChanged = true }
            case "deactivated":
                if legs[j].marketStatus != "inactive" { legs[j].marketStatus = "inactive"; legChanged = true }
            case "activated":
                if legs[j].marketStatus != "active" { legs[j].marketStatus = "active"; legChanged = true }
            default: break
            }
            if legChanged {
                bets[i].legs = legs
                if let p = bets[i].yesProbability { bets[i].currentDollars = bets[i].isYes ? p : 1 - p }
                changed = true
            }
        }
        return changed
    }

    /// Every game worth a scoreboard poll: started or about to (within 15 min), not settled.
    public var scoreboardMilestones: [String] {
        var ids = Set<String>()
        let soon = Date().addingTimeInterval(15 * 60)
        func want(_ id: String?, start: Date?, final: Bool, live: Bool) {
            guard let id else { return }
            if live || final || (start.map { $0 <= soon } ?? false) { ids.insert(id) }
        }
        for b in bets {
            if let legs = b.legs {
                for l in legs { want(l.milestoneID, start: l.startTime, final: l.outcome != .pending, live: l.isLive) }
            } else {
                want(b.milestoneID, start: b.startTime, final: b.isFinal, live: b.isLive)
            }
        }
        return Array(ids)
    }

    /// Store fresh scoreboards and let them speak for the game's phase: Kalshi's live feed says
    /// pre / live / finished and, unlike the milestone status, stays current in every sport.
    /// Returns true if anything visible changed.
    @discardableResult
    public mutating func applyLiveScores(_ scores: [String: LiveScore]) -> Bool {
        guard !scores.isEmpty else { return false }
        var all = liveScores ?? [:]
        var changed = false
        for (k, v) in scores where all[k] != v { all[k] = v; changed = true }
        // Drop scoreboards for games we no longer hold.
        let held = Set(bets.compactMap(\.milestoneID) + bets.flatMap { ($0.legs ?? []).compactMap(\.milestoneID) })
        all = all.filter { held.contains($0.key) }
        liveScores = all
        for i in bets.indices {
            if let id = bets[i].milestoneID, let sc = scores[id], bets[i].gamePhase != sc.phase {
                bets[i].gamePhase = sc.phase; changed = true
            }
            if var legs = bets[i].legs {
                var legChanged = false
                for j in legs.indices {
                    if let id = legs[j].milestoneID, let sc = scores[id], legs[j].gamePhase != sc.phase {
                        legs[j].gamePhase = sc.phase; legChanged = true
                    }
                }
                if legChanged { bets[i].legs = legs; changed = true }
            }
        }
        return changed
    }

    /// Current market value of every sports position (contracts × current price of your side).
    public var totalValue: Double {
        bets.compactMap { b in b.currentDollars.map { $0 * b.contracts } }.reduce(0, +)
    }
    /// What every sports position pays if it all goes your way.
    public var totalMaxPayout: Double { bets.map(\.maxPayout).reduce(0, +) }
    /// Cash + sports positions, the way Kalshi's "Total" works but sports only.
    public var sportsTotal: Double? { balanceDollars.map { $0 + totalValue } }
    public var totalAtRisk: Double {
        bets.map { $0.contracts * $0.avgCostDollars }.reduce(0, +)
    }
    public var totalRealized: Double {
        bets.compactMap(\.realizedPnL).reduce(0, +)
    }

    /// Bets folded by event, so YES "Dodgers win" + NO "Giants win" read as one line.
    /// Computed (cheap for the handful of games anyone holds); views should read it once per render.
    public var groups: [EventGroup] {
        var order: [String] = []
        var byKey: [String: [OpenBet]] = [:]
        for b in bets {
            let k = b.isCombo ? b.ticker : (b.gameKey.isEmpty ? (b.eventTicker ?? b.ticker) : b.gameKey)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(b)
        }
        return order.map { EventGroup(id: $0, bets: byKey[$0]!) }
    }

    public static func empty(_ env: KalshiEnvironment, error: String? = nil) -> PortfolioSnapshot {
        PortfolioSnapshot(environment: env, fetchedAt: Date(), balanceDollars: nil,
                          portfolioValueDollars: nil, bets: [], orders: [], hiddenNonSports: 0, errorMessage: error)
    }
}

/// One event (a game / a match) with every market you hold in it.
public struct EventGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var bets: [OpenBet]

    /// Game card title; prefers the winner market's event title ("Game 1: Chicago C vs San Diego · Sep 29").
    public var title: String { (bets.first { $0.isWinnerMarket } ?? bets.first)?.gameTitle ?? id }
    public var sport: String? { bets.first?.sport }
    public var isCombo: Bool { bets.first?.isCombo == true }
    /// Sports touched by this group: the market's own sport, or every leg's sport for a combo.
    public var sports: Set<String> {
        if let legs = bets.first?.legs { return Set(legs.compactMap(\.sport)) }
        return Set(bets.compactMap(\.sport))
    }
    public var isLive: Bool { bets.contains { $0.isLive } }
    /// The game's milestone (not for combos, whose legs have their own).
    public var milestoneID: String? { isCombo ? nil : bets.lazy.compactMap(\.milestoneID).first }
    /// Any market in the group is live or awaiting settlement (the Live filter).
    public var isInPlay: Bool { bets.contains { $0.isInPlay } }
    /// Every market in the group is decided or closed.
    public var isFinal: Bool { bets.allSatisfy(\.isFinal) }
    public var closeTime: Date? { bets.compactMap(\.closeTime).min() }
    /// Earliest start among the group's markets (for a combo: its earliest leg).
    public var startTime: Date? {
        if let legs = bets.first?.legs { return legs.compactMap(\.startTime).min() }
        return bets.compactMap(\.startTime).min()
    }
    public var unrealized: Double? {
        let v = bets.compactMap(\.unrealizedPnL)
        return v.isEmpty ? nil : v.reduce(0, +)
    }
    public var realized: Double {
        bets.compactMap(\.realizedPnL).reduce(0, +)
    }
    public var atRisk: Double { bets.map { $0.contracts * $0.avgCostDollars }.reduce(0, +) }
    public var maxPayout: Double { bets.map(\.maxPayout).reduce(0, +) }

    /// The market whose YES side is the majority of what you're backing; drives the matchup line.
    public var primary: OpenBet {
        let byBacking = Dictionary(grouping: bets, by: \.backing)
            .mapValues { $0.map(\.contracts).reduce(0, +) }
        let top = byBacking.max { $0.value < $1.value }?.key
        return bets.first { $0.isYes && $0.yesTitle == top }
            ?? bets.first { $0.backing == top }
            ?? bets[0]
    }
    /// "Dodgers 63% — Giants 37%" from the primary market's quote.
    public var matchupLine: String { primary.matchupLine }

    /// "14 net Dodgers" or "10 Dodgers · 4 Giants" when you're on both sides across markets.
    public var netLine: String {
        if let b = bets.first, b.isCombo {
            return "\(Fmt.contracts(b.contracts)) @ \(Fmt.cents(b.avgCostDollars)) · pays \(Fmt.dollars(b.maxPayout)) if all \(b.legs?.count ?? 0) hit"
        }
        let byBacking = Dictionary(grouping: bets, by: \.backing)
            .mapValues { $0.map(\.contracts).reduce(0, +) }
            .sorted { $0.value > $1.value }
        if byBacking.count == 1, let only = byBacking.first {
            return "\(Fmt.contracts(only.value)) net \(only.key)"
        }
        return byBacking.map { "\(Fmt.contracts($0.value)) \($0.key)" }.joined(separator: " · ")
    }
    /// Backing both teams' *winner* markets in one game. A total or spread alongside a winner is not a hedge.
    public var isHedged: Bool {
        Set(bets.filter(\.isWinnerMarket).map(\.backing)).count > 1
    }
}

// MARK: - Event title parsing

/// Kalshi event titles look like "Chicago vs Vegas", "Game 1: Boston vs New York Y",
/// "Series Winner: Philadelphia vs Atlanta"; sub_titles like "CHI vs VGK (Sep 29)".
/// The NO side of a team-win market is the *same* team ("No, Vegas doesn't win"), so the
/// opponent's name has to come from the event title.
enum EventTitleParser {
    /// ("Game 1", ["Boston", "New York Y"]) for "Game 1: Boston vs New York Y"
    static func teams(in title: String) -> (prefix: String?, sides: [String]) {
        // Drop any " · Sep 28" tag we appended ourselves.
        var body = title
        if let r = body.range(of: " · ") { body = String(body[..<r.lowerBound]) }
        // The qualifier can sit on either side of the colon:
        //   "Game 1: Boston vs New York Y"   or   "Chicago vs Vegas: 2nd Period Winner"
        var prefix: String? = nil
        if let r = body.range(of: ": ") {
            let head = String(body[..<r.lowerBound]), tail = String(body[r.upperBound...])
            if tail.contains(" vs ") { prefix = head; body = tail }
            else if head.contains(" vs ") { prefix = tail; body = head }
        }
        let sides = body.components(separatedBy: " vs ").map { $0.trimmingCharacters(in: .whitespaces) }
        return (prefix, sides.count == 2 ? sides : [])
    }

    /// The side in `title` that is not `team`, matched loosely (prefix / containment, either way).
    static func opponent(of team: String, in title: String) -> String? {
        let sides = teams(in: title).sides
        guard sides.count == 2 else { return nil }
        func same(_ a: String, _ b: String) -> Bool {
            let x = a.lowercased(), y = b.lowercased()
            return x == y || x.hasPrefix(y) || y.hasPrefix(x) || x.contains(y) || y.contains(x)
        }
        if same(sides[0], team) { return sides[1] }
        if same(sides[1], team) { return sides[0] }
        return nil
    }

    /// Game key = the part of the event ticker after the series: "KXNHLTOTAL-26OCT02ANAVGK" → "26OCT02ANAVGK".
    static func gameKey(eventTicker: String?) -> String {
        guard let et = eventTicker else { return "" }
        if let r = et.range(of: "-") { return String(et[r.upperBound...]) }
        return et
    }
    static func isWinnerSeries(_ seriesTicker: String?) -> Bool {
        (seriesTicker ?? "").uppercased().hasSuffix("GAME")
    }
    /// (gameTitle, qualifier). Winner markets keep their whole title ("Game 1: A vs B · Sep 29");
    /// other market types drop the qualifier from the title and return it separately.
    static func split(title: String, isWinner: Bool) -> (game: String, qualifier: String?) {
        if isWinner { return (title, nil) }
        let (prefix, sides) = teams(in: title)
        guard sides.count == 2 else { return (title, nil) }
        var game = sides.joined(separator: " vs ")
        if let r = title.range(of: " · ") { game += String(title[r.lowerBound...]) }
        return (game, prefix)
    }

    /// Game start. Kalshi game tickers embed the date and (for some leagues) the tip-off time in
    /// US Eastern: "KXMLBGAME-26SEP301400PHIATL" → 2026-09-30 14:00 ET. When the ticker has no
    /// time, Kalshi's expected_expiration_time is consistently start + 3h.
    static func startTime(eventTicker: String?, expectedExpiration: Date?) -> Date? {
        if let et = eventTicker {
            let key = gameKey(eventTicker: et)
            let scalars = Array(key.utf8)
            // YYMMMDD[HHMM]
            if scalars.count >= 7,
               let yy = Int(String(key.prefix(2))),
               let dd = Int(String(key.dropFirst(5).prefix(2))) {
                let mon = String(key.dropFirst(2).prefix(3)).uppercased()
                let months = ["JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7, "AUG": 8, "SEP": 9, "OCT": 10, "NOV": 11, "DEC": 12]
                if let mm = months[mon], (1...31).contains(dd) {
                    let rest = String(key.dropFirst(7))
                    if rest.count >= 4, let hh = Int(String(rest.prefix(2))), let mi = Int(String(rest.dropFirst(2).prefix(2))), hh < 24, mi < 60 {
                        var c = DateComponents(); c.year = 2000 + yy; c.month = mm; c.day = dd; c.hour = hh; c.minute = mi
                        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!
                        if let d = cal.date(from: c) { return d }
                    }
                    // Dated game, no time in the ticker: Kalshi's expected expiration is start + 3h.
                    return expectedExpiration.map { $0.addingTimeInterval(-3 * 3600) }
                }
            }
        }
        // Not a dated game (series winner, futures): no start time.
        return nil
    }

    /// "Sep 29" from "CHI vs VGK (Sep 29)"; nil if there is no parenthesised tail.
    static func dateTag(in subTitle: String?) -> String? {
        guard let s = subTitle, let open = s.lastIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        return String(s[s.index(after: open)..<close])
    }
}

// MARK: - Builder

public enum SnapshotBuilder {
    /// Positions + resting orders + market/event/series metadata → one sports-only snapshot.
    public static func build(client: KalshiClient) async throws -> PortfolioSnapshot {
        async let balanceTask = client.balance()
        async let positionsTask = client.openPositions()
        async let ordersTask = client.restingOrders()

        let (balance, positions, orders) = try await (balanceTask, positionsTask, ordersTask)

        let tickers = Array(Set(positions.map(\.ticker) + orders.map(\.ticker)))
        var markets = tickers.isEmpty ? [] : try await client.markets(tickers: tickers)
        // Combo contracts point at their legs; pull those markets too so we can name, price and
        // classify each leg (a combo counts as sports when every leg is).
        let legTickers = Set(markets.flatMap { ($0.mve_selected_legs ?? []).map(\.market_ticker) })
            .subtracting(markets.map(\.ticker))
        if !legTickers.isEmpty { markets += try await client.markets(tickers: Array(legTickers)) }
        let marketByTicker = Dictionary(markets.map { ($0.ticker, $0) }, uniquingKeysWith: { a, _ in a })

        // Event → title + series, series → category + sport. Cached; only misses hit the API,
        // a few at a time. A lookup that fails is an error, not a "non-sports" position:
        // we throw so Refresher keeps the last good snapshot instead of hiding everything.
        var events = MetaCache.loadEvents()
        let missingEvents = Set(markets.compactMap(\.event_ticker)).subtracting(events.keys)
        let fetchedEvents: [(String, Event)] = try await fetchConcurrently(Array(missingEvents), limit: 4) { try await client.event($0) }
        for (et, ev) in fetchedEvents {
            // "Game 1: Boston vs New York Y · Sep 29" — the sub_title's abbreviations are redundant
            // with the title, so keep only its date tag.
            var title = ev.title ?? et
            if let d = EventTitleParser.dateTag(in: ev.sub_title) { title += " · " + d }
            events[et] = EventMeta(title: title, seriesTicker: ev.series_ticker, seenAt: Date())
        }
        MetaCache.saveEvents(events)

        var series = MetaCache.loadSeries()
        let neededSeries = Set(markets.compactMap { events[$0.event_ticker ?? ""]?.seriesTicker })
        let missingSeries = neededSeries.subtracting(series.keys)
        let fetchedSeries: [(String, Series)] = try await fetchConcurrently(Array(missingSeries), limit: 4) { try await client.series($0) }
        for (st, sr) in fetchedSeries {
            series[st] = SeriesMeta(isSports: sr.isSports, sport: sr.sport)
        }
        MetaCache.saveSeries(series)

        let iso0 = ISO8601DateFormatter()
        iso0.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain0 = ISO8601DateFormatter()
        func date0(_ s: String?) -> Date? { s.flatMap { iso0.date(from: $0) ?? isoPlain0.date(from: $0) } }

        // Game clocks: Kalshi's milestone record has the real start time (tennis tickers carry
        // only a date, and expected_expiration is not start + 3h there) plus whether the game is
        // on or over. Sports events only; cached and re-asked only around game time. A failed
        // lookup is not an error — the old clock guess stands in.
        var clocks = MetaCache.loadClocks()
        let sportsEvents = Set(markets.compactMap { m -> String? in
            guard let et = m.event_ticker, let st = events[et]?.seriesTicker, series[st]?.isSports == true else { return nil }
            return et
        })
        let staleClocks = sportsEvents.filter { clocks[$0]?.isStale() ?? true }
        let fetchedClocks: [(String, Milestone?)] = (try? await fetchConcurrently(Array(staleClocks), limit: 4) {
            try? await client.milestone(forEvent: $0)
        }) ?? []
        for (et, ms) in fetchedClocks {
            clocks[et] = GameClock(start: date0(ms?.start_date), end: date0(ms?.end_date), status: ms?.details?.status,
                                   statusAt: date0(ms?.last_updated_ts), fetchedAt: Date(), found: ms != nil,
                                   milestoneID: ms?.id, kind: ms?.type,
                                   homeID: ms?.details?.home_team_id ?? ms?.details?.first_competitor_id,
                                   awayID: ms?.details?.away_team_id ?? ms?.details?.second_competitor_id,
                                   title: ms?.title)
        }
        if !fetchedClocks.isEmpty { MetaCache.saveClocks(clocks) }
        /// Start: milestone first, then the ticker's HHMM, then expected expiration − 3h.
        func start(for m: Market?) -> Date? {
            if let et = m?.event_ticker, let c = clocks[et], let st = c.start { return st }
            return EventTitleParser.startTime(eventTicker: m?.event_ticker, expectedExpiration: date0(m?.expected_expiration_time))
        }
        func phase(for m: Market?) -> GamePhase? { m?.event_ticker.flatMap { clocks[$0]?.phase() } }
        func milestoneID(for m: Market?) -> String? { m?.event_ticker.flatMap { clocks[$0]?.milestoneID } }

        // Team names for scoreboards: one structured-target lookup per team, cached for good.
        // Tennis names come from the milestone title instead ("Alcaraz vs Munar").
        var targets = MetaCache.loadTargets()
        let usedClocks = sportsEvents.compactMap { clocks[$0] }.filter { $0.milestoneID != nil }
        let teamIDs = Set(usedClocks.filter { !($0.kind ?? "").hasPrefix("tennis") }.flatMap { [$0.homeID, $0.awayID].compactMap { $0 } })
            .subtracting(targets.keys)
        let fetchedTargets: [(String, StructuredTarget?)] = (try? await fetchConcurrently(Array(teamIDs), limit: 4) {
            try? await client.structuredTarget($0)
        }) ?? []
        for (id, t) in fetchedTargets {
            guard let t else { continue }
            targets[id] = TargetMeta(name: t.name ?? "", abbreviation: t.details?.abbreviation)
        }
        if !fetchedTargets.isEmpty { MetaCache.saveTargets(targets) }
        var games: [String: GameInfo] = [:]
        for c in usedClocks {
            guard let mid = c.milestoneID else { continue }
            var info = GameInfo(kind: c.kind ?? "", homeID: c.homeID, awayID: c.awayID)
            if (c.kind ?? "").hasPrefix("tennis"), let t = c.title, let r = t.range(of: " vs ") {
                info.home = String(t[..<r.lowerBound]); info.away = String(t[r.upperBound...])
            } else {
                func short(_ id: String?) -> String? {
                    guard let id, let t = targets[id] else { return nil }
                    return t.abbreviation?.nonEmpty ?? t.name.nonEmpty
                }
                info.home = short(c.homeID); info.away = short(c.awayID)
            }
            games[mid] = info
        }
        /// "Alcaraz vs Munar · Oct 4" → "· Oct 5" when the real start falls on another local day.
        func localDated(_ title: String, start: Date?, market m: Market?) -> String {
            guard let start, let et = m?.event_ticker, clocks[et]?.start != nil,
                  let r = title.range(of: " · ", options: .backwards) else { return title }
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return String(title[..<r.lowerBound]) + " · " + f.string(from: start)
        }

        func meta(for m: Market?) -> (title: String?, series: SeriesMeta?) {
            guard let et = m?.event_ticker, let ev = events[et] else { return (nil, nil) }
            return (ev.title, ev.seriesTicker.flatMap { series[$0] })
        }
        func seriesTicker(for m: Market?) -> String? {
            m?.event_ticker.flatMap { events[$0]?.seriesTicker }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func date(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }

        /// Names for the two sides of an ordinary market. Kalshi's no_sub_title on a team-win
        /// market repeats the same team; the real opponent comes from the event title.
        func sideNames(_ m: Market?, eventTitle: String?) -> (yes: String, no: String) {
            let yesName = m?.yes_sub_title ?? "YES"
            if let t = eventTitle, let opp = EventTitleParser.opponent(of: yesName, in: t) { return (yesName, opp) }
            if let n = m?.no_sub_title, n.lowercased() != yesName.lowercased() { return (yesName, n) }
            return (yesName, "Not " + yesName)
        }

        /// Legs of a combo market, or nil if it isn't one / a leg can't be resolved.
        /// Returns nil in `legs` when any leg is not a sports market.
        func comboLegs(_ m: Market?) -> (legs: [ComboLeg]?, allSports: Bool) {
            guard let raw = m?.mve_selected_legs, !raw.isEmpty else { return (nil, false) }
            var legs: [ComboLeg] = []
            var allSports = true
            for l in raw {
                let lm = marketByTicker[l.market_ticker]
                let (t, sm) = meta(for: lm)
                if sm?.isSports != true { allSports = false }
                let isYes = (l.side ?? "yes").lowercased() != "no"
                let names = sideNames(lm, eventTitle: t)
                let winner = EventTitleParser.isWinnerSeries(seriesTicker(for: lm))
                let (gameTitle, _) = EventTitleParser.split(title: t ?? lm?.title ?? l.market_ticker, isWinner: winner)
                let yesLabel = winner ? "\(names.yes) to win" : names.yes
                var leg = ComboLeg(ticker: l.market_ticker, eventTitle: t ?? lm?.title ?? l.market_ticker,
                                   sideTitle: isYes ? names.yes : names.no, isYes: isYes, sport: sm?.sport,
                                   gameKey: EventTitleParser.gameKey(eventTicker: lm?.event_ticker),
                                   gameTitle: localDated(gameTitle, start: start(for: lm), market: lm),
                                   label: isYes ? yesLabel : "No · " + yesLabel,
                                   yesBid: nil, yesAsk: nil, yesLast: nil,
                                   marketStatus: lm?.status, result: lm?.result, closeTime: date(lm?.close_time),
                                   startTime: start(for: lm), gamePhase: phase(for: lm), milestoneID: milestoneID(for: lm))
                leg.applyTick(yesBid: lm?.yes_bid_dollars?.value, yesAsk: lm?.yes_ask_dollars?.value, last: lm?.last_price_dollars?.value)
                legs.append(leg)
            }
            return (legs, allSports)
        }

        var bets: [OpenBet] = []
        var hidden = 0
        var hiddenTickers: [String] = []
        for p in positions {
            let qty = p.contractsSigned
            let contracts = abs(qty)
            guard contracts > 0 else { continue }
            let m = marketByTicker[p.ticker]
            let (evTitle, sm) = meta(for: m)
            let isYes = qty > 0
            let avg = p.exposureDollars / contracts

            let combo = comboLegs(m)
            if let legs = combo.legs {
                guard combo.allSports else { hidden += 1; hiddenTickers.append(p.ticker); continue }
                let sports = Set(legs.compactMap(\.sport))
                var bet = OpenBet(
                    ticker: p.ticker, eventTicker: m?.event_ticker,
                    eventTitle: legs.map(\.sideTitle).joined(separator: " + "),
                    gameKey: p.ticker, gameTitle: "\(legs.count) market combo", label: "Combo",
                    sideTitle: isYes ? "Combo hits" : "Combo misses",
                    yesTitle: "Combo hits", noTitle: "Combo misses",
                    sport: sports.count == 1 ? sports.first : nil, isYes: isYes, contracts: contracts,
                    avgCostDollars: avg,
                    realizedPnL: p.realizedDollars, feesPaid: p.feesDollars,
                    currentDollars: nil, yesBid: nil, yesAsk: nil, yesLast: nil,
                    marketStatus: m?.status, result: m?.result, settlementBoundsType: m?.settlement_bounds_type, closeTime: date(m?.close_time),
                    startTime: legs.compactMap(\.startTime).min(), legs: legs)
                bet.applyTick(yesBid: m?.yes_bid_dollars?.value, yesAsk: m?.yes_ask_dollars?.value,
                              last: m?.last_price_dollars?.value)
                if bet.currentDollars == nil, let p = bet.yesProbability { bet.currentDollars = isYes ? p : 1 - p }
                bets.append(bet)
                continue
            }
            guard sm?.isSports == true else { hidden += 1; hiddenTickers.append(p.ticker); continue }

            let (yesName, noName) = sideNames(m, eventTitle: evTitle)
            let winner = EventTitleParser.isWinnerSeries(seriesTicker(for: m))
            let (gameTitle, qualifier) = EventTitleParser.split(title: evTitle ?? m?.title ?? p.ticker, isWinner: winner)
            var bet = OpenBet(
                ticker: p.ticker, eventTicker: m?.event_ticker,
                eventTitle: evTitle ?? m?.title ?? p.ticker,
                gameKey: EventTitleParser.gameKey(eventTicker: m?.event_ticker),
                gameTitle: localDated(gameTitle, start: start(for: m), market: m),
                qualifier: qualifier, label: yesName, isWinnerMarket: winner,
                sideTitle: isYes ? yesName : noName,
                yesTitle: yesName, noTitle: noName,
                sport: sm?.sport, isYes: isYes, contracts: contracts,
                avgCostDollars: avg,
                realizedPnL: p.realizedDollars, feesPaid: p.feesDollars,
                currentDollars: nil, yesBid: nil, yesAsk: nil, yesLast: nil,
                marketStatus: m?.status, result: m?.result, settlementBoundsType: m?.settlement_bounds_type, closeTime: date(m?.close_time),
                startTime: start(for: m), gamePhase: phase(for: m), milestoneID: milestoneID(for: m))
            bet.applyTick(yesBid: m?.yes_bid_dollars?.value, yesAsk: m?.yes_ask_dollars?.value,
                          last: m?.last_price_dollars?.value)
            if bet.currentDollars == nil, let p = bet.yesProbability { bet.currentDollars = isYes ? p : 1 - p }
            bets.append(bet)
        }
        // Live games first, then soonest close.
        bets.sort {
            if $0.isLive != $1.isLive { return $0.isLive }
            return ($0.startTime ?? $0.closeTime ?? .distantFuture) < ($1.startTime ?? $1.closeTime ?? .distantFuture)
        }

        let openOrders: [OpenOrder] = orders.compactMap { o in
            let m = marketByTicker[o.ticker]
            let (evTitle, sm) = meta(for: m)
            let combo = comboLegs(m)
            if let legs = combo.legs {
                guard combo.allSports else { return nil }
                let sports = Set(legs.compactMap(\.sport))
                return OpenOrder(id: o.order_id ?? UUID().uuidString, ticker: o.ticker,
                                 eventTitle: "Combo: " + legs.map(\.sideTitle).joined(separator: " + "),
                                 sideTitle: o.isYes ? "Combo hits" : "Combo misses",
                                 sport: sports.count == 1 ? sports.first : nil, isYes: o.isYes, isBuy: o.isBuy,
                                 remaining: o.remaining, limitDollars: o.priceDollars)
            }
            guard sm?.isSports == true else { return nil }
            let (yesName, noName) = sideNames(m, eventTitle: evTitle)
            return OpenOrder(id: o.order_id ?? UUID().uuidString, ticker: o.ticker,
                             eventTitle: evTitle ?? m?.title ?? o.ticker,
                             sideTitle: o.isYes ? yesName : noName,
                             sport: sm?.sport, isYes: o.isYes, isBuy: o.isBuy,
                             remaining: o.remaining, limitDollars: o.priceDollars)
        }

        return PortfolioSnapshot(
            environment: client.credential.environment, fetchedAt: Date(),
            balanceDollars: balance.balanceDollars,
            portfolioValueDollars: balance.portfolioValueDollars,
            bets: bets, orders: openOrders, hiddenNonSports: hidden, errorMessage: nil,
            hiddenTickers: hiddenTickers, games: games)
    }
}

/// Run `op` over `items` with at most `limit` in flight. Any failure fails the whole batch.
func fetchConcurrently<T: Sendable>(_ items: [String], limit: Int,
                                            _ op: @escaping @Sendable (String) async throws -> T) async throws -> [(String, T)] {
    try await withThrowingTaskGroup(of: (String, T).self) { group in
        var out: [(String, T)] = []
        var it = items.makeIterator()
        var inFlight = 0
        func enqueue() {
            if let next = it.next() { group.addTask { (next, try await op(next)) }; inFlight += 1 }
        }
        for _ in 0 ..< limit { enqueue() }
        while inFlight > 0 {
            guard let r = try await group.next() else { break }
            inFlight -= 1
            out.append(r)
            enqueue()
        }
        return out
    }
}

// MARK: - App Group caches

/// The game's own state, independent of the market's.
public enum GamePhase: String, Codable, Sendable {
    case scheduled, live, ended

    /// Kalshi's milestone status words differ by data provider. Only map the unambiguous ones;
    /// anything else returns nil and the clock decides. An end date always means it's over.
    static func from(status: String?, end: Date?) -> GamePhase? {
        if end != nil { return .ended }
        let s = (status ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // Cricket's provider writes sentences: "Match in Progress - Ball in Progress (Bet Delay…)",
        // "Match Complete - Bhutan have won by 27 runs".
        if s.hasPrefix("match in progress") { return .live }
        if s.hasPrefix("match complete") || s.hasPrefix("match abandoned") { return .ended }
        switch s {
        case "not_started", "notstarted", "scheduled", "sch", "created", "pregame", "pre-game",
             "postponed", "pp", "delayed", "suspended_before_start":
            return .scheduled
        case "live", "inprogress", "in_progress", "in progress", "halftime", "intermission":
            return .live
        case "closed", "ended", "finished", "final", "complete", "completed", "wov", "walkover",
             "retired", "cancelled", "canceled", "abandoned":
            return .ended
        default:
            return nil
        }
    }
}

/// Cached milestone facts for one event ticker.
struct GameClock: Codable {
    var start: Date?
    var end: Date?
    var status: String?
    /// Milestone's last_updated_ts. Optional so older caches decode.
    var statusAt: Date? = nil
    var fetchedAt: Date
    /// False when Kalshi has no milestone for the event (futures, some leagues).
    var found: Bool
    /// For scoreboards. Optional so older caches decode.
    var milestoneID: String? = nil
    var kind: String? = nil
    var homeID: String? = nil
    var awayID: String? = nil
    var title: String? = nil

    /// An end date always counts. A status word counts only while Kalshi touched the record in
    /// the last 15 minutes: baseball/basketball/football statuses are kept current, tennis ones
    /// often aren't ("not_started" for hours into a match). Stale → nil → the clock decides.
    func phase(now: Date = Date()) -> GamePhase? {
        guard found else { return nil }
        if end != nil { return .ended }
        guard let at = statusAt, now.timeIntervalSince(at) < 15 * 60 else { return nil }
        return GamePhase.from(status: status, end: nil)
    }

    /// Start times move and statuses change; re-ask only where it matters. Around and after the
    /// start: every 4 minutes until the game ends (about one 5-minute refresh). Days out or
    /// not found: every 6 hours. Ended: never.
    func isStale(now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        if found && milestoneID == nil { return true }   // cached by an older build
        if !found { return age > 6 * 3600 }
        if end != nil || phase(now: now) == .ended { return false }
        guard let start else { return age > 6 * 3600 }
        if now < start.addingTimeInterval(-30 * 60) { return age > 6 * 3600 }
        return age > 4 * 60
    }
}

/// A team's display names, from /structured_targets/{id}.
struct TargetMeta: Codable { var name: String; var abbreviation: String? }

struct EventMeta: Codable {
    var title: String
    var seriesTicker: String?
    var seenAt: Date? = nil   // for eviction; older entries go first
}
struct SeriesMeta: Codable { var isSports: Bool; var sport: String? }

public enum SnapshotCache {
    static var defaults: UserDefaults { UserDefaults(suiteName: SharedIDs.appGroup) ?? .standard }
    static let key = "portfolioSnapshot"

    public static func save(_ s: PortfolioSnapshot) {
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: key) }
    }
    public static func load() -> PortfolioSnapshot? {
        guard let d = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PortfolioSnapshot.self, from: d)
    }
    public static func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: MetaCache.eventsKey)
        LedgerCache.clear()
        // series cache is account-independent; keep it
    }
}

enum MetaCache {
    static let eventsKey = "eventMeta.v2"
    static let seriesKey = "seriesMeta"

    static func loadEvents() -> [String: EventMeta] { load(eventsKey) }
    static func saveEvents(_ d: [String: EventMeta]) {
        // Events roll over constantly in sports; keep the 300 most recently seen.
        var kept = d
        if kept.count > 500 {
            let sorted = kept.sorted { ($0.value.seenAt ?? .distantPast) > ($1.value.seenAt ?? .distantPast) }
            kept = Dictionary(uniqueKeysWithValues: sorted.prefix(300).map { ($0.key, $0.value) })
        }
        save(kept, eventsKey)
    }
    static let targetsKey = "targets.v1"
    static func loadTargets() -> [String: TargetMeta] { load(targetsKey) }
    static func saveTargets(_ d: [String: TargetMeta]) { save(d, targetsKey) }
    static let clocksKey = "gameClocks.v1"
    static func loadClocks() -> [String: GameClock] { load(clocksKey) }
    static func saveClocks(_ d: [String: GameClock]) {
        var kept = d
        if kept.count > 400 {
            let sorted = kept.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
            kept = Dictionary(uniqueKeysWithValues: sorted.prefix(300).map { ($0.key, $0.value) })
        }
        save(kept, clocksKey)
    }
    static func loadSeries() -> [String: SeriesMeta] { load(seriesKey) }
    static func saveSeries(_ d: [String: SeriesMeta]) { save(d, seriesKey) }

    private static func load<T: Decodable>(_ key: String) -> [String: T] {
        guard let d = SnapshotCache.defaults.data(forKey: key),
              let v = try? JSONDecoder().decode([String: T].self, from: d) else { return [:] }
        return v
    }
    private static func save<T: Encodable>(_ v: [String: T], _ key: String) {
        if let d = try? JSONEncoder().encode(v) { SnapshotCache.defaults.set(d, forKey: key) }
    }
}

// MARK: - One-call refresh used by both app and widget

public enum Refresher {
    public static func refresh() async -> PortfolioSnapshot {
        guard let cred = KeychainStore.load() else {
            return .empty(.prod, error: KalshiError.notConnected.localizedDescription)
        }
        do {
            let snap = try await SnapshotBuilder.build(client: KalshiClient(credential: cred))
            SnapshotCache.save(snap)
            return snap
        } catch {
            // Keep the last good data on screen, annotate the error.
            var stale = SnapshotCache.load() ?? .empty(cred.environment)
            stale.errorMessage = error.localizedDescription
            return stale
        }
    }
}
