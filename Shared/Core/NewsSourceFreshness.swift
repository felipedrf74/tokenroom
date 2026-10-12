import Foundation

/// A check is scoped to its feed. One delayed feed must not date every other
/// source's successful reading, and an unloaded feed isn't a stale archive.
struct NewsSourceFreshness {
    var currentCount = 0
    var delayedCount = 0
    var unloadedCount = 0
    var failedIDs = Set<String>()
    var totalCount: Int { currentCount + delayedCount + unloadedCount }

    init(cache: NewsCache, sources: [FeedSource], now: Date = .now,
         currentInterval: TimeInterval = NewsFetcher.openInterval) {
        var seen = Set<String>()
        for source in sources where seen.insert(source.id).inserted {
            let check = cache.check(for: source)
            let failed = cache.unreadable?.contains(source.id) == true || check.failedAt.map {
                check.succeededAt == nil || $0 >= check.succeededAt!
            } == true
            if failed { failedIDs.insert(source.id) }
            guard let succeeded = check.succeededAt else { unloadedCount += 1; continue }
            let age = now.timeIntervalSince(succeeded)
            if !failed, age >= 0, age <= currentInterval { currentCount += 1 }
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
