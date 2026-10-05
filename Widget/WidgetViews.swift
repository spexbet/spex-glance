import WidgetKit
import SwiftUI

/// Widget in the app's palette (D4): small is a cobalt tile with cream digits, like the money
/// tiles in the window; medium and large sit on paper/navy with Space Grotesk numbers.
/// Every family stamps "as of" — WidgetKit refreshes on a budget, so it's never truly live.
struct OpenBetsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OpenBetsEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                family == .systemSmall && !entry.notConnected ? Brand.cobalt : Brand.ground
            }
    }

    @ViewBuilder private var content: some View {
        if entry.notConnected {
            notConnected
        } else if let snap = entry.snapshot {
            switch family {
            case .systemSmall: SmallView(snap: snap)
            case .systemMedium: MediumView(snap: snap)
            case .systemLarge: LargeView(snap: snap)
            default: SmallView(snap: snap)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "eyeglasses").font(.title2).foregroundStyle(Brand.cobalt)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notConnected: some View {
        VStack(spacing: 6) {
            Image(systemName: "link.badge.plus").font(.title2).foregroundStyle(Brand.cobalt)
            Text("Open Spex Glance to connect Kalshi").font(.caption).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Shared bits

private func pnlColor(_ v: Double?) -> Color { Fmt.pnlColor(v) }

/// "SPEX ·  as of 2:41 PM" with a warning glyph when the last refresh failed.
private struct Header: View {
    let snap: PortfolioSnapshot
    var onCobalt = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "eyeglasses").font(.caption2.weight(.semibold))
            Text("SPEX").font(Brand.display(10, weight: .medium)).tracking(1)
            if snap.environment == .demo {
                Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(Brand.ember)
            }
            Spacer(minLength: 2)
            if snap.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Brand.ember)
            }
            Text("as of \(snap.updatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 9)).monospacedDigit()
        }
        .foregroundStyle(onCobalt ? Brand.cream.opacity(0.85) : Color.secondary)
    }
}

/// Short status for a widget row: "LIVE", "Final", or the start time.
private func statusText(_ g: EventGroup) -> (String, Bool)? {
    if g.isLive { return ("LIVE", true) }
    if g.isFinal { return ("Final", false) }
    if let st = g.startTime { return (Fmt.gameTime(st), false) }
    return nil
}

private struct GroupLine: View {
    let group: EventGroup

    /// "Yes · Vegas 24% · No · Over 8.5 runs 61%" or the combo's legs.
    private var detail: String {
        if let b = group.bets.first, let legs = b.legs {
            let pct = b.sideProbability.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            return legs.map(\.sideTitle).joined(separator: " + ") + pct
        }
        return group.bets.map { bet in
            if bet.isSettledUnpriced { return bet.positionLabel + " settled" }
            switch bet.outcome {
            case .won: return bet.positionLabel + " won"
            case .lost: return bet.positionLabel + " lost"
            case .pending:
                let pct = bet.sideProbability.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                return bet.positionLabel + pct
            }
        }.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: group.isCombo ? "link" : SportGlyph.symbol(for: group.sport ?? ""))
                .font(.caption2).foregroundStyle(Brand.cobalt).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(group.isCombo ? "\(group.bets.first?.legs?.count ?? 0)-leg combo" : group.title)
                        .font(.caption.weight(.semibold)).lineLimit(1)
                    if let st = statusText(group) {
                        Text(st.0).font(.system(size: 8, weight: st.1 ? .bold : .regular))
                            .foregroundStyle(st.1 ? Color.red : Color.secondary)
                            .lineLimit(1)
                    }
                }
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Fmt.dollars(group.unrealized, signed: true))
                .font(Brand.display(12).monospacedDigit())
                .foregroundStyle(pnlColor(group.unrealized))
        }
    }
}

// MARK: - Families

