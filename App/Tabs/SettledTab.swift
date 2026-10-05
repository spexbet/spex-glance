import SwiftUI

/// ⌘3 — markets Kalshi has settled, newest first, grouped by day with a daily net.
/// This is the ledger behind the realized P&L chart; nothing here is stored beyond a cache.
struct SettledTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.sportFilterKey, store: Prefs.defaults) private var sportFilter = ""
    @AppStorage(Prefs.workModeKey, store: Prefs.defaults) private var workMode = false
    @AppStorage(Prefs.pnlIncludeFeesKey, store: Prefs.defaults) private var includeFees = true

    struct Day: Identifiable {
        let day: Date
        let items: [SettledBet]
        let net: Double
        var id: Date { day }
    }

    var body: some View {
        let items = model.ledger?.items ?? []
        let sports = Array(Set(items.compactMap(\.sport))).sorted()
        let active = sports.contains(sportFilter) ? sportFilter : ""
        let shown = items.filter { active.isEmpty || $0.sport == active }
        let days = Self.group(shown, includeFees: includeFees)

        VStack(spacing: 0) {
            ZStack {
                if sports.count > 1 {
                    SportFilterBar(sports: sports, selection: $sportFilter, active: active)
                }
                HStack {
                    Spacer()
                    Toggle("Fees", isOn: $includeFees)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Subtract Kalshi's fees from each net")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            Divider()

            List {
                if days.isEmpty {
                    Section {
                        Text(model.isRefreshingLedger && model.ledger == nil ? "Loading…"
                             : active.isEmpty ? "Nothing settled yet." : "No settled \(active.lowercased()) markets.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(days) { d in
                    Section {
                        ForEach(d.items) { row($0) }
                    } header: {
                        HStack {
                            Text(Fmt.dayLabel(d.day))
                            Spacer()
                            if !workMode {
                                Text(Fmt.money(d.net, signed: true, workMode: workMode))
                                    .monospacedDigit()
                                    .foregroundStyle(Fmt.pnlColor(d.net))
                            }
                        }
                    }
                }
                if let l = model.ledger, l.items.count > l.namedCount {
                    Text("Older rows show tickers; the newest \(l.namedCount) carry full names.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .refreshable { await model.refreshLedger() }
            .scrollContentBackground(.hidden)
            .background(Theme.paper)
        }
    }

    private func row(_ b: SettledBet) -> some View {
        let net = b.net(includeFees: includeFees)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(b.sideLabel).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(b.gameTitle).lineLimit(1)
                    if let sp = b.sport {
                        Label(sp, systemImage: SportGlyph.symbol(for: sp))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    badge(b.outcome)
                    if !workMode {
                        Text(Fmt.money(net, signed: true, workMode: workMode))
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Fmt.pnlColor(net))
                    }
                }
                // Work Mode: no money — outcome and time only.
                Text(workMode ? Fmt.gameTime(b.settledAt) : "fee \(Fmt.money(b.fee, workMode: workMode)) · \(Fmt.gameTime(b.settledAt))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 14)
    }

    private func badge(_ o: SettledBet.Outcome) -> some View {
        let (text, color): (String, Color) = {
            switch o {
            case .won: return ("Won", .green)
            case .lost: return ("Lost", .red)
            case .mixed: return ("Mixed", .orange)
            case .scalar: return ("Settled", .secondary)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// Newest day first; items inside a day keep their newest-first order.
    static func group(_ items: [SettledBet], includeFees: Bool) -> [Day] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [SettledBet]] = [:]
        for b in items {
            let d = cal.startOfDay(for: b.settledAt)
            if byDay[d] == nil { order.append(d) }
            byDay[d, default: []].append(b)
        }
        return order.map { d in
            let xs = byDay[d]!
            return Day(day: d, items: xs, net: xs.reduce(0) { $0 + $1.net(includeFees: includeFees) })
        }
    }
}
