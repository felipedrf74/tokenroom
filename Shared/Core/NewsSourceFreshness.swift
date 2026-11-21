import Foundation

/// A check is scoped to its feed. One delayed feed must not date every other
/// source's successful reading, and an unloaded feed isn't a stale archive.
struct NewsSourceFreshness {
    var currentCount = 0
    var delayedCount = 0
    var unloadedCount = 0
    var failedIDs = Set<String>()
    var uncheckedIDs = Set<String>()
    var answeredCount = 0
    /// Read, but only up to their size limit (`NewsCache.SourceCheck.truncatedAt`).
    var truncatedIDs = Set<String>()
    var totalCount: Int { currentCount + delayedCount + unloadedCount }
    var checkedCount: Int { currentCount + delayedCount }

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
            guard let succeeded = check.succeededAt else {
                unloadedCount += 1
                uncheckedIDs.insert(source.id)
                continue
            }
            if !failed { answeredCount += 1 }
            let age = now.timeIntervalSince(succeeded)
            let current = currentInterval ?? NewsCadence.currentInterval(for: source)
            if !failed, age >= 0, age <= current { currentCount += 1 }
            else { delayedCount += 1 }
        }
    }

    var caption: String {
        guard totalCount > 0 else { return "No sources followed" }
        let noun = totalCount == 1 ? "source" : "sources"
        if checkedCount == 0 { return "\(totalCount) \(noun) not checked yet" }
        if currentCount == totalCount { return totalCount == 1 ? "1 source checked recently" : "All \(totalCount) sources checked recently" }
        return "\(currentCount) of \(totalCount) \(noun) checked recently"
    }

    func briefing(isChecking: Bool, modelsCheckedAt: Date?, modelsFailed: Bool) -> NewsEmptyBriefing {
        guard totalCount > 0 else {
            if modelsFailed { return isChecking ? .waiting : .couldNotCheck }
            return modelsCheckedAt != nil ? .quiet : .waiting
        }
        if answeredCount > 0 { return .quiet }
        return !isChecking && !failedIDs.isEmpty ? .couldNotCheck : .waiting
    }
}

enum NewsEmptyBriefing: Equatable {
    case waiting
    case couldNotCheck
    case quiet

    var title: String {
        switch self {
        case .waiting: "Waiting for the first source check"
        case .couldNotCheck: "Couldn't check your sources"
        case .quiet: "Your briefing is quiet"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "clock"
        case .couldNotCheck: "exclamationmark.triangle"
        case .quiet: "newspaper"
        }
    }

    func message(isChecking: Bool) -> String {
        switch self {
        case .waiting: isChecking ? "Checking your followed sources now." : "Your followed sources haven't been checked yet."
        case .couldNotCheck: "None of your followed sources answered the last check."
        case .quiet: "Follow tools and voices, browse the model archive, or check again."
        }
    }

    var actionTitle: String? {
        switch self {
        case .waiting: "Check Now"
        case .couldNotCheck: "Retry"
        case .quiet: nil
        }
    }
}
