import SwiftUI
import AppKit
import ServiceManagement

/// User preferences. Kept in the App Group suite so a future widget option can share them.
enum Prefs {
    static var defaults: UserDefaults { UserDefaults(suiteName: SharedIDs.appGroup) ?? .standard }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var scheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    static let appearanceKey = "appearance"
    static let menuBarShowPnLKey = "menuBarShowPnL"
    /// Work Mode: menu bar shows no Spex icon and no "$" — just a bare number, so a shared
    /// screen doesn't advertise a Kalshi portfolio.
    static let workModeKey = "workMode"
    /// Sport filter for the positions list; empty string means "All".
    static let sportFilterKey = "sportFilter"
    static let sortKey = "groupSort"
    /// Positions "Live" checkbox: only games started and not yet settled. Survives relaunch.
    static let positionsLiveOnlyKey = "positionsLiveOnly"

    /// Sections of the main window. ⌘1–⌘4; P&L is hidden in Work Mode.
    enum MainTab: String, CaseIterable, Identifiable {
        case positions, orders, settled, pnl
        var id: String { rawValue }
        var label: String {
            switch self {
            case .positions: return "Positions"
            case .orders: return "Orders"
            case .settled: return "Settled"
            case .pnl: return "P&L"
            }
        }
        var shortcutKey: Character {
            switch self {
            case .positions: return "1"
            case .orders: return "2"
            case .settled: return "3"
            case .pnl: return "4"
            }
        }
        /// Tabs shown for the current mode: everything, minus P&L in Work Mode.
        static func visible(workMode: Bool) -> [MainTab] {
            allCases.filter { !(workMode && $0 == .pnl) }
        }
    }

    /// Live Line is opt-in: off means nothing is ever written.
    static let liveLineEnabledKey = "liveLineEnabled"
    static let liveLineStoreKey = "liveLineStore"
    /// Seconds since 1970; the chart's "since" date and the start of the All range.
    static let liveLineEnabledAtKey = "liveLineEnabledAt"
    enum LiveLineStore: String, CaseIterable, Identifiable {
        case mac, icloud
        var id: String { rawValue }
    }

    static let pnlIncludeFeesKey = "pnlIncludeFees"
    static let pnlRangeKey = "pnlRange"
    enum PnLRange: String, CaseIterable, Identifiable {
        case day, week, month, all
        var id: String { rawValue }
        var label: String {
            switch self { case .day: return "1D"; case .week: return "7D"; case .month: return "30D"; case .all: return "All" }
        }
        var title: String {
            switch self { case .day: return "last 24 hours"; case .week: return "last 7 days"; case .month: return "last 30 days"; case .all: return "since day one" }
        }
        var start: Date? {
            switch self {
            case .day: return Date().addingTimeInterval(-86400)
            case .week: return Date().addingTimeInterval(-7 * 86400)
            case .month: return Date().addingTimeInterval(-30 * 86400)
            case .all: return nil
            }
        }
    }

