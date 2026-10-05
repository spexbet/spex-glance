import Foundation
import AppKit
import Network

/// How Kalshi looks from this Mac right now. Judged from Kalshi's own `GET /exchange/status`
/// plus what the app already sees: REST failures, socket drops, feed lag. No third-party
/// status site is consulted — the app still talks to nobody but Kalshi.
enum ExchangeHealth: Equatable {
    case ok
    /// Something is off but data is still flowing (a shard paused, trading halted, socket
    /// retrying, one failed refresh). The dot and icon go ember.
    case degraded(String)
    /// The exchange is halted or the API can't be reached. Red.
    case down(String)
    /// Kalshi says it's maintenance (scheduled window, or a resume time was given). Gray.
    case maintenance(until: Date?)
    /// This Mac has no network path at all. Kalshi is not to blame, so gray, not red.
    case offline
    /// The last attempt failed on this side — DNS, VPN, no route, timeout. Amber, with the
    /// plain-English reason; clears on the next good call. Not Kalshi's fault, so not "degraded".
    case localNetwork(String)
    /// Kalshi refused the key (401/403). Red: the one failure only the user can fix.
    case keyRejected(String)

    var isOK: Bool { self == .ok }
    /// Same case, ignoring the reason text: "since" resets when this changes.
    var kind: Int {
        switch self {
        case .ok: return 0; case .degraded: return 1; case .down: return 2; case .maintenance: return 3
        case .offline: return 4; case .localNetwork: return 5; case .keyRejected: return 6
        }
    }
    /// The exact line the footer shows for a local or key failure, so the window doesn't print
    /// the same reason twice (once as health, once as the refresh error).
    var detail: String? {
        switch self {
        case .localNetwork(let m), .keyRejected(let m): return m
        default: return nil
        }
    }
    /// True when Kalshi itself is the subject (worth pointing at a status page).
    var isAboutKalshi: Bool {
        switch self {
        case .degraded, .down, .maintenance: return true
        default: return false
        }
    }
    /// One line for the menu bar dropdown and the window banner.
    var summary: String {
        switch self {
        case .ok: return "Kalshi is up"
        case .degraded(let why): return "Kalshi degraded: \(why)"
        case .down(let why): return "Kalshi down: \(why)"
        case .maintenance(let until):
            if let u = until { return "Kalshi maintenance until \(Fmt.gameTime(u))" }
            return "Kalshi maintenance"
        case .offline: return "Computer network offline"
        case .localNetwork(let m): return m
        case .keyRejected(let m): return m
        }
    }
    /// Tint for the icon, the P&L text and the dot. Nil = normal menu bar colors.
    var tint: NSColor? {
        switch self {
        case .ok: return nil
        case .degraded, .localNetwork: return NSColor(red: 1.0, green: 0.54, blue: 0.24, alpha: 1)   // ember #FF8A3D
        case .down, .keyRejected: return .systemRed
        case .maintenance: return .systemGray
        case .offline: return .systemGray
        }
    }
    /// Short word for the bar when there is no P&L to show, or in Work Mode.
    var badge: String? {
        switch self {
        case .ok: return nil
        case .degraded: return "slow"
        case .down: return "down"
        case .maintenance: return "maint"
        case .offline: return "offline"
        case .localNetwork: return "network"
        case .keyRejected: return "key"
        }
    }
}

/// Polls `GET /exchange/status` once a minute (public, unauthenticated) and folds in the
/// app's own observations to produce one `ExchangeHealth`. Everything is a plain value;
/// `AppModel` owns the instance and republishes `health`.
@MainActor
final class ExchangeHealthMonitor {
    private(set) var health: ExchangeHealth = .ok { didSet { if health != oldValue { onChange?(health) } } }
    var onChange: ((ExchangeHealth) -> Void)?

    // Observations fed in by AppModel. Everything is counted in consecutive failures so a
    // single Wi-Fi blip, one slow response, or one socket drop never tints the bar.
    private var refreshFailures = 0
    private var lastRefreshError: String?
    private var socketState: LiveTicker.State = .idle
    /// The last refresh / the last status check failed on this Mac's side; each holds the
    /// plain-English reason and is cleared by the next attempt of its own kind that gets through.
    /// Kept apart so a status check that succeeds can't paper over a refresh that still fails.
    private var refreshLocal: String?
    private var statusLocal: String?
    /// Kalshi rejected the key on the last refresh.
    private var keyProblem: String?

