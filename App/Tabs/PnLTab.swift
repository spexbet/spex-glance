import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

/// ⌘4 — realized P&L as a step chart rebuilt from Kalshi's settlements (no storage), plus the
/// Live Line card once that opt-in exists. Never shown in Work Mode.
struct PnLTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false
    @AppStorage(Prefs.pnlIncludeFeesKey, store: Prefs.defaults) private var includeFees = true
    @AppStorage(Prefs.pnlRangeKey, store: Prefs.defaults) private var range: Prefs.PnLRange = .all
    @AppStorage(Prefs.liveLineEnabledKey, store: Prefs.defaults) private var liveLineEnabled = false
    @AppStorage(Prefs.liveLineStoreKey, store: Prefs.defaults) private var liveLineStore: Prefs.LiveLineStore = .mac
    @AppStorage(Prefs.liveLineEnabledAtKey, store: Prefs.defaults) private var liveLineEnabledAt = 0.0
    @State private var live: [LiveSample] = []

    var body: some View {
        let from = range.start
        let series = model.ledger?.cumulative(includeFees: includeFees, from: from) ?? []
        let total = series.last?.1 ?? 0
        let count = series.count

        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    HStack(spacing: 4) {
                        ForEach(Prefs.PnLRange.allCases) { r in
                            let on = r == range
                            Button { range = r } label: {
                                Text(r.label)
                                    .font(.caption.weight(on ? .semibold : .regular))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(on ? Color.accentColor : Color.secondary.opacity(0.15))
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Spacer()
                    Toggle("Include fees", isOn: $includeFees).toggleStyle(.checkbox).font(.caption)
                }

                card {
                    HStack(alignment: .firstTextBaseline) {
                        Text("REALIZED · \(range.title.uppercased())")
                            .font(Theme.display(10, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.money(total, signed: true, workMode: workMode))
                            .font(Theme.display(20, weight: .bold).monospacedDigit())
                            .foregroundStyle(Fmt.pnlColor(total))
                    }
                    if series.isEmpty {
                        Text(model.ledger == nil ? "Loading settlements…" : "Nothing settled \(range.title).")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        chart(series, from: from)
                    }
                    Text("Rebuilt from Kalshi settlements · sports only · \(count) market\(count == 1 ? "" : "s") · fees \(includeFees ? "included" : "excluded")")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                if liveLineEnabled {
                    liveCard
                } else {
                    card {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Live Line is off").font(.headline)
                                Text("Turn it on in Settings to chart your sports total over time.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            SettingsLink { Text("Settings ⌘,") }
                                .buttonStyle(SpexButtonStyle(filled: false))
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.paper)
        .task(id: "\(range.rawValue)|\(liveLineEnabled)|\(model.liveLineUpdatedAt?.timeIntervalSince1970 ?? 0)") {
            guard liveLineEnabled, let env = model.credential?.environment else { live = []; return }
            let from = range.start
            let xs = await Task.detached(priority: .userInitiated) { LiveLineStore.samples(env: env, from: from) }.value
            if !Task.isCancelled { live = xs }
        }
    }

    /// Live Line: the sports total sampled on every tick since the user turned it on.
    private var liveCard: some View {
        let last = live.last?.sportsTotal
        let first = live.first?.sportsTotal
        let delta = (last != nil && first != nil) ? last! - first! : nil
        // Oldest sample here, including history downloaded from your other Macs.
        let oldest = model.credential.flatMap { LiveLineStore.info(env: $0.environment).oldest }
        let since = oldest.map { Fmt.gameTime($0) }
            ?? (liveLineEnabledAt > 0 ? Fmt.gameTime(Date(timeIntervalSince1970: liveLineEnabledAt)) : "today")
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text("LIVE LINE · SPORTS TOTAL")
                    .font(Theme.display(10, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                if let delta {
                    Text("\(Fmt.money(delta, signed: true, workMode: workMode)) \(range.label)")
                        .font(.caption.monospacedDigit()).foregroundStyle(Fmt.pnlColor(delta))
                }
                Text(Fmt.money(last ?? model.snapshot?.sportsTotal, workMode: workMode))
                    .font(Theme.display(20, weight: .bold).monospacedDigit())
            }
            if live.count < 2 {
                Text(live.isEmpty ? "Waiting for the first samples — they land about once a minute while prices move."
                                  : "One sample so far. The line appears with the next one.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                let lo = live.map(\.sportsTotal).min()!, hi = live.map(\.sportsTotal).max()!
                let pad = max(1, (hi - lo) * 0.15)
                Chart {
                    ForEach(Array(live.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("When", p.ts), y: .value("Total", p.sportsTotal))
                            .interpolationMethod(.linear)   // a balance: no invented curves between samples
                            .foregroundStyle(StatTile.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    }
                }
                .chartYScale(domain: (lo - pad) ... (hi + pad))
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Fmt.money(d, workMode: workMode)).font(.caption2).monospacedDigit()
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 170)
            }
            HStack {
                Text("Sampled on every tick since \(since) · \(liveLineStore == .icloud ? "synced with iCloud" : "stored on this Mac only") · \(live.count) point\(live.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Save as CSV…") { exportCSV() }
                    .font(.caption)
                    .disabled(live.isEmpty)
            }
        }
    }

    private func exportCSV() {
        guard let env = model.credential?.environment else { return }
        let all = LiveLineStore.samples(env: env, from: nil)
        let iso = ISO8601DateFormatter()
        var text = "ts_iso,sports_total,unrealized\n"
        for s in all { text += "\(iso.string(from: s.ts)),\(s.sportsTotal),\(s.unrealized)\n" }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "spex-live-line.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func chart(_ series: [(Date, Double)], from: Date?) -> some View {
        // Start the step at zero where the window opens and carry the last value to now.
        var pts = series
        pts.insert((from ?? series[0].0, 0), at: 0)
        pts.append((Date(), series[series.count - 1].1))
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("When", p.0), y: .value("P&L", p.1))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(StatTile.cobalt)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            RuleMark(y: .value("Zero", 0))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .foregroundStyle(.secondary.opacity(0.5))
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(Fmt.money(d, workMode: workMode)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .frame(height: 170)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }
}
