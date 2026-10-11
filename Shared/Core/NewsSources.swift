import Foundation

enum NewsSourceKind: String, Codable, Sendable {
    case officialAnnouncement, officialStatus, commentary
    var label: String {
        switch self {
        case .officialAnnouncement: "Official release"
        case .officialStatus: "Provider status"
        case .commentary: "Commentary"
        }
    }
}

struct NewsVoice: Identifiable, Sendable {
    let id: String
    let name: String
    let profileURL: URL
    let evidenceURL: URL
    let verifiedAt: String
    let feed: FeedSource?

    private static func voice(_ id: String, _ name: String, _ handle: String, _ articles: String?, _ evidence: String) -> Self {
        Self(id: "voice-" + id, name: name, profileURL: URL(string: "https://x.com/" + handle)!,
             evidenceURL: URL(string: evidence)!, verifiedAt: "2026-10-11",
             feed: articles.map { FeedSource(id: "voice-" + id, name: name, url: URL(string: $0)!, kind: .commentary) })
    }
    static let catalog: [Self] = [
        voice("simonw", "Simon Willison", "simonw", "https://simonwillison.net/tags/llms.atom", "https://simonwillison.net/about/"),
        voice("emollick", "Ethan Mollick", "emollick", "https://www.oneusefulthing.org/feed", "https://www.oneusefulthing.org/about"),
        voice("karpathy", "Andrej Karpathy", "karpathy", "https://karpathy.bearblog.dev/feed/", "https://karpathy.ai/"),
        voice("bcherny", "Boris Cherny", "bcherny", "https://borischerny.com/feed.xml", "https://borischerny.com/about/"),
        voice("embirico", "Alexander Embiricos", "embirico", nil, "https://github.com/embirico"),
    ]
}

enum NewsStatusSource {
    static let catalog: [FeedSource] = [
        FeedSource(id: "status-openai", name: "OpenAI status", url: URL(string: "https://status.openai.com/feed.atom")!, provider: .openai, kind: .officialStatus),
        FeedSource(id: "status-claude", name: "Claude status", url: URL(string: "https://status.claude.com/history.atom")!, provider: .claude, kind: .officialStatus),
    ]
}
