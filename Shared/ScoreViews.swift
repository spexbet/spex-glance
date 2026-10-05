import SwiftUI

/// "● ARI 24 – 36 NYG" — one line, leader bold, a cobalt dot on whoever has the ball, is
/// serving or is batting. Used on collapsed cards, combo legs and the menu bar.
struct ScoreLine: View {
    let score: LiveScore
    var font: Font = .callout

    var body: some View {
        let l = Double(score.left.score), r = Double(score.right.score)
        let leftLeads = (l ?? 0) > (r ?? 0), rightLeads = (r ?? 0) > (l ?? 0)
        HStack(spacing: 5) {
            dot(score.left.hasPossession)
            Text(score.left.name).fontWeight(leftLeads ? .semibold : .regular)
            Text(score.left.score).fontWeight(leftLeads ? .bold : .regular).monospacedDigit()
            Text("–").foregroundStyle(.secondary)
            Text(score.right.score).fontWeight(rightLeads ? .bold : .regular).monospacedDigit()
            Text(score.right.name).fontWeight(rightLeads ? .semibold : .regular)
            dot(score.right.hasPossession)
        }
        .font(font)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(score.left.name) \(score.left.score), \(score.right.name) \(score.right.score)")
    }

    @ViewBuilder private func dot(_ on: Bool) -> some View {
        Circle().fill(Brand.cobalt).frame(width: 6, height: 6).opacity(on ? 1 : 0)
    }
}

/// The expanded scoreboard: big score with the period/clock between, then the sport's own
/// situation (down & distance, runners and count, power play, sets and points), the last play,
/// and for baseball a little diamond with the outs.
struct ScoreCard: View {
    let score: LiveScore
    let sport: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                side(score.left, alignment: .leading)
                Spacer(minLength: 4)
                VStack(spacing: 2) {
                    Text(score.state == .live ? "LIVE" : score.state == .final ? "FINAL" : "UPCOMING")
                        .font(.caption2.weight(.bold)).tracking(0.6)
                        .foregroundStyle(score.state == .live ? Color.red : Color.secondary)
                    Text(score.status).font(.caption.weight(.medium)).monospacedDigit()
                        .multilineTextAlignment(.center).lineLimit(2)
                }
                .frame(minWidth: 90)
                Spacer(minLength: 4)
                side(score.right, alignment: .trailing)
            }
            if score.bases != nil || score.situation != nil {
                HStack(spacing: 10) {
                    if let bases = score.bases { Diamond(bases: bases, outs: score.outs ?? 0) }
                    if let s = score.situation {
                        Text(s).font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let p = score.lastPlay {
                Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Live data from Kalshi · \(Fmt.relative(score.updatedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func side(_ s: LiveScore.Side, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            HStack(spacing: 4) {
                if alignment == .trailing, s.hasPossession { possessionMark }
                Text(s.name).font(.caption.weight(.semibold)).lineLimit(1)
                if alignment == .leading, s.hasPossession { possessionMark }
            }
            Text(s.score).font(Brand.display(26).monospacedDigit())
        }
    }

    /// Ball, serve or at-bat, depending on the sport.
    private var possessionMark: some View {
        let symbol: String = {
            switch (sport ?? "").lowercased() {
            case "football": return "football.fill"
            case "basketball": return "basketball.fill"
            case "tennis": return "tennisball.fill"
            case "baseball": return "figure.baseball"
            default: return "circle.fill"
            }
        }()
        return Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(Brand.cobalt)
            .accessibilityLabel((sport ?? "").lowercased() == "tennis" ? "serving" : (sport ?? "").lowercased() == "baseball" ? "batting" : "has possession")
    }
}

/// Three bases as small diamonds (filled = runner) with outs as dots underneath.
private struct Diamond: View {
    let bases: [Bool]   // 1st, 2nd, 3rd
    let outs: Int

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                base(bases.count > 1 && bases[1]).offset(y: -7)          // 2nd
                base(bases.count > 2 && bases[2]).offset(x: -8)          // 3rd
                base(bases.count > 0 && bases[0]).offset(x: 8)           // 1st
            }
            .frame(width: 28, height: 22)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(i < outs ? Color.primary : Color.secondary.opacity(0.25)).frame(width: 4, height: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runners: " + (["first", "second", "third"].enumerated().filter { $0.offset < bases.count && bases[$0.offset] }.map(\.element).joined(separator: ", ").nonEmpty ?? "none") + ", \(outs) out")
    }

    private func base(_ on: Bool) -> some View {
        Rectangle()
            .fill(on ? Brand.cobalt : Color.clear)
            .overlay(Rectangle().stroke(on ? Brand.cobalt : Color.secondary, lineWidth: 1))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
    }
}
