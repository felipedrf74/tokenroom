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

/// A public author or publication, followed through its public article feed. Names, X handles and
/// feed URLs here are what each one publishes about itself (`evidenceURL`), checked on `verifiedAt`.
struct NewsVoice: Identifiable, Sendable {
    /// A person or a publication's own voice, or a source of what the industry is discussing
    /// (Techmeme, Hugging Face's blog). Both are commentary, checked as rarely; Following lists
    /// them apart.
    enum Role: Sendable { case voice, discussion }

    let id: String
    let name: String
    let profileURL: URL
    let evidenceURL: URL
    let verifiedAt: String
    let feed: FeedSource?
    let role: Role

    private static func voice(_ id: String, _ name: String, _ handle: String, _ articles: String?, _ evidence: String,
                              verifiedAt: String = "2026-10-11", role: Role = .voice) -> Self {
        let id = (role == .discussion ? "discussion-" : "voice-") + id
        return Self(id: id, name: name, profileURL: URL(string: "https://x.com/" + handle)!,
                    evidenceURL: URL(string: evidence)!, verifiedAt: verifiedAt,
                    feed: articles.map { FeedSource(id: id, name: name, url: URL(string: $0)!, kind: .commentary) }, role: role)
    }

    static let catalog: [Self] = [
        voice("simonw", "Simon Willison", "simonw", "https://simonwillison.net/tags/llms.atom", "https://simonwillison.net/about/"),
        voice("emollick", "Ethan Mollick", "emollick", "https://www.oneusefulthing.org/feed", "https://www.oneusefulthing.org/about"),
        voice("karpathy", "Andrej Karpathy", "karpathy", "https://karpathy.bearblog.dev/feed/", "https://karpathy.ai/"),
        voice("bcherny", "Boris Cherny", "bcherny", "https://borischerny.com/feed.xml", "https://borischerny.com/about/"),
        // Added November 2026. Each feed answered 200 with entries from that week, under 2 MB, and
        // each about page links the X handle used here.
        voice("importai", "Import AI", "jackclarksf", "https://importai.substack.com/feed", "https://importai.substack.com/about", verifiedAt: "2026-11-07"),
        voice("interconnects", "Interconnects", "natolambert", "https://www.interconnects.ai/feed", "https://www.interconnects.ai/about", verifiedAt: "2026-11-07"),
        voice("latentspace", "Latent Space", "latentspacepod", "https://www.latent.space/feed", "https://www.latent.space/about", verifiedAt: "2026-11-07"),
        voice("mitsuhiko", "Armin Ronacher", "mitsuhiko", "https://lucumr.pocoo.org/feed.atom", "https://lucumr.pocoo.org/about/", verifiedAt: "2026-11-07"),
        voice("mitchellh", "Mitchell Hashimoto", "mitchellh", "https://mitchellh.com/feed.xml", "https://mitchellh.com/about", verifiedAt: "2026-11-07"),
        voice("techmeme", "Techmeme", "Techmeme", "https://www.techmeme.com/feed.xml", "https://www.techmeme.com/about", verifiedAt: "2026-11-07", role: .discussion),
        voice("huggingface", "Hugging Face", "huggingface", "https://huggingface.co/blog/feed.xml", "https://huggingface.co/blog", verifiedAt: "2026-11-07", role: .discussion),
    ]

    /// What a new install follows: daily builders' notes and the weekly research and industry
    /// letters. An update never adds to what an existing install follows (`NewsStore.newSources`).
    static let newInstallFollows: Set<String> = ["voice-simonw", "voice-interconnects", "voice-importai", "voice-latentspace"]
}

enum NewsStatusSource {
    static let catalog: [FeedSource] = [
        FeedSource(id: "status-openai", name: "OpenAI status", url: URL(string: "https://status.openai.com/feed.atom")!, provider: .openai, kind: .officialStatus),
        FeedSource(id: "status-claude", name: "Claude status", url: URL(string: "https://status.claude.com/history.atom")!, provider: .claude, kind: .officialStatus),
        // Added November 2026.
        FeedSource(id: "status-github", name: "GitHub status", url: URL(string: "https://www.githubstatus.com/history.atom")!, provider: .copilot, kind: .officialStatus),
        FeedSource(id: "status-openrouter", name: "OpenRouter status", url: URL(string: "https://status.openrouter.ai/history.atom")!, provider: .openrouter, kind: .officialStatus),
        // The page calls itself "SpaceXAI System Status" and reports Grok, Grok Bot and Cursor:
        // Cursor's own status page (status.cursor.com) redirects here, so it's named for both.
        FeedSource(id: "status-spacexai", name: "SpaceXAI status (Grok, Cursor)", url: URL(string: "https://status.x.ai/feed.xml")!, provider: .grok, kind: .officialStatus),
    ]
}
