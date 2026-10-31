import Foundation

/// What windows are called on screen and in alerts. A session is named by its length ("5-hour"),
/// since "Session" doesn't say how long one lasts; every other window keeps its provider's title.
enum WindowNames {
    /// "5-hour" for a session (sessions are 5 hours unless the provider says otherwise), keeping
    /// what the provider puts before "session" ("Gemini 5-hour"); the title otherwise.
    static func title(kind: WindowKind, title: String, seconds: Double?) -> String {
        guard kind == .session else { return title }
        let hours = Int(((seconds ?? 5 * 3600) / 3600).rounded())
        guard hours > 0 else { return title }
        let qualifier = title.lowercased().hasSuffix(" session") ? String(title.dropLast(" session".count)) : ""
        return qualifier.isEmpty ? "\(hours)-hour" : "\(qualifier) \(hours)-hour"
    }

    /// The limit as a noun inside a sentence: "5-hour limit", "weekly limit", "daily limit",
    /// "Opus weekly limit", "limit for premium requests".
    static func limit(kind: WindowKind, title: String, seconds: Double?) -> String {
        switch kind {
        case .session:
            return "\(inSentence(Self.title(kind: kind, title: title, seconds: seconds))) limit"
        case .daily where title == "Today":
            return "daily limit"
        case .weekly, .daily:
            return "\(inSentence(title)) limit"
        case .monthly, .billingCycle, .pool:
            return "limit for \(inSentence(title))"
        }
    }

    /// A title inside a sentence: lowercased when it starts with an ordinary word ("weekly",
    /// "this cycle"), as written when it starts with a name ("Opus weekly", "Cursor Models",
    /// "AI credits").
    static func inSentence(_ title: String) -> String {
        let first = title.prefix { !$0.isWhitespace }
        return ordinaryWords.contains(String(first)) ? title.lowercased() : title
    }

    private static let ordinaryWords: Set<String> = [
        "Session", "Weekly", "Daily", "Monthly", "Today", "This", "Premium", "Chat", "Completions",
        "Credits", "Balance", "Overage", "Prepaid", "Spend", "Extra", "Booster", "Code", "Web", "Other",
    ]
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
