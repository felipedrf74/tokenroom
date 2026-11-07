import Foundation

/// A check is scoped to its feed. One delayed feed must not date every other
/// source's successful reading, and an unloaded feed isn't a stale archive.
struct NewsSourceFreshness {
    var currentCount = 0
    var delayedCount = 0
    var unloadedCount = 0
    var failedIDs = Set<String>()
    /// Read, but only up to their size limit (`NewsCache.SourceCheck.truncatedAt`).
    var truncatedIDs = Set<String>()
    var totalCount: Int { currentCount + delayedCount + unloadedCount }

    /// How recently an official feed must have been read to count as current: its background
    /// interval and a download (`NewsCadence.currentInterval`). Each kind is measured against its
    /// own interval, so a voice read two hours ago is current and a status feed isn't.
    static let currentInterval = NewsCadence.intervals(for: .official).background + NewsFetcher.downloadTimeout

    /// `currentInterval`, when given, holds every source to one interval instead of its kind's.
    init(cache: NewsCache, sources: [FeedSource], now: Date = .now,
         currentInterval: TimeInterval? = nil) {
        var seen = Set<String>()
        for source in sources where seen.insert(source.id).inserted {
            let check = cache.check(for: source)
            let failed = cache.unreadable?.contains(source.id) == true || check.failedAt.map {
                check.succeededAt == nil || $0 >= check.succeededAt!
            } == true
            if failed { failedIDs.insert(source.id) }
            if !failed, check.truncatedAt != nil { truncatedIDs.insert(source.id) }
            guard let succeeded = check.succeededAt else { unloadedCount += 1; continue }
            let age = now.timeIntervalSince(succeeded)
            let current = currentInterval ?? NewsCadence.currentInterval(for: source)
            if !failed, age >= 0, age <= current { currentCount += 1 }
            else { delayedCount += 1 }
        }
    }

    var caption: String {
        guard totalCount > 0 else { return "No sources followed" }
        var parts = ["\(currentCount) \(currentCount == 1 ? "source" : "sources") current"]
        if delayedCount > 0 { parts.append("\(delayedCount) delayed") }
        if unloadedCount > 0 { parts.append("\(unloadedCount) not loaded") }
        return parts.joined(separator: " · ")
    }
}
