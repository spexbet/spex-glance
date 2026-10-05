import SwiftUI
import AppKit
import WidgetKit

@main
struct SpexGlanceApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(Prefs.appearanceKey, store: Prefs.defaults) private var appearance: Prefs.Appearance = .system
    @AppStorage(Prefs.menuBarShowPnLKey, store: Prefs.defaults) private var menuBarShowPnL = true
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false

    var body: some Scene {
        // One window, ever. A widget tap or the menu bar's "Open" brings this window forward; it
        // never spawns a second one (WindowGroup did, on every widget tap).
        Window("Spex Glance", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(appearance.scheme)
                .task { await model.refresh() }
                .frame(minWidth: 560, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)   // ContentView draws its own centered title row
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheck)
            }
            // View menu: ⌘1–⌘4 jump to a section, ⌘⇧[ / ⌘⇧] cycle. P&L is unavailable in Work Mode.
            CommandGroup(after: .sidebar) {
                ForEach(Prefs.MainTab.allCases) { tab in
                    Button(tab.label) { model.selectTab(tab) }
                        .keyboardShortcut(KeyEquivalent(tab.shortcutKey), modifiers: .command)
                        .disabled(tab == .pnl && workMode)
                }
                Divider()
                Button("Next Section") { model.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Section") { model.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
            }
            CommandMenu("Positions") {
                Button("Expand / Collapse All") { model.toggleExpandAll() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                // ⌘⇧M (plain ⌘M is macOS Minimize): same switch as Settings → Menu bar → Work Mode.
                // Hides the menu bar icon, the "$" sign, the money tiles and the bottom buttons.
                Toggle("Work Mode", isOn: $workMode)
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView().preferredColorScheme(appearance.scheme)
        }

        // Live menu bar item: net P&L in the bar, live percentages in the dropdown.
        MenuBarExtra {
            MenuBarView().environmentObject(model).preferredColorScheme(appearance.scheme)
        } label: {
            // Health tints everything in the bar: ember when degraded, red when down, gray in
            // maintenance. Text color survives the menu bar only as an attributed string.
            let tint = model.health.tint
            if workMode {
                // Work Mode: no logo, no "$" — a bare signed number, or a neutral dot.
                if menuBarShowPnL, let n = model.menuBarNumber { Text(MenuBarText.attributed(n, tint: tint)) }
                else if let b = model.health.badge { Text(MenuBarText.attributed(b, tint: tint)) }
                else { Image(systemName: "circle.dotted") }
            } else if menuBarShowPnL {
                Label {
                    Text(MenuBarText.attributed(model.menuBarTitle, tint: tint))
                } icon: {
                    Image(nsImage: MenuBarIcon.image(tint: tint))
                }
                .labelStyle(.titleAndIcon)
            } else if let b = model.health.badge {
                Label {
                    Text(MenuBarText.attributed(b, tint: tint))
                } icon: {
                    Image(nsImage: MenuBarIcon.image(tint: tint))
                }
                .labelStyle(.titleAndIcon)
            } else {
                Image(nsImage: MenuBarIcon.image(tint: tint))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var credential: KalshiCredential? = KeychainStore.load()
    @Published var snapshot: PortfolioSnapshot? = SnapshotCache.load()
    @Published var isRefreshing = false
    @Published var showWizard = false
    @Published var liveState: LiveTicker.State = .idle
    @Published var lastTickAt: Date?
    /// Seconds between Kalshi stamping the last message and it reaching us. Nil until a stamped
    /// message arrives; a few seconds is normal, tens of seconds means we're falling behind.
    @Published var feedLag: TimeInterval?
    /// Kalshi's health as seen from here; drives the menu bar tint and the status banner.
    @Published var health: ExchangeHealth = .ok
    /// When `health` last left `.ok`, for "down since 12:40".
    @Published var healthChangedAt: Date?
    private let healthMonitor = ExchangeHealthMonitor()
    /// False when the Mac has no network path. Drives the "Computer network offline" line.
    @Published var isOnline = true
    private let networkMonitor = NetworkMonitor()
    /// Settled markets (the Settled tab and the realized chart). Cached; refreshed incrementally
    /// after every positions refresh, so a settlement push lands here within seconds.
    @Published var ledger: Ledger? = LedgerCache.load()
    @Published var isRefreshingLedger = false
    private var ledgerTask: Task<Void, Never>?

    func refreshLedger() async {
        guard let cred = credential else { return }
        if let t = ledgerTask { await t.value; return }
        let task = Task { @MainActor in
            self.isRefreshingLedger = true
            defer { self.isRefreshingLedger = false }
            do {
                let l = try await LedgerBuilder.build(client: KalshiClient(credential: cred), existing: self.ledger)
                self.ledger = l
                LedgerCache.save(l)
            } catch {
                // Keep the cached ledger; the positions refresh already surfaces API errors.
            }
        }
        ledgerTask = task
        await task.value
        ledgerTask = nil
    }

    /// Live Line (opt-in): samples the sports total on ticks and refreshes; `liveLineUpdatedAt`
    /// nudges the P&L chart.
    let liveLine = LiveLineRecorder()
    @Published var liveLineUpdatedAt: Date?

    /// Which section the window shows. Not persisted: the app opens on Positions — that's the glance.
    @Published var tab: Prefs.MainTab = .positions

    private var workModeOn: Bool { Prefs.defaults.bool(forKey: Prefs.workModeKey) }
    /// ⌘1–⌘4. P&L is refused while Work Mode is on.
    func selectTab(_ t: Prefs.MainTab) {
        if t == .pnl, workModeOn { return }
        tab = t
    }
    /// ⌘⇧] / ⌘⇧[: wraps around, skipping P&L in Work Mode.
    func cycleTab(_ delta: Int) {
        let all = Prefs.MainTab.visible(workMode: workModeOn)
        let i = all.firstIndex(of: tab) ?? 0
        tab = all[(i + delta + all.count) % all.count]
    }
    /// Work Mode flipped on while P&L was showing: fall back to Positions.
    func workModeChanged(_ on: Bool) {
        if on, tab == .pnl { tab = .positions }
    }

    /// Group ids (game keys / combo tickers) currently expanded in the positions list.
    @Published var expandedGroups: Set<String> = []
    /// Set when the connected key turns out to have write scopes (checked once per launch).
    @Published var keyScopeWarning: String?
    /// Resting orders Kalshi cancelled itself this session (newest first, last 12 hours, max 10).
    @Published var kalshiCancels: [KalshiCancel] = []
    /// Last Live Line enabled/store/env combination sync was started for.
    private var liveLineSyncSig = ""
    private var scopeChecked = false

    /// A game a widget tap asked to show; PositionsTab scrolls to it and clears this.
    @Published var focusGroup: String?

    /// Handle a spexglance:// link: Positions tab, and the tapped game expanded and in view.
    func open(_ link: DeepLink) {
        NSApp.activate(ignoringOtherApps: true)
        tab = .positions
        if case .game(let id) = link {
            expandedGroups.insert(id)
            focusGroup = id
        }
    }

    func toggleExpanded(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }
    /// ⌘E: if anything is open, close everything; otherwise open everything.
    func toggleExpandAll() {
        let ids = Set((snapshot?.groups ?? []).map(\.id))
        expandedGroups = expandedGroups.isEmpty ? ids : []
    }

    private let ticker = LiveTicker()
    private var pollTimer: Timer?
    private var inFlight: Task<Void, Never>?
    /// When each market last ticked over the socket, so a REST refresh doesn't clobber a newer quote.
    private var tickTimes: [String: Date] = [:]

    var isConnected: Bool { credential != nil }

    var menuBarTitle: String {
        guard let s = snapshot, !s.bets.isEmpty else { return health.badge ?? "Spex" }
        return Fmt.dollars(s.totalUnrealized, signed: true)
    }
    /// Work Mode title: "+305.57" — no currency sign, nil when there is nothing to show.
    var menuBarNumber: String? {
        guard let s = snapshot, !s.bets.isEmpty else { return nil }
        return Fmt.dollars(s.totalUnrealized, signed: true).replacingOccurrences(of: "$", with: "")
    }

    /// Pending full reload triggered by a push we can't apply in place (new position, new order).
    private var reloadTask: Task<Void, Never>?
    /// Last time a live change was written to the widget cache; ticks are throttled, structure isn't.
    private var lastCacheWrite: Date = .distantPast

    init() {
        ticker.onTick = { [weak self] t, bid, ask, last, at in self?.applyTick(t, bid, ask, last, serverTime: at) }
        ticker.onPosition = { [weak self] p in self?.applyPosition(p) }
        ticker.onOrder = { [weak self] o in self?.applyOrder(o) }
        ticker.onLifecycle = { [weak self] l in self?.applyLifecycle(l) }
        ticker.onState = { [weak self] s in
            self?.liveState = s
            self?.healthMonitor.socketChanged(s)
            // A lag figure from before a drop or a quiet spell means nothing once we're back.
            if s != .live { self?.feedLag = nil }
        }
        healthMonitor.onChange = { [weak self] h in
            guard let self else { return }
            let prev = self.health
            self.health = h
            if h.isOK { self.healthChangedAt = nil }
            else if self.healthChangedAt == nil || prev.kind != h.kind { self.healthChangedAt = Date() }
        }
        liveLine.onSample = { [weak self] at in self?.liveLineUpdatedAt = at }
        NotificationCenter.default.addObserver(forName: .liveLineMerged, object: nil, queue: .main) { [weak self] _ in
            self?.liveLineUpdatedAt = Date()
        }
        // Settings flips the Live Line prefs; (re)evaluate sync whenever they change.
        // Only the Live Line switches matter. Reacting to every write (sync saves its own bookmark
        // in these defaults) re-entered start() in a loop and fired a burst of downloads.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: Prefs.defaults, queue: .main) { [weak self] _ in
            guard let self, let env = self.credential?.environment else { return }
            let sig = "\(LiveLineRecorder.enabled)|\(Prefs.defaults.string(forKey: Prefs.liveLineStoreKey) ?? "")|\(env.rawValue)"
            guard sig != self.liveLineSyncSig else { return }
            self.liveLineSyncSig = sig
            LiveLineSync.shared.start(env: env)
        }
        if let cred = credential {
            healthMonitor.start(environment: cred.environment)
            LiveLineSync.shared.start(env: cred.environment)
        }
        networkMonitor.start { [weak self] online in
            guard let self else { return }
            let wasOnline = self.isOnline
            self.isOnline = online
            self.healthMonitor.networkChanged(online: online)
            if online, !wasOnline, self.credential != nil {
                // Back on the network. DNS and routes take a moment to settle, so wait before
                // catching up, and try once more if the first attempt still fails.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard self.isOnline else { return }
                    self.ticker.reconnectNow()
                    await self.refresh()
                    if self.snapshot?.errorMessage != nil {
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        guard self.isOnline else { return }
                        await self.refresh()
                    }
                }
            }
        }
        // Fills, sells, settlements and new orders arrive over the socket; the 5-minute poll is
        // reconciliation, so a missed message or a dropped socket can't leave stale numbers up.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        scoreTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollScores() }
        }
    }

    // MARK: Scoreboards

    private var scoreTimer: Timer?
    private var scoresInFlight = false
    /// Every 15 s, while any held game is on (or starts within 15 min): one batch request to
    /// `GET /live_data/batch` for all of them — up to 100 games per call, public data.
    /// Nothing is polled when no game is live.
    func pollScores() async {
        guard !scoresInFlight, let cred = credential, let s = snapshot, isOnline else { return }
        let ids = s.scoreboardMilestones
        guard !ids.isEmpty else { return }
        scoresInFlight = true
        defer { scoresInFlight = false }
        guard let entries = try? await KalshiClient(credential: cred).liveData(milestoneIDs: ids) else { return }
        guard var cur = snapshot else { return }
        let games = cur.games ?? [:]
        var parsed: [String: LiveScore] = [:]
        for e in entries {
            guard let info = games[e.milestone_id],
                  let sc = LiveScoreParser.parse(type: e.type, details: e.details, info: info) else { continue }
            parsed[e.milestone_id] = sc
        }
        // Window and menu bar only. The widget isn't nudged here: a reload every 15 s would burn
        // WidgetKit's daily budget; it picks up the phase on the next price or position push.
        if cur.applyLiveScores(parsed) { snapshot = cur }
    }

    /// Set by a live push that a running REST load may not reflect yet; makes the loader go
    /// around once more so a fill that lands mid-fetch isn't overwritten by older REST data.
    private var reloadPending = false

    /// Coalesces overlapping calls: a refresh already in flight is awaited, not duplicated.
    /// The in-flight loader repeats while pushes keep arriving underneath it.
    func refresh() async {
        guard isConnected else { return }
        if let t = inFlight { await t.value; return }
        let task = Task {
            repeat {
                self.reloadPending = false
                await self.performRefresh()
            } while self.reloadPending && self.isConnected
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        if !scopeChecked, let cred = credential {
            scopeChecked = true
            if case .notReadOnly(let extras, let missingRead) = await KalshiClient(credential: cred).checkOwnKeyScope() {
                keyScopeWarning = "Your Kalshi key " + (extras.isEmpty ? "doesn't have Read all data checked" : "has \(extras.joined(separator: ", ")) checked")
                    + ". Spex Glance never uses those permissions, but replace the key: Disconnect, then create a new one on Kalshi with only Read all data checked."
                    + (missingRead && !extras.isEmpty ? " (It is also missing Read.)" : "")
            } else {
                keyScopeWarning = nil
            }
        }
        var fresh = await Refresher.refresh()
        healthMonitor.refreshFinished(error: fresh.errorMessage)
        // Keep any socket quote newer than the REST response.
        if let old = snapshot, old.environment == fresh.environment {
            for i in fresh.bets.indices {
                let t = fresh.bets[i].ticker
                if let tickAt = tickTimes[t], tickAt > fresh.fetchedAt,
                   let prev = old.bets.first(where: { $0.ticker == t }) {
                    fresh.bets[i].applyTick(yesBid: prev.yesBid, yesAsk: prev.yesAsk, last: prev.yesLast)
                }
                // Same for combo legs.
                for leg in old.bets.first(where: { $0.ticker == t })?.legs ?? [] {
                    if let tickAt = tickTimes[leg.ticker], tickAt > fresh.fetchedAt {
                        fresh.bets[i].applyLegTick(ticker: leg.ticker, yesBid: leg.yesBid, yesAsk: leg.yesAsk, last: leg.yesLast)
                    }
                }
            }
        }
        // Scoreboards outlive a REST reload: carry them over and let them set each game's phase.
        if let old = snapshot, old.environment == fresh.environment, let scores = old.liveScores {
            fresh.applyLiveScores(scores)
        }
        snapshot = fresh
        WidgetCenter.shared.reloadTimelines(ofKind: SharedIDs.widgetKind)
        startLive()
        Task { await pollScores() }
        liveLine.sample(fresh, force: true)
        Task { await refreshLedger() }
    }

    private func startLive() {
        guard let cred = credential, let s = snapshot else { return }
        let tickers = s.liveTickers
        if tickers.isEmpty { ticker.stop() } else { ticker.start(credential: cred, tickers: tickers) }
    }

    private func applyTick(_ t: String, _ bid: Double?, _ ask: Double?, _ last: Double?, serverTime: Date?) {
        let now = Date()
        if let at = serverTime { feedLag = max(0, now.timeIntervalSince(at)) }
        guard var s = snapshot else { return }
        if s.applyTick(ticker: t, yesBid: bid, yesAsk: ask, last: last) {
            s.liveUpdatedAt = now
            snapshot = s
            tickTimes[t] = now
            lastTickAt = now
            liveLine.sample(s)
            // Prices move constantly; give the widget a fresh copy at most once a minute.
            if now.timeIntervalSince(lastCacheWrite) > 60 { persistLive(s) }
        }
    }

    private func applyPosition(_ p: LivePosition) {
        guard var s = snapshot else { return }
        switch s.applyPosition(ticker: p.ticker, contracts: p.contracts, costDollars: p.costDollars,
                               realized: p.realizedDollars, fees: p.feesDollars) {
        case .updated:
            // Size or cost moved (a fill): show it now, then let REST bring the new cash balance.
            s.liveUpdatedAt = Date()
            snapshot = s
            persistLive(s)
            scheduleReload()
        case .closed:
            // Sold out or paid out: drop it now, then reload for the new cash balance and to
            // stop streaming a market we no longer hold.
            s.liveUpdatedAt = Date()
            snapshot = s
            persistLive(s)
            scheduleReload()
        case .unknown:
            // A market we haven't seen (new buy, or a side flip): needs names, sport and legs.
            scheduleReload()
        case .unchanged:
            break
        }
    }

    private func applyOrder(_ o: LiveOrder) {
        guard var s = snapshot else { return }
        if o.status == "canceled", let why = KalshiCancel.explanation(for: o.reason),
           let open = s.orders.first(where: { $0.id == o.orderID }) {
            let cutoff = Date().addingTimeInterval(-12 * 3600)
            kalshiCancels = ([KalshiCancel(id: open.id, eventTitle: open.eventTitle, sideTitle: open.sideTitle,
                                           isYes: open.isYes, isBuy: open.isBuy, reason: why, at: Date())]
                             + kalshiCancels.filter { $0.id != open.id && $0.at > cutoff }).prefix(10).map { $0 }
        }
        let isNew = s.applyOrder(id: o.orderID, ticker: o.ticker, status: o.status, isYes: o.isYes, isBuy: o.isBuy,
                                 yesPrice: o.yesPriceDollars, remaining: o.remaining)
        s.liveUpdatedAt = Date()
        snapshot = s
        persistLive(s)
        if isNew { scheduleReload() } else if inFlight != nil { reloadPending = true }
    }

    private func applyLifecycle(_ l: LiveLifecycle) {
        guard var s = snapshot else { return }
        if s.applyLifecycle(ticker: l.ticker, eventType: l.eventType, result: l.result, closeTime: l.closeTime) {
            s.liveUpdatedAt = Date()
            snapshot = s
            persistLive(s)
            if inFlight != nil { reloadPending = true }
        }
        // Payout changes cash; settled markets leave the positions list. Let REST catch up.
        if l.eventType == "settled" { scheduleReload() }
    }

    /// Write the live snapshot where the widget reads it and nudge WidgetKit.
    private func persistLive(_ s: PortfolioSnapshot) {
        lastCacheWrite = Date()
        SnapshotCache.save(s)
        WidgetCenter.shared.reloadTimelines(ofKind: SharedIDs.widgetKind)
    }

    /// Full REST reload, coalesced: a burst of pushes (a multi-fill order, a settlement wave)
    /// becomes one request a couple of seconds after the last one.
    private func scheduleReload() {
        reloadPending = true
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func connect(_ cred: KalshiCredential) throws {
        try KeychainStore.save(cred)
        credential = cred
        healthMonitor.start(environment: cred.environment)
        LiveLineSync.shared.start(env: cred.environment)
        SnapshotCache.clear()
        snapshot = nil
        ledger = nil
        tickTimes = [:]
        scopeChecked = false
        keyScopeWarning = nil
        Task { await refresh() }
    }

    func disconnect() {
        if let env = credential?.environment { LiveLineStore.clear(env: env) }   // history goes with the key
        LiveLineSync.shared.stop()
        ticker.stop()
        healthMonitor.stop()
        reloadTask?.cancel()
        KeychainStore.delete()
        SnapshotCache.clear()
        credential = nil
        snapshot = nil
        ledger = nil
        tickTimes = [:]
        feedLag = nil
        lastTickAt = nil
        WidgetCenter.shared.reloadTimelines(ofKind: SharedIDs.widgetKind)
    }
}


/// Colored text for the menu bar. Plain `Text(...).foregroundStyle` is ignored there; an
/// attributed string's color is honored.
enum MenuBarText {
    static func attributed(_ s: String, tint: NSColor?) -> AttributedString {
        var a = AttributedString(s)
        if let tint { a.foregroundColor = Color(nsColor: tint) }
        return a
    }
}
