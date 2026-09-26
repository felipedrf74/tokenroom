import Foundation

/// News as one edition: what's new since the last visit, one top story, the tools' own news
/// grouped by tool, and models retiring soon. Built from what `NewsStore` holds; the iPhone's
/// Today view and the Mac's News window both read it.
struct NewsEdition: Equatable, Sendable {
    struct Digest: Equatable, Sendable {
        var models: Int
        var updates: Int
        var retiring: Int

        var isEmpty: Bool { models == 0 && updates == 0 && retiring == 0 }
    }

    /// One tool's announcements, newest first.
    struct Tool: Equatable, Sendable, Identifiable {
        /// The feed's name, e.g. "Claude Code".
        var id: String { source }
        var source: String
        var provider: Provider?
        /// "Changelog", "Releases", "News".
        var kind: String
        var items: [FeedItem]
        /// Items published since the last visit.
        var newCount: Int
    }

    var digest: Digest
    /// The newest model from a followed lab, when it's recent enough to lead with.
    var topStory: ModelRelease?
    var moreModels: [ModelRelease]
    var tools: [Tool]
    var retiring: [ModelRelease]
}

enum NewsEditions {
    /// A top story older than this isn't news any more; the edition leads with its tools instead.
    static let topStoryAge: TimeInterval = 14 * 86_400
    /// Models retiring within this long are "soon".
    static let retiringHorizon: TimeInterval = 30 * 86_400
    static let moreModelsLimit = 8
    static let itemsPerTool = 3

    /// - Parameters:
    ///   - models: followed labs' models, newest first.
    ///   - announcements: followed feeds' items, newest first, duplicates folded.
    ///   - retiring: every model with an announced retirement, soonest first.
    ///   - since: the last visit; newer items count as new.
    static func today(models: [ModelRelease], announcements: [FeedItem], retiring: [ModelRelease], since: Date, now: Date = .now) -> NewsEdition {
        let soon = retiring.filter { expires in
            guard let date = expires.expires else { return false }
            return date > now && date.timeIntervalSince(now) <= retiringHorizon
        }
        let top = models.first.flatMap { now.timeIntervalSince($0.created) <= topStoryAge ? $0 : nil }
        let more = Array(models.dropFirst(top == nil ? 0 : 1).prefix(moreModelsLimit))
        return NewsEdition(
            digest: NewsEdition.Digest(
                models: models.filter { $0.created > since }.count,
                updates: announcements.filter { ($0.published ?? .distantPast) > since }.count,
                retiring: soon.count
            ),
            topStory: top,
            moreModels: more,
            tools: tools(announcements, since: since),
            retiring: soon
        )
    }

    /// Announcements grouped by the feed that published them, the tool with the newest item first.
    static func tools(_ announcements: [FeedItem], since: Date) -> [NewsEdition.Tool] {
        var order: [String] = []
        var grouped: [String: [FeedItem]] = [:]
        for item in announcements {
            if grouped[item.source] == nil { order.append(item.source) }
            grouped[item.source, default: []].append(item)
        }
        return order.map { source in
            let items = grouped[source] ?? []
            let feed = FeedSource.catalog.first { $0.name == source }
            return NewsEdition.Tool(
                source: source,
                provider: feed?.provider,
                kind: feed.map(kind) ?? "News",
                items: Array(items.prefix(itemsPerTool)),
                newCount: items.filter { ($0.published ?? .distantPast) > since }.count
            )
        }
    }

    /// What a feed carries, from its address: GitHub releases, a changelog, or news.
    static func kind(of feed: FeedSource) -> String {
        let address = feed.url.absoluteString.lowercased()
        if address.contains("/releases.atom") { return "Releases" }
        if address.contains("changelog") || address.contains("release-notes") { return "Changelog" }
        return "News"
    }

    /// The provider whose icon and tint stand for a lab in News: its own organization where
    /// Tokenroom has one. Google has none, so its models show a monogram.
    static let labProviders: [String: Provider] = [
        "anthropic": .anthropicOrg, "openai": .openai, "x-ai": .xaiOrg, "z-ai": .zai,
        "moonshotai": .moonshot, "minimax": .minimax, "deepseek": .deepseek,
    ]
}

extension ModelRelease {
    /// "1M", "400K".
    var contextText: String? {
        guard let context = contextLength, context > 0 else { return nil }
        return context.formatted(.number.notation(.compactName))
    }

    /// Days until it retires, counting a part day as one.
    func daysUntilRetirement(now: Date = .now) -> Int? {
        guard let expires, expires > now else { return nil }
        return Int((expires.timeIntervalSince(now) / 86_400).rounded(.up))
    }
}
