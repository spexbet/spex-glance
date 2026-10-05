import SwiftUI

// Rows laid out the way Kalshi's own portfolio does it, so nothing needs re-learning:
//
//   Game card      "CHI Blackhawks vs VGK Golden Knights"      LIVE · Hockey        −$63.89
//   Position       Yes · Vegas                                  24% chance ▼
//                  2nd Period Winner · Cost $100.00             Pays $209.47
//   Combo card     3 MARKET COMBO                               99% chance ▲       +$35.54
//                  $287.90 pays $325.82
//                  BASEBALL  Game 1: Chicago C vs San Diego
//                    San Diego to win                                   99%
//                    San Diego over 6.5 runs scored                     99%
//                  HOCKEY    Vancouver vs Edmonton
//                    No · Edmonton wins by over 1.5 goals               99%

/// "24% chance ▼" — colored by whether your side is worth more than you paid.
struct ChanceLabel: View {
    let bet: OpenBet
    var font: Font = .body

    var body: some View {
        if bet.isSettledUnpriced {
            Label("Settled", systemImage: "flag.checkered").font(font.weight(.semibold)).foregroundStyle(.secondary)
        } else {
        switch bet.outcome {
        case .won:
            Label("Won", systemImage: "checkmark.circle.fill").font(font.weight(.semibold)).foregroundStyle(.green)
        case .lost:
            Label("Lost", systemImage: "xmark.circle.fill").font(font.weight(.semibold)).foregroundStyle(.red)
        case .pending:
            let p = bet.sideProbability
            let up = p.map { $0 >= bet.avgCostDollars }
            HStack(spacing: 3) {
                Text(p.map { "\(Int(($0 * 100).rounded()))% chance" } ?? "— chance")
                if let up { Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.caption2) }
            }
            .font(font.monospacedDigit().weight(.semibold))
            .foregroundStyle(up == nil ? Color.secondary : up! ? Color.green : Color.red)
        }
        }
    }
}

/// "Value $52.11" — what the position would fetch now, colored by whether that beats the cost.
struct ValueLabel: View {
    let bet: OpenBet
    var body: some View {
        let v = bet.currentDollars.map { $0 * bet.contracts }
        let up = v.map { $0 >= bet.costDollars }
        Text(bet.isSettledUnpriced ? "Settled · see Kalshi for payout"
             : bet.outcome == .won ? "Won \(Fmt.dollars(bet.maxPayout))"
             : bet.outcome == .lost ? "Lost \(Fmt.dollars(bet.costDollars))"
             : v.map { "Value \(Fmt.dollars($0))" } ?? "Value —")
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(up == nil ? Color.secondary : up! ? Color.green : Color.red)
    }
}

