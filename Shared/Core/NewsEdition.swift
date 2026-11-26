import Foundation

struct NewsEdition: Equatable, Sendable {
    struct Digest: Equatable, Sendable {
        var models: Int
        var updates: Int
        var retiring: Int

        var isEmpty: Bool { models == 0 && updates == 0 && retiring == 0 }
    }

    struct Tool: Equatable, Sendable, Identifiable {
        var id: String { sourceID ?? source }
        var sourceID: String? = nil
        var source: String
        var provider: Provider?
        var kind: String
        var items: [FeedItem]
        var newCount: Int
    }

    var digest: Digest
    var topStory: ModelRelease?
    var moreModels: [ModelRelease]
    var tools: [Tool]
    var retiring: [ModelRelease]

    var isEmpty: Bool { topStory == nil && moreModels.isEmpty && tools.isEmpty && retiring.isEmpty }
}

enum NewsEditions {
    static let topStoryAge: TimeInterval = 14 * 86_400
    static let retiringHorizon: TimeInterval = 30 * 86_400
    static let moreModelsLimit = 8
    static let itemsPerTool = 3

    static func isTopStoryDate(_ date: Date, now: Date = .now) -> Bool {
        (0...topStoryAge).contains(now.timeIntervalSince(date))
    }

    static func isRecentModel(_ model: ModelRelease, now: Date = .now) -> Bool {
        isTopStoryDate(model.created, now: now)
    }

    static func today(models: [ModelRelease], announcements: [FeedItem], retiring: [ModelRelease], since: Date, now: Date = .now) -> NewsEdition {
        let soon = retiring.filter { expires in
            guard let date = expires.expires else { return false }
            return date > now && date.timeIntervalSince(now) <= retiringHorizon
        }
        let recent = models.filter { isRecentModel($0, now: now) }
        let top = recent.first
        let more = Array(recent.dropFirst(top == nil ? 0 : 1).prefix(moreModelsLimit))
        return NewsEdition(
            digest: NewsEdition.Digest(
                models: recent.filter { $0.newsDate > since }.count,
                updates: announcements.filter { ($0.newsDate ?? .distantPast) > since }.count,
                retiring: soon.count
            ),
            topStory: top,
            moreModels: more,
            tools: tools(announcements, since: since),
            retiring: soon
        )
    }

    static func tools(_ announcements: [FeedItem], since: Date) -> [NewsEdition.Tool] {
        var order: [String] = []
        var grouped: [String: [FeedItem]] = [:]
        for item in announcements {
            let key = item.sourceID ?? item.source
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        return order.map { source in
            let items = grouped[source] ?? []
            let name = items.first?.source ?? source
            let feed = FeedSource.catalog.first { $0.id == source || $0.name == source }
            return NewsEdition.Tool(
                sourceID: items.first?.sourceID,
                source: name,
                provider: feed?.provider,
                kind: feed.map(kind) ?? "News",
                items: Array(items.prefix(itemsPerTool)),
                newCount: items.filter { ($0.newsDate ?? .distantPast) > since }.count
            )
        }
    }

    static func kind(of feed: FeedSource) -> String {
        let address = feed.url.absoluteString.lowercased()
        if address.contains("/releases.atom") { return "Releases" }
        if address.contains("changelog") || address.contains("release-notes") { return "Changelog" }
        return "News"
    }

    static let labProviders: [String: Provider] = [
        "anthropic": .anthropicOrg, "openai": .openai, "x-ai": .xaiOrg, "z-ai": .zai,
        "moonshotai": .moonshot, "minimax": .minimax, "deepseek": .deepseek,
    ]
}

extension ModelRelease {
    var contextText: String? {
        contextText(locale: .current)
    }

    func contextText(locale: Locale) -> String? {
        guard let context = contextLength, context > 0 else { return nil }
        return context.formatted(.number.notation(.compactName).locale(locale))
    }

    func daysUntilRetirement(now: Date = .now) -> Int? {
        guard let expires, expires > now else { return nil }
        return Int((expires.timeIntervalSince(now) / 86_400).rounded(.up))
    }
}
