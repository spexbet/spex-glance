import Foundation
import SwiftUI

public enum Fmt {
    private static let usd: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    public static func dollars(_ v: Double?, signed: Bool = false) -> String {
        guard let v else { return "—" }
        let s = usd.string(from: NSNumber(value: abs(v))) ?? "$0.00"
        if signed { return (v < 0 ? "-" : "+") + s }
        return v < 0 ? "-" + s : s
    }

    /// `dollars`, minus the "$" when Work Mode is on — the one place that rule lives.
    public static func money(_ v: Double?, signed: Bool = false, workMode: Bool) -> String {
        let s = dollars(v, signed: signed)
        return workMode ? s.replacingOccurrences(of: "$", with: "") : s
    }

    /// "Today", "Yesterday", "Sep 28" — section headers for a day of settlements.
    public static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "EEE, MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    /// 0.58 -> "58¢"
    public static func cents(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))¢"
    }

    public static func contracts(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    public static func relative(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    /// "Today 7:08 PM", "Tomorrow 11:00 AM", "Thu 4:00 PM", "Oct 12, 1:00 PM" — in the user's zone.
    public static func gameTime(_ d: Date) -> String {
        let cal = Calendar.current
        let t = DateFormatter(); t.dateFormat = "h:mm a"
        if cal.isDateInToday(d) { return "Today \(t.string(from: d))" }
        if cal.isDateInTomorrow(d) { return "Tomorrow \(t.string(from: d))" }
        if cal.isDateInYesterday(d) { return "Yesterday \(t.string(from: d))" }
        let f = DateFormatter()
        f.dateFormat = abs(d.timeIntervalSinceNow) < 6 * 86400 ? "EEE h:mm a" : "MMM d, h:mm a"
        return f.string(from: d)
    }

    /// "1h 12m" — how long since a game started.
    public static func elapsed(since d: Date) -> String {
        let m = max(0, Int(Date().timeIntervalSince(d) / 60))
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    /// One line for a game header: "LIVE · 1h 12m in", "Today 7:08 PM", "Final · awaiting settlement".
    public static func gameStatus(start: Date?, isLive: Bool, isFinal: Bool = false) -> String? {
        if isFinal { return "Final · awaiting settlement" }
        guard let start else { return isLive ? "LIVE" : nil }
        if isLive { return "LIVE · \(elapsed(since: start)) in" }
        let dt = start.timeIntervalSinceNow
        if dt > 0 && dt < 3 * 3600 { return "\(gameTime(start)) · in \(elapsed(since: Date().addingTimeInterval(-dt)))" }
        return gameTime(start)
    }

    /// Green for gains, red for losses, secondary for zero/unknown. One place, used everywhere.
    public static func pnlColor(_ v: Double?) -> Color {
        guard let v, v != 0 else { return .secondary }
        return v > 0 ? .green : .red
    }
}
