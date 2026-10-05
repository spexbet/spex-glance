import Foundation

/// Who's who in a game, resolved once per refresh from Kalshi's milestone + structured targets.
/// Keyed by milestone id in the snapshot.
public struct GameInfo: Codable, Equatable, Sendable {
    public var kind: String                 // milestone type, e.g. "football_game"
    public var homeID: String?
    public var awayID: String?
    public var home: String?                // "NYG" / "Samsung" / "Alcaraz"
    public var away: String?
}

/// A game's scoreboard, normalized across sports from `GET /live_data/batch`.
/// Left/right follow the way the game is written: away @ home for US-style team sports,
/// home – away for soccer, title order for tennis.
public struct LiveScore: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pre, live, final }
    public struct Side: Codable, Equatable, Sendable {
        public var name: String
        public var score: String
        /// Has the ball / puck advantage / is serving / is batting.
        public var hasPossession: Bool = false
    }
    public var state: State
    public var left: Side
    public var right: Side
    /// "Q4 · 2:31", "Top 8th · 1 out", "P2 · 12:40", "Set 3 · 4–3", "71'", "Halftime", "Final".
    public var status: String
    /// Sport-specific: "2nd & 7 at NYG 35", "Runners on 1st & 3rd · 2–1", "Power play: DET",
    /// "6–4 3–6 · 30–15".
    public var situation: String?
    public var lastPlay: String?
    public var updatedAt: Date
    /// Baseball only, for the diamond: occupied 1st/2nd/3rd, and outs.
    public var bases: [Bool]? = nil
    public var outs: Int? = nil

    /// One line for a collapsed card: "ARI 24 – 36 NYG · Q4 2:31".
    public var compact: String {
        let s = "\(left.name) \(left.score) – \(right.score) \(right.name)"
        return state == .pre ? s : s + " · " + status
    }

    /// The game phase this scoreboard implies; overrides the milestone guess while fresh.
    public var phase: GamePhase {
        switch state { case .pre: return .scheduled; case .live: return .live; case .final: return .ended }
    }
}