    // Last word from Kalshi.
    private var status: ExchangeStatusResponse?
    private var statusFailures = 0
    private var lastStatusError: String?
    private var maintenanceWindows: [(Date, Date)] = []
    private var lastScheduleFetch: Date = .distantPast

    /// From NWPathMonitor. While false, nothing is polled and the verdict is .offline.
    private var online = true
    /// When the network last came back. The socket needs a moment to reconnect after that,
    /// and that moment is the Mac's, not Kalshi's.
    private var onlineSince: Date = .distantPast

    private var timer: Timer?
    private var environment: KalshiEnvironment = .prod
    /// Bumped by start/stop so a poll still in flight can't write a verdict after stop().
    private var generation = 0

    func start(environment: KalshiEnvironment) {
        self.environment = environment
        generation += 1
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        status = nil
        statusFailures = 0
        refreshFailures = 0
        refreshLocal = nil
        statusLocal = nil
        keyProblem = nil
        health = .ok
    }

    // MARK: Inputs

    /// Outcome of a full REST refresh. The verdict follows the *last attempt*, not the last
    /// success: a refresh that fails on this Mac's side turns the dot amber right away, a
    /// rejected key turns it red, and the next good refresh clears both. Only failures that
    /// are Kalshi's (5xx and the like) count toward "degraded"/"down". 429 is left to 0.4.0's
    /// backoff and never moves the dot.
    func refreshFinished(error: String?) {
        guard let e = error else {
            refreshFailures = 0
            lastRefreshError = nil
            refreshLocal = nil
            keyProblem = nil
            recompute()
            return
        }
        if KalshiError.isKeyProblem(e) {
            keyProblem = e
            refreshLocal = nil
            recompute()
        } else if KalshiError.isLocalNetwork(e) {
            refreshLocal = e
            keyProblem = nil
            recompute()
        } else if e.contains("(429)") {
            recompute()
        } else {
            refreshFailures += 1
            lastRefreshError = e
            refreshLocal = nil
            keyProblem = nil
            // A failed refresh is the moment to ask Kalshi what's going on, not a minute later.
            Task { await poll() }
        }
    }

    func socketChanged(_ s: LiveTicker.State) {
        socketState = s
        recompute()
    }

