import Foundation

/// How often each kind of News source is checked. Pure, so the iPhone's background refresh, the
/// Mac's News loop, and the screens that keep News current all agree, and tests can say so.
///
/// | Kind | Off screen or in background | On screen |
/// |---|---|---|
/// | Official announcements and releases | 15 min | 5 min |
/// | Status (followed only) | 10 min | 5 min |
/// | Voices and discussion | 3 h | 30 min |
/// | Model list | 30 min | 15 min |
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

    /// The age at which a check of `tier` is due. `maxAge` is how fresh the caller asks for: nil
    /// in the background (the tier's own interval), 0 now (pull to refresh, Check Now), and
    /// otherwise (News opening or on screen, the iPhone coming forward) no fresher than the tier's
    /// on-screen interval and never staler than its background one. So a live check every five
    /// minutes doesn't poll a voice that posts weekly, and coming forward still checks a status
    /// feed that's due by its own ten minutes.
    static func interval(for tier: Tier, maxAge: TimeInterval?) -> TimeInterval {
        let intervals = intervals(for: tier)
        guard let maxAge else { return intervals.background }
        guard maxAge > 0 else { return 0 }
        return min(intervals.background, max(maxAge, intervals.onScreen))
    }

    static func interval(for source: FeedSource, maxAge: TimeInterval?) -> TimeInterval {
        interval(for: tier(of: source), maxAge: maxAge)
    }

    /// When the iPhone comes forward, on any tab, it checks what's older than this (60 minutes
    /// before November 2026). iOS decides when background refresh runs, so this is when most
    /// checks happen.
    static let activationMaxAge: TimeInterval = 15 * 60

    /// How long a source's last read counts as current: its kind's background interval and a
    /// download, so a feed checked on schedule never reads as delayed, on screen or off.
    static func currentInterval(for source: FeedSource) -> TimeInterval {
        intervals(for: tier(of: source)).background + NewsFetcher.downloadTimeout
    }

    /// The shortest and longest a background loop (the Mac's) waits between passes: never a busy
    /// loop when something is overdue but can't be read (offline), and never long past a source
    /// coming due.
    static let shortestWait: TimeInterval = 60
    static let longestWait: TimeInterval = 15 * 60

    /// When the next background pass should go out: the soonest the model list or a followed
    /// source comes due by its kind's interval, its failure backoff, or its Retry-After, kept
    /// within `shortestWait` and `longestWait` of `now`.
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

    /// When `NewsFetcher.isDue` turns true for a check with these times.
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
