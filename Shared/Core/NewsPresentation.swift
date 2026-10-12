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


enum NewsDestination: String, CaseIterable, Identifiable, Hashable {
    case today = "Today", following = "Following", skills = "Skills", saved = "Saved"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .today: "newspaper"; case .following: "person.2"; case .skills: "sparkles"; case .saved: "bookmark" }
    }
}
enum NewsCollection: String, CaseIterable, Identifiable, Hashable {
    case model = "Models", release = "Releases", voice = "Voices", status = "Status", retirement = "Retirements"
    var id: String { rawValue }
}
enum NewsDiscovery {
    static func familyIDs(for source: FeedSource) -> Set<String> {
        let product = source.partOf ?? source.id
        return Set((FeedSource.catalog + [source]).filter { ($0.partOf ?? $0.id) == product }.map(\.id))
    }
    static func stories(_ items: [FeedItem], source: FeedSource, query: String = "") -> [FeedItem] {
        let family = familyIDs(for: source)
        return items.filter { item in
            let belongs = family.contains(item.sourceID ?? "") || item.aliasIDs.contains { alias in
                family.contains(String(alias.prefix { $0 != "|" }))
            }
            return belongs && NewsSearch.matches(query, title: item.displayTitle, source: item.source)
        }
    }
    static func latestOfficial(_ items: [FeedItem], now: Date = .now) -> FeedItem? {
        items.filter { ($0.kind ?? .officialAnnouncement) == .officialAnnouncement && now.timeIntervalSince($0.sortDate) <= NewsEditions.topStoryAge }
            .sorted { $0.sortDate > $1.sortDate }.first
    }
    static func stories(_ items: [FeedItem], collection: NewsCollection? = nil, query: String = "") -> [FeedItem] {
        items.filter { item in
            let kind = item.kind ?? .officialAnnouncement
            let matches: Bool
            switch collection {
            case .release: matches = kind == .officialAnnouncement
            case .voice: matches = kind == .commentary
            case .status: matches = kind == .officialStatus
            case .model, .retirement: matches = false
            case nil: matches = true
            }
            return matches && NewsSearch.matches(query, title: item.displayTitle, source: item.source)
        }
    }
}

struct NewsCollectionHealth {
    var checkedAt: Date?
    var uncheckedCount: Int
    var sourceCount: Int
    var problem: String?
    var retryIDs: Set<String>
    var sourceIDs: Set<String>
    var isModelList = false

    var caption: String {
        if isModelList { return checkedAt.map { "Models checked \(RelativeTime.ago($0))" } ?? "Models not checked yet" }
        if sourceCount == 0 { return "No sources followed for this collection" }
        if uncheckedCount > 0 { return "\(sourceCount - uncheckedCount) of \(sourceCount) sources checked" }
        return checkedAt.map { "Sources checked \(RelativeTime.ago($0))" } ?? "Sources not checked yet"
    }
}

extension NewsStore {
    func collectionHealth(for collection: NewsCollection, sourceID: String? = nil) -> NewsCollectionHealth {
        if collection == .model || collection == .retirement {
            let failed = cache.modelsFailedAt != nil || cache.unreadable?.contains(ModelFeed.id) == true
            return .init(checkedAt: cache.modelsFetchedAt, uncheckedCount: cache.modelsFetchedAt == nil ? 1 : 0,
                         sourceCount: 1, problem: failed ? "Couldn't read OpenRouter's model list." : nil,
                         retryIDs: failed ? [ModelFeed.id] : [], sourceIDs: [ModelFeed.id], isModelList: true)
        }
        let kind: NewsSourceKind
        switch collection {
        case .release: kind = .officialAnnouncement
        case .voice: kind = .commentary
        case .status: kind = .officialStatus
        case .model, .retirement: kind = .officialAnnouncement
        }
        let source = sourceID.flatMap { id in (sources + FeedSource.catalog).first { $0.id == id } }
        let family = source.map { NewsDiscovery.familyIDs(for: $0) } ?? Set(sourceID.map { [$0] } ?? [])
        let selected = sources.filter { $0.kind == kind && (sourceID == nil || family.contains($0.id)) }
        let checks = selected.map { cache.check(for: $0) }
        let failed = selected.filter { cache.check(for: $0).failedAt != nil || cache.unreadable?.contains($0.id) == true }
        let problem = failed.isEmpty ? nil : "Couldn't read " + failed.map(\.name).joined(separator: ", ") + "."
        return .init(checkedAt: checks.compactMap(\.succeededAt).min(), uncheckedCount: checks.filter { $0.succeededAt == nil }.count,
                     sourceCount: selected.count, problem: problem, retryIDs: Set(failed.map(\.id)), sourceIDs: Set(selected.map(\.id)))
    }

    func sourceHealth(for source: FeedSource) -> NewsCollectionHealth {
        let collection: NewsCollection
        switch source.kind {
        case .officialAnnouncement: collection = .release
        case .commentary: collection = .voice
        case .officialStatus: collection = .status
        }
        return collectionHealth(for: collection, sourceID: source.id)
    }
}

extension FeedItem {
    var displayExcerpt: String? {
        guard let excerpt else { return nil }
        let clean = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    func bookmark(now: Date = .now) -> NewsBookmark {
        .init(id: stableID, aliases: aliasIDs, kind: .story, title: displayTitle, publisher: source, url: link,
              summary: displayExcerpt, publishedAt: publisherPublishedAt, updatedAt: updatedAt, savedAt: now)
    }
}
extension ModelRelease {
    func bookmark(now: Date = .now) -> NewsBookmark {
        .init(id: "model|" + id, aliases: [], kind: .model, title: shortName, publisher: vendorName, url: link,
              summary: nil, publishedAt: created, updatedAt: nil, savedAt: now)
    }
}
extension SkillListing {
    func bookmark(sort: SkillSort, checkedAt: Date?, now: Date = .now) -> NewsBookmark {
        .init(id: "skill|" + id, aliases: [], kind: .skill, title: name, publisher: owner, url: canonicalURL, summary: summary,
              publishedAt: nil, updatedAt: updatedAt, savedAt: now,
              skill: .init(owner: owner, slug: slug, version: version, requirements: requirements,
                           ranking: "\(sort.label) · \(rankText)", checkedAt: checkedAt))
    }
}