    func networkChanged(online: Bool) {
        guard online != self.online else { return }
        self.online = online
        if online {
            // Back on the network: forget failures that were only ever the Mac's fault, and give
            // DNS a few seconds before asking Kalshi anything.
            onlineSince = Date()
            refreshFailures = 0
            statusFailures = 0
            refreshLocal = nil
            statusLocal = nil
            socketState = .connecting
            health = .ok
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.online else { return }
                await self.poll()
            }
        } else {
            recompute()
        }
    }

    // MARK: Polling

    func poll() async {
        guard online else { recompute(); return }
        let gen = generation
        let client = PublicKalshiClient(environment: environment)
        do {
            let st = try await client.exchangeStatus()
            guard gen == generation else { return }
            status = st
            statusFailures = 0
            lastStatusError = nil
            statusLocal = nil
        } catch {
            guard gen == generation else { return }
            status = nil
            let msg = error.localizedDescription
            if KalshiError.isLocalNetwork(msg) {
                // Can't reach Kalshi from here (VPN, DNS…): that's this Mac's story, not Kalshi's.
                statusLocal = msg
            } else {
                statusLocal = nil
                statusFailures += 1
                lastStatusError = msg
            }
        }
        // Maintenance windows change rarely: fetch hourly, and only once something looks off.
        // The stamp is set on failure too, so a struggling API isn't hit twice a minute.
        if Date().timeIntervalSince(lastScheduleFetch) > 3600,
           status?.exchange_active == false || statusFailures > 0 || maintenanceWindows.isEmpty {
            lastScheduleFetch = Date()
            if let sched = try? await client.exchangeSchedule() {
                guard gen == generation else { return }
                maintenanceWindows = (sched.schedule?.maintenance_windows ?? []).compactMap { w in
                    guard let s = Self.date(w.start_datetime), let e = Self.date(w.end_datetime) else { return nil }
                    return (s, e)
                }
            }
        }
        guard gen == generation else { return }
        recompute()
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }

    // MARK: Verdict

    private func recompute() {
        // 0. No network path on this Mac: nothing below can be trusted, and none of it is Kalshi's doing.
        if !online { health = .offline; return }
        // 0b. Kalshi refused the key: red, and it's the user's to fix, so it outranks the rest.
        if let k = keyProblem { health = .keyRejected(k); return }
        // 0c. The last attempt couldn't get out of this Mac (DNS, VPN, no route): amber with the
        //     reason, so the dot and the footer line say the same thing.
        if let l = refreshLocal ?? statusLocal { health = .localNetwork(l); return }
        let now = Date()
        let inMaintenance = maintenanceWindows.first { $0.0 <= now && now <= $0.1 }

        // 1. Kalshi says the exchange is stopped.
        if let st = status, !st.exchange_active {
            if let w = inMaintenance { health = .maintenance(until: w.1); return }
            if let r = Self.date(st.exchange_estimated_resume_time) { health = .maintenance(until: r); return }
            health = .down("exchange halted")
            return
        }

        // Fresh off a network return, failures are still the Mac's to own for a little while.
        let settling = now.timeIntervalSince(onlineSince) < 30

        // 2. Can't reach Kalshi. During a published maintenance window that's expected.
        let socketStruggling: Bool = {
            // The first retries (2 s, 4 s) are routine; ember only once it's clearly not coming back.
            // Right after the network returns, give it 30 s before its state says anything about Kalshi.
            if settling { return false }
            if case .backoff(let d) = socketState { return d >= 8 }
            return false
        }()
        if statusFailures >= 2, !settling {
            if let w = inMaintenance { health = .maintenance(until: w.1); return }
            if refreshFailures >= 2 || socketStruggling {
                health = .down(shortError(lastStatusError ?? "")); return
            }
            health = .degraded("status check failing"); return
        }

        // 3. Exchange up, but something is impaired.
        if let st = status {
            if !st.trading_active { health = .degraded("trading paused"); return }
            if let shard = (st.exchange_index_statuses ?? []).first(where: { !$0.exchange_active || !$0.trading_active }) {
                let name = (shard.description?.isEmpty == false) ? shard.description! : "shard \(shard.exchange_index)"
                health = .degraded("\(name) paused"); return
            }
        }
        if refreshFailures >= 3, !settling { health = .down(shortError(lastRefreshError ?? "")); return }
        if refreshFailures == 2, !settling { health = .degraded("refresh failing"); return }
        if socketStruggling { health = .degraded("socket reconnecting"); return }
        // A rejected price subscription (.failed) is usually a settled ticker, not an outage; the
        // live dot already reports it. Feed lag is likewise shown by the dot and can be a fast
        // clock, so neither one changes the verdict.
        health = .ok
    }

    private func shortError(_ s: String) -> String {
        // "Kalshi returned 503: ..." → "HTTP 503"; "Network error: The request timed out." → "timed out"
        if let r = s.range(of: #"\b5\d\d\b"#, options: .regularExpression) { return "HTTP \(s[r])" }
        if s.localizedCaseInsensitiveContains("timed out") { return "timed out" }
        if s.localizedCaseInsensitiveContains("offline") || s.localizedCaseInsensitiveContains("internet") { return "no network" }
        return "API unreachable"
    }
}

/// Unauthenticated calls: exchange status and schedule need no key, so they work even when
/// the authenticated paths are the thing that's broken.
struct PublicKalshiClient {
    let environment: KalshiEnvironment

    func exchangeStatus() async throws -> ExchangeStatusResponse { try await get("/exchange/status") }
    func exchangeSchedule() async throws -> ExchangeScheduleResponse { try await get("/exchange/schedule") }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: environment.baseURL.appendingPathComponent(environment.apiPrefix + path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw KalshiError.transport(from: error) }
        guard let http = resp as? HTTPURLResponse else { throw KalshiError.transport("no HTTP response") }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw KalshiError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}


/// Watches whether this Mac has any usable network path. Fires on the main actor.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "spex.network-monitor")
    private(set) var isOnline = true

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.isOnline = online
                onChange(online)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}
