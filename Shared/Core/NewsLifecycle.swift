import Foundation

/// When the iPhone checks News besides the News tab: in a background refresh and when the app
/// comes forward. Shared, so the Mac's tests cover what the iPhone app runs.
@MainActor enum NewsLifecycle {
    /// News's share of a background refresh, which iOS gives about 30 seconds. Past it the pass
    /// is cancelled, and the checks it cut short count no failure.
    static let backgroundBudget: TimeInterval = 20

    /// A background refresh: usage and News side by side, so neither waits for the other, with
    /// News held to `budget`. Returns when both are done.
    static func backgroundRefresh(news: NewsStore, preferences: AlertPreferences, budget: TimeInterval = backgroundBudget,
                                  usage: @escaping @MainActor @Sendable () async -> Void) async {
        async let usageDone: Void = usage()
        async let newsDone: Void = TimeLimit.run(budget, otherwise: ()) { @MainActor in
            await news.refresh(preferences: preferences, cancellable: true)
        }
        _ = await (usageDone, newsDone)
    }

    /// The app comes forward, on any tab: usage and News at once, News checking what's older
    /// than `NewsCadence.activationMaxAge` (or due by its kind, if sooner), so the News badge and
    /// tab are current without waiting behind usage. A pass under way is waited for, not dropped.
    static func cameForward(news: NewsStore, preferences: @escaping @MainActor @Sendable () -> AlertPreferences,
                            usage: @escaping @MainActor @Sendable () async -> Void) async {
        async let usageDone: Void = usage()
        async let newsDone: Void = news.refresh(maxAge: NewsCadence.activationMaxAge, preferences: preferences(), waitsForFollowUp: true)
        _ = await (usageDone, newsDone)
    }
}
