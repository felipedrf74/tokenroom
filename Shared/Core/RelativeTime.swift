import Foundation

enum RelativeTime {
    static func resets(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "reset due" }
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(max(minutes, 1))m"
    }

    /// How long until `date`, short enough for a widget row: rounded to the nearest hour up to
    /// three days ("23h", "2d 22h"), and to the nearest day past that ("12d"), where the hour
    /// no longer matters and a row needs the room for its window's name. Widgets show this
    /// from an hour out; inside the hour they tick. Every form follows the rounded hours, so
    /// timeline entries land where it moves (`ReadingCache.countdownDates`).
    static func remaining(until date: Date, now: Date = .now) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        return remaining(hours: Int((seconds / 3_600).rounded()))
    }

    /// The same for a whole number of hours left.
    static func remaining(hours rounded: Int) -> String {
        let hours = max(1, rounded)
        if hours >= 72 { return "\((hours + 12) / 24)d" }
        let days = hours / 24
        if days == 0 { return "\(hours)h" }
        return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h"
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3_600)))h ago" }
        return "\(max(1, Int(seconds / 86_400)))d ago"
    }

    static func cycleDay(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "resets \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }
}