/// Cobalt tile: unrealized P&L big, game count and total under it. Cream on cobalt reads in
/// both appearances; the sign and a ▲/▼ carry gain/loss instead of green/red.
struct SmallView: View {
    let snap: PortfolioSnapshot
    var body: some View {
        let u = snap.totalUnrealized
        VStack(alignment: .leading, spacing: 2) {
            Header(snap: snap, onCobalt: true)
            Spacer(minLength: 0)
            Text("UNREALIZED").font(Brand.display(9, weight: .medium)).tracking(0.8)
                .foregroundStyle(Brand.cream.opacity(0.75))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if u != 0 {
                    Image(systemName: u > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2)
                }
                Text(Fmt.dollars(u, signed: true))
                    .font(Brand.display(26).monospacedDigit())
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            .foregroundStyle(Brand.cream)
            Spacer(minLength: 0)
            HStack {
                let live = snap.groups.filter(\.isLive).count
                Text(live > 0 ? "\(snap.groups.count) games · \(live) live" : "\(snap.groups.count) game\(snap.groups.count == 1 ? "" : "s")")
                Spacer()
                Text(Fmt.dollars(snap.sportsTotal)).monospacedDigit()
            }
            .font(Brand.display(10, weight: .medium))
            .foregroundStyle(Brand.cream.opacity(0.85))
        }
    }
}

struct MediumView: View {
    let snap: PortfolioSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Header(snap: snap)
            if snap.bets.isEmpty {
                Spacer()
                Text("No open sports positions").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(snap.groups.prefix(3)) { GroupLine(group: $0) }
                if snap.groups.count > 3 {
                    Text("+\(snap.groups.count - 3) more").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Cash \(Fmt.dollars(snap.balanceDollars)) · Positions \(Fmt.dollars(snap.totalValue))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(Fmt.dollars(snap.totalUnrealized, signed: true))
                    .font(Brand.display(13).monospacedDigit())
                    .foregroundStyle(pnlColor(snap.totalUnrealized))
            }
        }
    }
}

struct LargeView: View {
    let snap: PortfolioSnapshot

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(Brand.display(8, weight: .medium)).tracking(0.7)
                .foregroundStyle(Brand.cream.opacity(0.8))
            Text(value).font(Brand.display(14).monospacedDigit()).foregroundStyle(Brand.cream)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.cobalt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(snap: snap)
            HStack(spacing: 5) {
                tile("Cash", Fmt.dollars(snap.balanceDollars))
                tile("Positions", Fmt.dollars(snap.totalValue))
                tile("Total", Fmt.dollars(snap.sportsTotal))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Unrealized").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if snap.totalRealized != 0 {
                    Text("\(Fmt.dollars(snap.totalRealized, signed: true)) realized")
                        .font(.caption2.monospacedDigit()).foregroundStyle(pnlColor(snap.totalRealized))
                }
                Text(Fmt.dollars(snap.totalUnrealized, signed: true))
                    .font(Brand.display(14).monospacedDigit()).foregroundStyle(pnlColor(snap.totalUnrealized))
            }
            Divider()
            if snap.bets.isEmpty {
                Text("No open sports positions").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snap.groups.prefix(6)) { GroupLine(group: $0) }
                if snap.groups.count > 6 {
                    Text("+\(snap.groups.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !snap.orders.isEmpty {
                Divider()
                Text("RESTING ORDERS").font(Brand.display(8, weight: .medium)).tracking(0.7).foregroundStyle(.secondary)
                ForEach(snap.orders.prefix(2)) { o in
                    HStack {
                        Text("\(o.isBuy ? "Buy" : "Sell") \(Fmt.contracts(o.remaining)) · \(o.isYes ? "Yes" : "No") · \(o.sideTitle)")
                            .font(.caption2).lineLimit(1)
                        Spacer()
                        Text(Fmt.cents(o.limitDollars)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if snap.hiddenNonSports > 0 {
                Text("\(snap.hiddenNonSports) non-sports not shown").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let e = snap.errorMessage {
                Text(e).font(.system(size: 9)).foregroundStyle(Brand.ember).lineLimit(2)
            }
        }
    }
}


#Preview("Small", as: .systemSmall) {
    OpenBetsWidget()
} timeline: {
    OpenBetsEntry(date: .now, snapshot: .sample, notConnected: false)
}

#Preview("Medium", as: .systemMedium) {
    OpenBetsWidget()
} timeline: {
    OpenBetsEntry(date: .now, snapshot: .sample, notConnected: false)
}

#Preview("Large", as: .systemLarge) {
    OpenBetsWidget()
} timeline: {
    OpenBetsEntry(date: .now, snapshot: .sample, notConnected: false)
}
