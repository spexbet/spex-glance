import Foundation

/// A position change pushed by Kalshi's `market_positions` channel.
struct LivePosition: Equatable {
    var ticker: String
    /// Signed contracts: positive = YES, negative = NO. Zero means the position is gone (sold or settled).
    var contracts: Double
    var costDollars: Double?
    var realizedDollars: Double?
    var feesDollars: Double?
}

/// A resting-order change pushed by the `user_orders` channel.
struct LiveOrder: Equatable {
    var orderID: String
    var ticker: String
    /// "resting" | "canceled" | "executed"
    var status: String
    var isYes: Bool?
    var isBuy: Bool?
    var yesPriceDollars: Double?
    var remaining: Double?
    /// Kalshi's `last_update_reason`: "Trade", "Amend", "Decrease", or a "…Cancel" when the
    /// exchange cancelled it (halt, close, settlement bounds…). Absent on a cancel the user made.
    var reason: String? = nil
}

/// A resting order Kalshi cancelled on its own, kept briefly so the Orders tab can say why it vanished.
struct KalshiCancel: Identifiable, Equatable {
    var id: String
    var eventTitle: String
    var sideTitle: String
    var isYes: Bool
    var isBuy: Bool
    var reason: String
    var at: Date

    /// Plain English for the reasons Kalshi sends when *it* cancels an order. Nil for anything
    /// the user did (cancel, amend, decrease) or a fill — those need no explanation.
    static func explanation(for reason: String?) -> String? {
        switch reason {
        case "SettlementBoundsCancel": return "Cancelled by Kalshi (settlement bounds changed)"
        case "HaltCancel":             return "Cancelled by Kalshi (market halted)"
        case "CloseCancel":            return "Cancelled by Kalshi (market closed)"
        case "ExpiryCancel":           return "Expired (the order's time limit ran out)"
        case "MarginCancel":           return "Cancelled by Kalshi (margin requirements)"
        case "SelfTradeCancel":        return "Cancelled by Kalshi (would have traded against your own order)"
        case "PostOnlyCrossCancel":    return "Cancelled by Kalshi (post-only order would have crossed)"
        case "ReduceOnlyCancel":       return "Cancelled by Kalshi (reduce-only limit)"
        case let r? where r.hasSuffix("Cancel"): return "Cancelled by Kalshi"
        default: return nil
        }
    }
}

/// A market state change pushed by `market_lifecycle_v2`. Kalshi sends every market on the
/// exchange through this channel; the feed drops anything not in the watched set before it gets here.
struct LiveLifecycle: Equatable {
    var ticker: String
    /// "determined" | "settled" | "close_date_updated" | "deactivated" | "activated" | …
    var eventType: String
    var result: String?
    var closeTime: Date?
}

/// One WebSocket to Kalshi carrying four read-only channels:
///  - `ticker` for the markets we hold (prices)
///  - `market_positions` + `user_orders` for the whole account (fills, sells, settlements, new orders)
///  - `market_lifecycle_v2` for Won/Lost the moment Kalshi decides a market
/// The socket only ever sends `subscribe`. Reconnects with backoff on transport errors; a
/// rejected *price* subscription stops it (the REST poll keeps the app honest either way),
/// while a rejected secondary channel just degrades that channel back to polling.
@MainActor
final class LiveTicker {
    enum State: Equatable { case idle, connecting, live, backoff(Int), failed(String) }

    private(set) var state: State = .idle
    var onTick: ((_ ticker: String, _ yesBid: Double?, _ yesAsk: Double?, _ last: Double?, _ serverTime: Date?) -> Void)?
    var onPosition: ((LivePosition) -> Void)?
    var onOrder: ((LiveOrder) -> Void)?
    var onLifecycle: ((LiveLifecycle) -> Void)?
    var onState: ((State) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var credential: KalshiCredential?
    private var tickers: Set<String> = []
    private var nextID = 1
    /// Command id of the price subscription — the one whose rejection is fatal.
    private var tickerCommandID = 0
    private var attempts = 0
    private var generation = 0

    func start(credential: KalshiCredential, tickers: [String]) {
        let newSet = Set(tickers)
        if self.credential == credential, newSet == self.tickers, state == .live { return }
        self.credential = credential
        self.tickers = newSet
        reconnect()
    }

    /// The network just came back: drop any pending backoff and connect right away.
    func reconnectNow() {
        guard credential != nil, !tickers.isEmpty else { return }
        attempts = 0
        reconnect()
    }

    func stop() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        set(.idle)
    }

    // MARK: Internals

    private func set(_ s: State) {
        state = s
        onState?(s)
    }

