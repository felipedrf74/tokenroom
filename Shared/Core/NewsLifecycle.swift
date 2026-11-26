import Foundation

@MainActor enum NewsLifecycle {
    static let backgroundBudget: TimeInterval = 20

    static func backgroundRefresh(news: NewsStore, preferences: AlertPreferences, budget: TimeInterval = backgroundBudget,
                                  usage: @escaping @MainActor @Sendable () async -> Void) async {
        async let usageDone: Void = usage()
        async let newsDone: Void = TimeLimit.run(budget, otherwise: ()) { @MainActor in
            await news.refresh(preferences: preferences, cancellable: true)
        }
        _ = await (usageDone, newsDone)
    }

    static func cameForward(news: NewsStore, preferences: @escaping @MainActor @Sendable () -> AlertPreferences,
                            usage: @escaping @MainActor @Sendable () async -> Void) async {
        async let usageDone: Void = usage()
        async let newsDone: Void = news.refresh(maxAge: NewsCadence.activationMaxAge, preferences: preferences(), waitsForFollowUp: true)
        _ = await (usageDone, newsDone)
    }
}
