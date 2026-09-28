import Foundation

enum NewsSearch {
    static func matches(_ query: String, title: String, source: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query) || source.localizedCaseInsensitiveContains(query)
    }
}

struct NewsEmptyPresentation {
    var title: String
    var message: String

    static func make(section: NewsFilter, searching: Bool, hasLabs: Bool, hasSources: Bool, problem: String?) -> Self {
        if searching { return .init(title: "No matching results", message: "Try another title, lab, or source.") }
        if section == .models, !hasLabs { return .init(title: "No labs followed", message: "Choose labs in Follow, or show all cached models.") }
        if section == .announcements, !hasSources { return .init(title: "No sources followed", message: "Choose official sources in Follow.") }
        if section == .today, !hasLabs, !hasSources { return .init(title: "Nothing followed yet", message: "Choose labs and official sources in Follow.") }
        if let problem { return .init(title: "Couldn't load this section", message: problem) }
        if section == .retiring { return .init(title: "No upcoming retirements", message: "No models in the cached list are due to retire.") }
        return .init(title: "No news yet", message: "Check again, or change what you follow.")
    }
}