    private func reconnect() {
        guard let cred = credential, !tickers.isEmpty else { stop(); return }
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        set(.connecting)

        let env = cred.environment
        var req = URLRequest(url: env.wsURL)
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        guard let sig = try? cred.sign(ts + "GET" + env.wsPath).base64EncodedString() else { set(.idle); return }
        req.setValue(cred.keyID, forHTTPHeaderField: "KALSHI-ACCESS-KEY")
        req.setValue(ts, forHTTPHeaderField: "KALSHI-ACCESS-TIMESTAMP")
        req.setValue(sig, forHTTPHeaderField: "KALSHI-ACCESS-SIGNATURE")

        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()

        // Three subscribe commands, because the market filter is per command: prices are
        // filtered to what we hold, while positions/orders/lifecycle must be unfiltered so a
        // brand-new position or order (a market we don't hold yet) still reaches us.
        tickerCommandID = nextID
        send(t, gen: gen, fatal: true, ["channels": ["ticker"], "market_tickers": Array(tickers).sorted()])
        send(t, gen: gen, fatal: false, ["channels": ["market_positions", "user_orders"]])
        send(t, gen: gen, fatal: false, ["channels": ["market_lifecycle_v2"]])
        receiveLoop(t, gen: gen)
    }

    private func send(_ t: URLSessionWebSocketTask, gen: Int, fatal: Bool, _ params: [String: Any]) {
        let cmd: [String: Any] = ["id": nextID, "cmd": "subscribe", "params": params]
        nextID += 1
        guard let data = try? JSONSerialization.data(withJSONObject: cmd),
              let str = String(data: data, encoding: .utf8) else { return }
        t.send(.string(str)) { [weak self] err in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if err != nil, fatal { self.scheduleRetry() }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                switch result {
                case .failure:
                    self.scheduleRetry()
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    else if case .data(let d) = msg, let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    self.receiveLoop(t, gen: gen)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "subscribed" || type == "ok" {
            attempts = 0
            set(.live)
            return
        }
        if type == "error" {
            // The server rejected a command (bad channel, unknown ticker, auth). Retrying the
            // same request won't help. A rejected price subscription stops the feed and shows
            // why; a rejected secondary channel quietly falls back to the REST poll.
            let msg = (obj["msg"] as? [String: Any])?["msg"] as? String
                ?? (obj["msg"] as? String) ?? "subscription rejected"
            let id = obj["id"] as? Int
            guard id == nil || id == tickerCommandID else { return }
            generation += 1
            task?.cancel(with: .normalClosure, reason: nil)
            set(.failed(msg))
            return
        }
        guard let m = obj["msg"] as? [String: Any] else { return }
        // Kalshi stamps every message with when it left their network layer.
        let serverTime = (obj["sending_ts_ms"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }

        switch type {
        case "ticker":
            guard let ticker = m["market_ticker"] as? String else { return }
            let bid = num(m, "yes_bid_dollars")
            let ask = num(m, "yes_ask_dollars")
            let last = num(m, "price_dollars")
            let stamped = serverTime ?? (m["ts_ms"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            if state != .live { attempts = 0; set(.live) }
            onTick?(ticker, bid, ask, last, stamped)

        case "market_position":
            guard let ticker = m["market_ticker"] as? String, let qty = num(m, "position_fp") else { return }
            onPosition?(LivePosition(ticker: ticker, contracts: qty,
                                     costDollars: num(m, "position_cost_dollars"),
                                     realizedDollars: num(m, "realized_pnl_dollars"),
                                     feesDollars: num(m, "fees_paid_dollars")))

        case "user_order":
            guard let id = m["order_id"] as? String, let ticker = m["ticker"] as? String,
                  let status = m["status"] as? String else { return }
            var isYes: Bool? = nil
            if let s = (m["outcome_side"] as? String ?? m["side"] as? String)?.lowercased() { isYes = s == "yes" }
            var isBuy: Bool? = nil
            if let b = (m["book_side"] as? String)?.lowercased() { isBuy = b == "bid" }
            else if let a = (m["action"] as? String)?.lowercased() { isBuy = a == "buy" }
            onOrder?(LiveOrder(orderID: id, ticker: ticker, status: status.lowercased(), isYes: isYes, isBuy: isBuy,
                               yesPriceDollars: num(m, "yes_price_dollars"),
                               remaining: num(m, "remaining_count_fp"),
                               reason: m["last_update_reason"] as? String))

        case "market_lifecycle_v2":
            // Firehose: every market on Kalshi. Only ours matter.
            guard let ticker = m["market_ticker"] as? String, tickers.contains(ticker),
                  let ev = m["event_type"] as? String else { return }
            let close = (m["close_ts"] as? Double).map { Date(timeIntervalSince1970: $0) }
            onLifecycle?(LiveLifecycle(ticker: ticker, eventType: ev, result: m["result"] as? String, closeTime: close))

        default:
            return
        }
    }

    /// Kalshi sends fixed-point dollars and contract counts as strings ("0.6300"); accept a bare number too.
    private func num(_ m: [String: Any], _ key: String) -> Double? {
        switch m[key] {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private func scheduleRetry() {
        attempts += 1
        let delay = min(60, Int(pow(2.0, Double(min(attempts, 6)))))   // 2,4,8,…,60s
        set(.backoff(delay))
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self, self.generation == gen else { return }
            self.reconnect()
        }
    }
}
