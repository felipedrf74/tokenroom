import Foundation

/// What windows are called on screen and in alerts. A session is named by its length ("5-hour"),
/// since "Session" doesn't say how long one lasts; every other window keeps its provider's title.
enum WindowNames {
    /// "5-hour" for a session (sessions are 5 hours unless the provider says otherwise); the
    /// title otherwise.
    static func title(kind: WindowKind, title: String, seconds: Double?) -> String {
        guard kind == .session else { return title }
        let hours = Int(((seconds ?? 5 * 3600) / 3600).rounded())
        return hours > 0 ? "\(hours)-hour" : title
    }

    /// The limit as a noun inside a sentence: "5-hour limit", "weekly limit", "daily limit",
    /// "limit for premium requests".
    static func limit(kind: WindowKind, title: String, seconds: Double?) -> String {
        switch kind {
        case .session:
            return "\(Self.title(kind: kind, title: title, seconds: seconds)) limit"
        case .weekly, .daily:
            return "\(title.lowercased()) limit"
        case .monthly, .billingCycle, .pool:
            return "limit for \(title.lowercased())"
        }
    }
}

extension RelayWindow {
    var displayTitle: String {
        WindowNames.title(kind: windowKind, title: title, seconds: periodSec)
    }

    var limitName: String {
        WindowNames.limit(kind: windowKind, title: title, seconds: periodSec)
    }
}

extension QuotaWindow {
    var displayTitle: String {
        WindowNames.title(kind: kind, title: title, seconds: windowSeconds)
    }
}