/// One held market inside a game card.
/// Collapsed:  Yes · Vegas · 2nd Period Winner            Value $2.10 · pays $209.47
/// Expanded adds cost, chance and P&L.
struct PositionRow: View {
    let bet: OpenBet
    var expanded = false
    @Environment(\.workMode) private var workMode

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(bet.positionLabel).fontWeight(.semibold)
                    if let q = bet.qualifier { Text(q).font(.caption).foregroundStyle(.secondary) }
                }
                if expanded {
                    // Work Mode: no position size on screen at all.
                    if !workMode {
                        Text("Cost \(Fmt.dollars(bet.costDollars)) · \(Fmt.contracts(bet.contracts)) @ \(Fmt.cents(bet.avgCostDollars))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(bet.ticker).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if workMode {
                    // Work Mode: no money at all — the chance carries the row.
                    ChanceLabel(bet: bet, font: .body)
                } else {
                    HStack(spacing: 6) {
                        ValueLabel(bet: bet)
                        Text("· pays \(Fmt.dollars(bet.maxPayout))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if expanded {
                        ChanceLabel(bet: bet, font: .caption)
                        if let u = bet.unrealizedPnL {
                            Text("\(Fmt.dollars(u, signed: true)) unrealized").font(.caption.monospacedDigit()).foregroundStyle(Fmt.pnlColor(u))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// The legs of a combo, grouped by sport → game, Kalshi style. Always expanded.
struct ComboLegsView: View {
    let legs: [ComboLeg]
    /// Scoreboards by milestone id; each game in the combo shows its own score when on.
    var scores: [String: LiveScore] = [:]

    private var grouped: [(sport: String, games: [(title: String, legs: [ComboLeg])])] {
        var sportOrder: [String] = [], bySport: [String: [ComboLeg]] = [:]
        for l in legs {
            let s = l.sport ?? "Other"
            if bySport[s] == nil { sportOrder.append(s) }
            bySport[s, default: []].append(l)
        }
        return sportOrder.map { s in
            var gameOrder: [String] = [], byGame: [String: [ComboLeg]] = [:]
            for l in bySport[s]! {
                let k = l.gameKey.isEmpty ? l.gameTitle : l.gameKey
                if byGame[k] == nil { gameOrder.append(k) }
                byGame[k, default: []].append(l)
            }
            return (s, gameOrder.map { (byGame[$0]![0].gameTitle, byGame[$0]!) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(grouped, id: \.sport) { g in
                HStack(spacing: 4) {
                    Image(systemName: SportGlyph.symbol(for: g.sport)).font(.caption2)
                    Text(g.sport.uppercased()).font(.caption2.weight(.semibold)).tracking(0.5)
                }
                .foregroundStyle(.secondary)
                ForEach(g.games, id: \.title) { game in
                    let live = game.legs.contains { $0.isLive }
                    let sc = game.legs.lazy.compactMap { $0.milestoneID.flatMap { scores[$0] } }.first
                    HStack(spacing: 6) {
                        Text(game.title).font(.callout.weight(.medium))
                        if live, let sc, sc.state == .live {
                            Text("LIVE · " + sc.status).font(.caption).foregroundStyle(Color.red)
                        } else if let st = Fmt.gameStatus(start: game.legs.compactMap(\.startTime).min(), isLive: live) {
                            Text(st).font(.caption).foregroundStyle(live ? Color.red : Color.secondary)
                        }
                    }
                    if let sc, sc.state != .pre {
                        HStack(spacing: 6) {
                            ScoreLine(score: sc, font: .caption)
                            if let sit = sc.situation { Text("· " + sit).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    ForEach(game.legs) { leg in
                        HStack {
                            Rectangle().fill(.quaternary).frame(width: 2)
                            legName(leg)
                            Spacer()
                            legState(leg)
                        }
                        .font(.callout)
                        .padding(.leading, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder private func legName(_ leg: ComboLeg) -> some View {
        switch leg.outcome {
        case .missed: Text(leg.label).strikethrough().foregroundStyle(.red)
        case .hit: Text(leg.label)
        case .pending: Text(leg.label)
        }
    }
    @ViewBuilder private func legState(_ leg: ComboLeg) -> some View {
        switch leg.outcome {
        case .hit: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            HStack(spacing: 4) {
                Text(leg.hitProbability.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

/// SF Symbol for a Kalshi sport tag. Unknown tags get a generic glyph.
enum SportGlyph {
    static func symbol(for sport: String) -> String {
        switch sport.lowercased() {
        case "": return "square.grid.2x2"
        case "baseball", "mlb": return "figure.baseball"
        case "basketball", "nba", "wnba", "college basketball": return "figure.basketball"
        case "football", "nfl", "college football": return "figure.american.football"
        case "hockey", "nhl": return "figure.hockey"
        case "tennis": return "figure.tennis"
        case "soccer", "football (soccer)", "mls": return "figure.indoor.soccer"
        case "golf": return "figure.golf"
        case "mma", "ufc", "boxing": return "figure.boxing"
        case "racing", "f1", "formula 1", "nascar": return "flag.checkered"
        case "cricket": return "figure.cricket"
        case "combos": return "link"
        default: return "sportscourt"
        }
    }
}

/// Work Mode, handed down from the window so shared row views can hide money without
/// reaching into app preferences.
private struct WorkModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var workMode: Bool {
        get { self[WorkModeKey.self] }
        set { self[WorkModeKey.self] = newValue }
    }
}
