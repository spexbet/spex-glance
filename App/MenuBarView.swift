import SwiftUI
import AppKit

/// The menu bar dropdown: the window's vocabulary in a smaller frame. Paper/navy ground,
/// Space Grotesk for money, cobalt for the money strip, red only for LIVE and losses.
/// Work Mode drops the money strip and every "$", like the window.
struct MenuBarView: View {
    @AppStorage(Prefs.sortKey, store: Prefs.defaults) private var sort: Prefs.GroupSort = .liveFirst
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Measured height of the game list. A ScrollView inside a MenuBarExtra window has no ideal
    /// height of its own (it collapsed to nothing), so size it to its content, capped.
    @State private var listHeight: CGFloat = 0

    private func money(_ v: Double?, signed: Bool = false) -> String { Fmt.money(v, signed: signed, workMode: workMode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !model.health.isOK { healthRow }

            if let s = model.snapshot, !s.bets.isEmpty {
                if !workMode { moneyStrip(s) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sort.sorted(s.groups)) { g in
                            groupCard(g)
                        }
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                    })
                }
                .scrollIndicators(listHeight > Self.maxListHeight ? .automatic : .never)
                .frame(height: min(max(listHeight, 60), Self.maxListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
                if s.hiddenNonSports > 0 {
                    Text("\(s.hiddenNonSports) non-sports position\(s.hiddenNonSports == 1 ? "" : "s") not shown")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: model.isConnected ? "eyeglasses" : "link.badge.plus").foregroundStyle(.secondary)
                    Text(model.isConnected ? "No open sports positions right now." : "Not connected. Open Spex Glance to connect Kalshi.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(Brand.ground)
    }

    /// Taller than this and the list scrolls; keeps the dropdown on a laptop screen.
    static let maxListHeight: CGFloat = 480

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            if !workMode { Image(nsImage: MenuBarIcon.image).accessibilityHidden(true) }
            Text("Spex Glance").font(Brand.display(15, weight: .medium))
            Spacer()
            liveDot
        }
    }

    /// Cash / Positions / Total as three small cobalt tiles, then the unrealized line.
    private func moneyStrip(_ s: PortfolioSnapshot) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                miniTile("Cash", money(s.balanceDollars))
                miniTile("Positions", money(s.totalValue))
                miniTile("Total", money(s.sportsTotal))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Unrealized").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if s.totalRealized != 0 {
                    Text("\(money(s.totalRealized, signed: true)) realized")
                        .font(.caption.monospacedDigit()).foregroundStyle(Fmt.pnlColor(s.totalRealized))
                }
                Text(money(s.totalUnrealized, signed: true))
                    .font(Brand.display(17).monospacedDigit())
                    .foregroundStyle(Fmt.pnlColor(s.totalUnrealized))
            }
        }
    }

    private func miniTile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(Brand.display(9, weight: .medium)).tracking(0.7)
                .foregroundStyle(Brand.cream.opacity(0.8))
            Text(value).font(Brand.display(15).monospacedDigit()).foregroundStyle(Brand.cream)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// One game (or combo) as a card: title + status on top, a line per position below.
    private func groupCard(_ g: EventGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: g.isCombo ? "link" : SportGlyph.symbol(for: g.sport ?? ""))
                    .font(.caption).foregroundStyle(.secondary).frame(width: 14)
                if g.isCombo, let b = g.bets.first {
                    Text("\(b.legs?.count ?? 0) MARKET COMBO").font(.caption.weight(.semibold)).tracking(0.4)
                } else {
                    Text(g.title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !workMode {
                    Text(money(g.unrealized, signed: true))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Fmt.pnlColor(g.unrealized))
                }
            }
            let sc = g.milestoneID.flatMap { model.snapshot?.liveScores?[$0] }
            HStack(spacing: 6) {
                if g.isLive, let sc, sc.state == .live {
                    Text("LIVE · " + sc.status).font(.caption2.weight(.bold)).foregroundStyle(Color.red)
                } else if let st = Fmt.gameStatus(start: g.startTime, isLive: g.isLive, isFinal: g.isFinal) {
                    Text(st).font(.caption2.weight(g.isLive ? .bold : .regular))
                        .foregroundStyle(g.isLive ? Color.red : Color.secondary)
                }
                if let sc, sc.state != .pre {
                    Spacer(minLength: 4)
                    ScoreLine(score: sc, font: .caption2)
                }
            }
            .padding(.leading, 20)
            Group {
                if g.isCombo, let b = g.bets.first, let legs = b.legs {
                    HStack {
                        if !workMode { Text("\(money(b.costDollars)) pays \(money(b.maxPayout))").font(.caption.monospacedDigit()) }
                        Spacer()
                        ChanceLabel(bet: b, font: .caption)
                    }
                    ForEach(legs) { leg in
                        HStack {
                            Text(leg.label).font(.caption2).lineLimit(1)
                                .foregroundStyle(leg.outcome == .missed ? Color.red : Color.secondary)
                            Spacer()
                            switch leg.outcome {
                            case .hit: Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                            case .missed: Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
                            case .pending:
                                Text(leg.hitProbability.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else {
                    ForEach(g.bets) { bet in
                        HStack(spacing: 6) {
                            Text(bet.positionLabel).font(.caption.weight(.medium)).lineLimit(1)
                            if let q = bet.qualifier { Text(q).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                            Spacer(minLength: 4)
                            ChanceLabel(bet: bet, font: .caption)
                        }
                    }
                }
            }
            .padding(.leading, 20)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open Spex Glance") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(SpexButtonStyle(filled: true, compact: true))
            Button {
                Task { await model.refresh() }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(SpexButtonStyle(filled: false, compact: true))
            .disabled(model.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Spacer()
            Menu {
                SettingsLink { Text("Settings…") }
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }.disabled(!Updater.shared.canCheck)
                Divider()
                Button("Quit Spex Glance") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    /// Shown only while something is wrong: what, since when, and where to look.
    private var healthRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: model.health.tint ?? .secondaryLabelColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.health.summary).font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                if let t = model.healthChangedAt {
                    Text("since \(Fmt.gameTime(t)) · numbers may be stale").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.health.isAboutKalshi {
                Button("Status page") { NSWorkspace.shared.open(URL(string: "https://kalshistatus.com")!) }
                    .font(.caption2)
                    .help("kalshistatus.com — an unofficial, community-run Kalshi status page")
            }
        }
        .padding(8)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var liveDot: some View {
        let (color, text): (Color, String) = {
            switch model.liveState {
            case .live:
                // Amber once Kalshi's own timestamps say we're more than 15s behind.
                if let lag = model.feedLag, lag > 15, let t = model.lastTickAt, Date().timeIntervalSince(t) < 120 {
                    return (.orange, "live · \(Int(lag))s behind")
                }
                return (.green, model.lastTickAt.map { "live · " + Fmt.relative($0) } ?? "live")
            case .connecting: return (.yellow, "connecting")
            case .backoff(let s): return (.orange, "retry in \(s)s")
            case .failed(let m): return (.red, "socket: \(m)")
            case .idle: return (.gray, "polling")
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
