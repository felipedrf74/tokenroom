import Foundation

enum NewsCadence {
    enum Tier: Sendable, Equatable, CaseIterable {
        case official, status, voices, models
    }

    struct Intervals: Sendable, Equatable {
        var background: TimeInterval
        var onScreen: TimeInterval
    }

    static func intervals(for tier: Tier) -> Intervals {
        switch tier {
        case .official: Intervals(background: 15 * 60, onScreen: 5 * 60)
        case .status: Intervals(background: 10 * 60, onScreen: 5 * 60)
        case .voices: Intervals(background: 3 * 3600, onScreen: 30 * 60)
        case .models: Intervals(background: 30 * 60, onScreen: 15 * 60)
        }
    }

    static func tier(of source: FeedSource) -> Tier {
        switch source.kind {
        case .officialAnnouncement: .official
        case .officialStatus: .status
        case .commentary: .voices
        }
    }

    static func interval(for tier: Tier, maxAge: TimeInterval?) -> TimeInterval {
        let intervals = intervals(for: tier)
        guard let maxAge else { return intervals.background }
        guard maxAge > 0 else { return 0 }
        return min(intervals.background, max(maxAge, intervals.onScreen))
    }

    static func interval(for source: FeedSource, maxAge: TimeInterval?) -> TimeInterval {
        interval(for: tier(of: source), maxAge: maxAge)
    }

    static let activationMaxAge: TimeInterval = 15 * 60

    static func currentInterval(for source: FeedSource) -> TimeInterval {
        intervals(for: tier(of: source)).background + NewsFetcher.downloadTimeout
    }

    static let shortestWait: TimeInterval = 60
    static let longestWait: TimeInterval = 15 * 60

    static func nextCheck(cache: NewsCache, sources: [FeedSource], now: Date) -> Date {
        var due: [Date] = [dueDate(succeededAt: cache.modelsFetchedAt, failedAt: cache.modelsFailedAt, failures: cache.modelsFailures,
                                   retryAt: cache.modelsRetryAt, interval: intervals(for: .models).background, now: now)]
        for source in sources {
            let check = cache.check(for: source)
            due.append(dueDate(succeededAt: check.succeededAt, failedAt: check.failedAt, failures: check.failures,
                               retryAt: check.retryAt, interval: interval(for: source, maxAge: nil), now: now))
        }
        let soonest = due.min() ?? now.addingTimeInterval(longestWait)
        return min(max(soonest, now.addingTimeInterval(shortestWait)), now.addingTimeInterval(longestWait))
    }

    static func dueDate(succeededAt: Date?, failedAt: Date?, failures: Int?, retryAt: Date?, interval: TimeInterval, now: Date) -> Date {
        if let failedAt, succeededAt.map({ failedAt >= $0 }) ?? true {
            let backoff = failedAt.addingTimeInterval(NewsFetcher.retryInterval(afterFailures: failures))
            if let retryAt, retryAt > now, retryAt.timeIntervalSince(now) <= NewsFetcher.longestRetryAfter { return max(retryAt, backoff) }
            return failedAt > now ? now : backoff
        }
        guard let succeededAt, succeededAt <= now else { return now }
        return succeededAt.addingTimeInterval(interval)
    }
}