    enum GroupSort: String, CaseIterable, Identifiable {
        case liveFirst, soonest, latest
        var id: String { rawValue }
        var label: String {
            switch self {
            case .liveFirst: return "Live first"
            case .soonest: return "Earliest start first"
            case .latest: return "Latest start first"
            }
        }
        var symbol: String {
            switch self {
            case .liveFirst: return "dot.radiowaves.left.and.right"
            case .soonest: return "arrow.up"
            case .latest: return "arrow.down"
            }
        }
        func sorted(_ groups: [EventGroup]) -> [EventGroup] {
            let far = Date.distantFuture
            switch self {
            case .liveFirst:
                // live → upcoming (soonest first) → finals awaiting settlement
                func rank(_ g: EventGroup) -> Int { g.isLive ? 0 : g.isFinal ? 2 : 1 }
                return groups.sorted {
                    if rank($0) != rank($1) { return rank($0) < rank($1) }
                    return ($0.startTime ?? far) < ($1.startTime ?? far)
                }
            case .soonest: return groups.sorted { ($0.startTime ?? far) < ($1.startTime ?? far) }
            case .latest: return groups.sorted { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.appearanceKey, store: Prefs.defaults) private var appearance: Prefs.Appearance = .system
    @AppStorage(Prefs.menuBarShowPnLKey, store: Prefs.defaults) private var menuBarShowPnL = true
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @ObservedObject private var updater = Updater.shared
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    @AppStorage(Prefs.liveLineEnabledKey, store: Prefs.defaults) private var liveLineEnabled = false
    @AppStorage(Prefs.liveLineStoreKey, store: Prefs.defaults) private var liveLineStore: Prefs.LiveLineStore = .mac
    @AppStorage(Prefs.liveLineEnabledAtKey, store: Prefs.defaults) private var liveLineEnabledAt = 0.0
    @State private var showStorageSheet = false
    @State private var confirmClear = false
    @State private var historyInfo: (chunks: Int, bytes: Int, oldest: Date?) = (0, 0, nil)
    @ObservedObject private var sync = LiveLineSync.shared
    @State private var offerCloudDelete = false
    @State private var cloudDeleteError: String?
    private var liveEnv: KalshiEnvironment { KeychainStore.load()?.environment ?? .prod }

    private var historyLine: String {
        guard historyInfo.chunks > 0 else { return "No samples yet — the first one lands on the next price tick." }
        let since = historyInfo.oldest.map { Fmt.gameTime($0) } ?? "—"
        let kb = max(1, historyInfo.bytes / 1024)
        return "Recording since \(since) · \(kb) KB · 1-minute points for 24 h, 5-minute to 7 days, hourly after"
    }

    var body: some View {
        VStack(spacing: 0) {
        // macOS 26+ pins window titles to the left. Hide the real one and add our own label
        // as a subview of the title bar itself, centered — the title bar can't paint over its own child.
        Color.clear.frame(height: 0)
            .background(WindowConfigurator { w in
                w.title = "Settings"
                w.toolbar = nil
                w.titleVisibility = .hidden
                guard let bar = w.standardWindowButton(.closeButton)?.superview,
                      bar.subviews.first(where: { $0.identifier?.rawValue == "spex.centeredTitle" }) == nil else { return }
                let label = NSTextField(labelWithString: "Settings")
                label.identifier = NSUserInterfaceItemIdentifier("spex.centeredTitle")
                label.font = NSFont.titleBarFont(ofSize: NSFont.systemFontSize)
                label.textColor = .labelColor
                label.alignment = .center
                label.sizeToFit()
                label.frame.origin = NSPoint(x: (bar.bounds.width - label.frame.width) / 2,
                                             y: (bar.bounds.height - label.frame.height) / 2)
                label.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
                bar.addSubview(label)
            })
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().interpolation(.high)
            .frame(width: 95, height: 95)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Prefs.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("System follows your Mac or iPhone's light/dark setting, including automatic switching.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Charts") {
                Toggle("Live Line", isOn: Binding(
                    get: { liveLineEnabled },
                    set: { on in
                        if on { showStorageSheet = true }      // confirm where first; nothing written yet
                        else { liveLineEnabled = false }       // data is kept; "Clear History…" deletes
                    }))
                Text("Charts your sports total over time on the P&L section. Off by default — turning it on stores a copy of your portfolio-value history. Nothing is stored while it's off.")
                    .font(.footnote).foregroundStyle(.secondary)
                if liveLineEnabled {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Where it's stored").font(.body)
                            Text(liveLineStore == .icloud
                                 ? sync.status.line + (sync.lastPullAt.map { " Last sync \(Fmt.relative($0))." } ?? "")
                                 : "This Mac only · encrypted in the app container. Disconnect erases it.")
                                .font(.footnote)
                                .foregroundStyle(liveLineStore == .icloud && sync.status != .syncing && sync.status != .checking ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Button("Change…") { showStorageSheet = true }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("History").font(.body)
                            Text(historyLine).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clear History…") { confirmClear = true }
                            .disabled(historyInfo.chunks == 0)
                    }
                }
            }
            .sheet(isPresented: $showStorageSheet) {
                LiveLineStorageSheet(pick: liveLineStore) { store in
                    let was = liveLineStore
                    liveLineStore = store
                    if !liveLineEnabled { liveLineEnabledAt = Date().timeIntervalSince1970 }
                    liveLineEnabled = true
                    if store == .icloud {
                        // Existing local history goes up too, so a second Mac sees the whole line.
                        LiveLineSync.shared.start(env: liveEnv)
                        LiveLineSync.shared.uploadAll()
                    } else if was == .icloud {
                        offerCloudDelete = true
                    }
                }
            }
            .alert("Also delete the iCloud copy?", isPresented: $offerCloudDelete) {
                Button("Delete from iCloud", role: .destructive) {
                    Task { cloudDeleteError = await LiveLineSync.shared.deleteCloudCopy() }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Live Line now stays on this Mac. The copy in your iCloud can be removed too; other Macs keep what they already downloaded.")
            }
            .alert("Couldn't delete from iCloud", isPresented: Binding(get: { cloudDeleteError != nil }, set: { if !$0 { cloudDeleteError = nil } })) {
                Button("OK") {}
            } message: { Text(cloudDeleteError ?? "") }
            .alert("Clear Live Line history?", isPresented: $confirmClear) {
                Button("Clear", role: .destructive) {
                    LiveLineStore.clear(env: liveEnv)
                    liveLineEnabledAt = Date().timeIntervalSince1970
                    historyInfo = LiveLineStore.info(env: liveEnv)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes every sample on this Mac. Recording continues from the next price tick.")
            }
            .onAppear { historyInfo = LiveLineStore.info(env: liveEnv) }
            .onChange(of: liveLineEnabled) { _, _ in historyInfo = LiveLineStore.info(env: liveEnv) }

            Section("Menu bar") {
                Toggle("Show unrealized P&L next to the icon", isOn: $menuBarShowPnL)
                Toggle("Work Mode", isOn: $workMode)
                Text("Hides the Spex icon and the $ sign in the menu bar, so a shared screen shows only a plain number (or a neutral dot when P&L is off). Nothing else changes.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let e = loginError {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
                Text("Also visible under System Settings → General → Login Items.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, on in Updater.shared.automaticallyChecks = on }
                    .disabled(!updater.isConfigured)
                Button("Check Now") { Updater.shared.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Text(updater.isConfigured
                     ? "Updates come from GitHub Releases and are verified against a signing key built into the app."
                     : "This build was made from source without a release signing key, so automatic updates are off. Pull the repo and rebuild to update.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                if KeychainStore.load() != nil { APITierRow() }
                Text("Spex Glance is a cleaner way to keep track of your open Kalshi sports positions — in a window and from the menu bar. It uses a free, read-only API key from your own Kalshi account; nothing leaves your Mac except requests to Kalshi.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Not affiliated with Kalshi. Does not place, amend, or cancel orders. Informational only — not trading advice. Prices and settlements are relayed from Kalshi as-is and can lag or be wrong; always confirm on Kalshi before acting.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    Browser.open(URL(string: "https://github.com/spexbet/spex-glance")!)
                } label: { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button {
                    // Support is a GitHub issue. Pre-fill the environment so the report is useful on arrival.
                    let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let os = ProcessInfo.processInfo.operatingSystemVersionString
                    let body = "**Spex Glance** \(app) · **macOS** \(os)\n\n**What happened**\n\n\n**What you expected**\n\n"
                    var c = URLComponents(string: "https://github.com/spexbet/spex-glance/issues/new")!
                    c.queryItems = [URLQueryItem(name: "body", value: body)]
                    Browser.open(c.url!)
                } label: { Label("Report a problem or ask a question", systemImage: "questionmark.bubble") }
                Text("Support is handled through GitHub issues. Please include what you saw and what you expected; your app and macOS versions are filled in for you.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
                } label: { Label("Third-party licenses", systemImage: "doc.text") }
                Text("MIT licensed, provided as-is with no warranty. Built with Claude. Includes Sparkle (MIT) and Space Grotesk (SIL OFL 1.1).")
                    .font(.footnote).foregroundStyle(.tertiary)
            }

            Section("Want to help keep this project running?") {
                HStack {
                    Button {
                        Browser.open(URL(string: "https://ko-fi.com/U4B527UPTU")!)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cup.and.saucer.fill")
                            Text("Support me on Ko-fi").fontWeight(.semibold)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(.white)
                        .background(Color(red: 1.0, green: 0.37, blue: 0.36), in: Capsule())   // Ko-fi coral
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Support me on Ko-fi (opens in your browser)")
                    Spacer()
                }
                Text("Spex Glance is free. Tips go toward the Apple developer account that keeps it signed and notarized.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}

/// Runs a closure against the hosting NSWindow once it exists.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { configure(w) } }
    }
}