public enum LiveScoreParser {
    /// Nil when the shape isn't recognised or there's nothing worth showing yet.
    public static func parse(type: String, details d: [String: JSONValue], info: GameInfo, now: Date = Date()) -> LiveScore? {
        let widget = d["widget_status"]?.string?.lowercased() ?? ""
        let rawStatus = d["status"]?.string?.lowercased() ?? ""
        let state: LiveScore.State = {
            switch widget {
            case "live": return .live
            case "finished", "final": return .final
            case "pre", "none": return .pre
            default:
                if ["closed", "ended", "finished", "complete"].contains(rawStatus) { return .final }
                if ["inprogress", "in_progress", "live"].contains(rawStatus) { return .live }
                return .pre
            }
        }()
        let home = info.home ?? "Home", away = info.away ?? "Away"
        func id(_ k: String) -> String? { d[k]?.string }
        func play(_ v: JSONValue?) -> String? {
            if let s = v?.string { return s }
            return v?["description"]?.string
        }
        var out: LiveScore
        switch type {
        case "football_game":
            let q = d["quarter"]?.int ?? 0
            let clock = d["clock"]?.string ?? ""
            let pos = d["situation"]?["possession_team_id"]?.string
            out = LiveScore(state: state,
                            left: .init(name: away, score: d["away_points"]?.string ?? "0", hasPossession: pos != nil && pos == info.awayID),
                            right: .init(name: home, score: d["home_points"]?.string ?? "0", hasPossession: pos != nil && pos == info.homeID),
                            status: periodLine(state: state, label: q > 4 ? "OT" : q > 0 ? "Q\(q)" : nil, clock: clock, raw: rawStatus),
                            situation: footballSituation(d, info: info),
                            lastPlay: play(d["last_play"]), updatedAt: now)
            if d["is_under_review"]?.bool == true { out.situation = [out.situation, "Under review"].compactMap { $0 }.joined(separator: " · ") }

        case "basketball_game":
            let p = d["period"]?.int ?? 0
            let halves = d["period_type"]?.string?.lowercased() == "half"
            let label: String? = p == 0 ? nil
                : halves ? (p > 2 ? "OT\(p > 3 ? String(p - 2) : "")" : "H\(p)")
                : (p > 4 ? "OT\(p > 5 ? String(p - 4) : "")" : "Q\(p)")
            let pos = d["possession"]?.string?.lowercased()
            func has(_ side: String, _ id: String?) -> Bool { pos != nil && (pos == side || pos == id?.lowercased()) }
            out = LiveScore(state: state,
                            left: .init(name: away, score: d["away_points"]?.string ?? "0", hasPossession: has("away", info.awayID)),
                            right: .init(name: home, score: d["home_points"]?.string ?? "0", hasPossession: has("home", info.homeID)),
                            status: periodLine(state: state, label: label, clock: d["period_remaining_time"]?.string ?? "", raw: rawStatus),
                            situation: nil, lastPlay: play(d["last_play"]), updatedAt: now)

        case "baseball_game":
            let inning = d["inning"]?.int ?? 0
            let top = d["inning_half"]?.int == BaseballFields.topHalf
            let outs = d["outs"]?.int ?? 0
            out = LiveScore(state: state,
                            left: .init(name: away, score: d["away_points"]?.string ?? "0", hasPossession: state == .live && top),
                            right: .init(name: home, score: d["home_points"]?.string ?? "0", hasPossession: state == .live && !top),
                            status: state == .final ? (inning > 9 ? "Final/\(inning)" : "Final")
                                : state == .pre ? "Scheduled"
                                : "\(top ? "Top" : "Bot") \(ordinal(inning)) · \(outs) out\(outs == 1 ? "" : "s")",
                            situation: state == .live ? baseballSituation(d) : nil,
                            lastPlay: play(d["last_play"]), updatedAt: now)
            if state == .live {
                let b = (d["bases"]?.array ?? []).map { $0.bool == true }
                out.bases = (0..<3).map { i in BaseballFields.firstBaseIndex + i < b.count && b[BaseballFields.firstBaseIndex + i] }
                out.outs = outs
            }

        case "hockey_match", "hockey_tournament":
            let p = d["period"]?.int ?? 0
            let label: String? = p == 0 ? nil : p == 4 ? "OT" : p >= 5 ? "SO" : "P\(p)"
            out = LiveScore(state: state,
                            left: .init(name: away, score: d["away_points"]?.string ?? "0"),
                            right: .init(name: home, score: d["home_points"]?.string ?? "0"),
                            status: periodLine(state: state, label: label, clock: d["period_remaining_time"]?.string ?? "", raw: rawStatus),
                            situation: hockeySituation(d, home: home, away: away),
                            lastPlay: play(d["last_play"]), updatedAt: now)

        case let t where t.hasPrefix("soccer"):
            let half = d["half"]?.string?.uppercased() ?? ""
            let minute = d["time"]?.string ?? ""
            let status: String = {
                if state == .final { return d["status_text"]?.string ?? "Full-time" }
                if state == .pre { return "Scheduled" }
                if half == "HT" { return "Halftime" }
                return [minute, half == "ET" ? "Extra time" : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                    .nonEmpty ?? (d["status_text"]?.string ?? "Live")
            }()
            out = LiveScore(state: state,
                            left: .init(name: home, score: d["home_same_game_score"]?.string ?? d["home_score"]?.string ?? "0"),
                            right: .init(name: away, score: d["away_same_game_score"]?.string ?? d["away_score"]?.string ?? "0"),
                            status: status, situation: soccerSituation(d, home: home, away: away),
                            lastPlay: play(d["last_play"]), updatedAt: now)

        case let t where t.hasPrefix("tennis"):
            // competitor1 is the first name in the title (info.home here), competitor2 the second.
            // round_scores = games per set, the current set marked "ongoing"; current_round_score
            // = points in the current game (0/15/30/40); server/advantage = competitor ids.
            let c1 = d["competitor1_id"]?.string, srv = d["server"]?.string
            let r1 = d["competitor1_round_scores"]?.array ?? [], r2 = d["competitor2_round_scores"]?.array ?? []
            let ongoing1 = r1.last.flatMap { $0["outcome"]?.string == "ongoing" ? $0["score"]?.string : nil }
            let ongoing2 = r2.last.flatMap { $0["outcome"]?.string == "ongoing" ? $0["score"]?.string : nil }
            let setNo = (d["completed_rounds"]?.int ?? 0) + 1
            out = LiveScore(state: state,
                            left: .init(name: home, score: d["competitor1_overall_score"]?.string ?? "0",
                                        hasPossession: state == .live && srv != nil && srv == c1),
                            right: .init(name: away, score: d["competitor2_overall_score"]?.string ?? "0",
                                         hasPossession: state == .live && srv != nil && srv != c1),
                            status: state == .final ? "Final" : state == .pre ? "Scheduled"
                                : "Set \(setNo) · \(ongoing1 ?? "0")–\(ongoing2 ?? "0")",
                            situation: tennisSituation(d, live: state == .live, first: home, second: away),
                            lastPlay: nil, updatedAt: now)

        case "cricket_match":
            let txt = d["cricket_result"]?["status_text"]?.string
            func line(_ side: String) -> String {
                let r = d["\(side)_total_runs"]?.string ?? d["\(side)_score"]?.string ?? "0"
                let w = d["\(side)_wickets"]?.string ?? "0"
                return "\(r)/\(w)"
            }
            out = LiveScore(state: state,
                            left: .init(name: home, score: line("home"), hasPossession: d["batting"]?.string == "home"),
                            right: .init(name: away, score: line("away"), hasPossession: d["batting"]?.string == "away"),
                            status: txt ?? (state == .final ? "Final" : "Live"),
                            situation: nil, lastPlay: play(d["last_play"]), updatedAt: now)

        default:
            // Unknown sport: show the scores if Kalshi sends them in the usual names.
            guard d["home_points"] != nil || d["home_score"] != nil else { return nil }
            out = LiveScore(state: state,
                            left: .init(name: away, score: d["away_points"]?.string ?? d["away_score"]?.string ?? "0"),
                            right: .init(name: home, score: d["home_points"]?.string ?? d["home_score"]?.string ?? "0"),
                            status: state == .final ? "Final" : state == .pre ? "Scheduled" : "Live",
                            situation: nil, lastPlay: play(d["last_play"]), updatedAt: now)
        }
        if out.lastPlay?.isEmpty == true { out.lastPlay = nil }
        if state != .live { out.left.hasPossession = false; out.right.hasPossession = false }
        return out
    }

    // MARK: Pieces

    static func periodLine(state: LiveScore.State, label: String?, clock: String, raw: String) -> String {
        if state == .final { return label == "OT" || label?.hasPrefix("OT") == true || label == "SO" ? "Final/\(label!)" : "Final" }
        if state == .pre { return "Scheduled" }
        if raw.contains("half") { return "Halftime" }
        guard let label else { return "Live" }
        let c = clock.hasPrefix("0") && clock.count == 5 ? String(clock.dropFirst()) : clock   // "02:31" → "2:31"
        if c == "0:00" || c.isEmpty { return "End \(label)" }
        return "\(label) · \(c)"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    static func footballSituation(_ d: [String: JSONValue], info: GameInfo) -> String? {
        guard let s = d["situation"], let down = s["down"]?.int, down > 0 else {
            if d["pending_try"]?.bool == true { return "Extra point / two-point try" }
            return nil
        }
        let togo = s["goal_to_go"]?.bool == true ? "Goal" : (s["yfd"]?.string ?? "?")
        var line = "\(ordinal(down)) & \(togo)"
        if let yl = s["yardline"]?.int {
            let side = s["side_team_id"]?.string
            let team = side == info.homeID ? info.home : side == info.awayID ? info.away : nil
            line += yl == 50 ? " at midfield" : " at \(team.map { $0 + " " } ?? "")\(yl)"
        }
        let pos = s["possession_team_id"]?.string
        if let p = pos, let who = p == info.homeID ? info.home : p == info.awayID ? info.away : nil { line += " · \(who) ball" }
        return line
    }

    static func baseballSituation(_ d: [String: JSONValue]) -> String? {
        let b = (d["bases"]?.array ?? []).map { $0.bool == true }
        let occupied = BaseballFields.baseNames.enumerated().compactMap { i, name in
            let idx = BaseballFields.firstBaseIndex + i
            return idx < b.count && b[idx] ? name : nil
        }
        let runners: String = occupied.isEmpty ? "Bases empty"
            : occupied.count == 3 ? "Bases loaded"
            : "Runner\(occupied.count > 1 ? "s" : "") on " + occupied.joined(separator: " & ")
        let count = "\(d["balls"]?.int ?? 0)–\(d["strikes"]?.int ?? 0)"
        return "\(runners) · \(count) count"
    }

    static func hockeySituation(_ d: [String: JSONValue], home: String, away: String) -> String? {
        let h = d["home_strength"]?.string?.lowercased() ?? "even"
        let a = d["away_strength"]?.string?.lowercased() ?? "even"
        if h.contains("power") { return "Power play: \(home)" }
        if a.contains("power") { return "Power play: \(away)" }
        if h.contains("empty") || a.contains("empty") { return "Empty net" }
        return nil
    }

    static func soccerSituation(_ d: [String: JSONValue], home: String, away: String) -> String? {
        func reds(_ k: String) -> Int {
            (d[k]?.array ?? []).filter { ($0["event_type"]?.string ?? "").contains("red") }.count
        }
        var parts: [String] = []
        let hr = reds("home_significant_events"), ar = reds("away_significant_events")
        if hr > 0 { parts.append("\(home) \(hr) red") }
        if ar > 0 { parts.append("\(away) \(ar) red") }
        if d["show_penalties"]?.bool == true, let p = d["penalties_text"]?.string { parts.append("Pens \(p)") }
        if let agg = d["aggregate_text"]?.string { parts.append(agg) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Completed sets, then the current game: "6–4 · 30–15", "Deuce", "Ad Gaillard".
    static func tennisSituation(_ d: [String: JSONValue], live: Bool, first: String, second: String) -> String? {
        let r1 = d["competitor1_round_scores"]?.array ?? [], r2 = d["competitor2_round_scores"]?.array ?? []
        var sets: [String] = []
        for i in 0..<min(r1.count, r2.count) where r1[i]["outcome"]?.string != "ongoing" {
            let a = r1[i]["score"]?.string ?? "0", b = r2[i]["score"]?.string ?? "0"
            var s = "\(a)–\(b)"
            if let ta = r1[i]["tiebreak_score"]?.int, let tb = r2[i]["tiebreak_score"]?.int { s += "(\(min(ta, tb)))" }
            sets.append(s)
        }
        var parts: [String] = []
        if !sets.isEmpty { parts.append(sets.joined(separator: " ")) }
        if live {
            let c1 = d["competitor1_id"]?.string
            let p1 = d["competitor1_current_round_score"]?.string ?? "0", p2 = d["competitor2_current_round_score"]?.string ?? "0"
            if let adv = d["advantage"]?.string {
                parts.append("Ad \(adv == c1 ? first : second)")
            } else if p1 == "40" && p2 == "40" {
                parts.append("Deuce")
            } else if !(p1 == "0" && p2 == "0") {
                parts.append("\(p1)–\(p2)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Field meanings in Kalshi's baseball feed, pinned down by watching live games.
enum BaseballFields {
    /// `inning_half` value for the top of the inning (away team batting).
    static let topHalf = 1
    /// Index in `bases` of first base; the next two are second and third.
    static let firstBaseIndex = 0
    static let baseNames = ["1st", "2nd", "3rd"]
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
