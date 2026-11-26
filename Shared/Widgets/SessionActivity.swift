import ActivityKit
import AppIntents
import Foundation

struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionActivityState

    var providerID: String
    var providerName: String
    var shortName: String
    var monogram: String
    var tint: String
    var windowID: String
    var windowTitle: String
    var windowSeconds: Double? = nil
}

enum LiveActivities {
    static let lingering: TimeInterval = 15 * 60

    static func candidate(in provider: RelayProvider, preferring window: String? = nil, now: Date = .now) -> RelayWindow? {
        provider.windowToFollow(preferring: window, now: now)
    }

    static var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private static var shown: [Activity<SessionActivityAttributes>] {
        Activity<SessionActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    static func activity(for providerID: String, now: Date = .now) -> Activity<SessionActivityAttributes>? {
        shown.first { $0.attributes.providerID == providerID && $0.content.state.resetsAt > now }
    }

    @MainActor
    @discardableResult
    static func start(_ provider: RelayProvider, window: RelayWindow, now: Date = .now) async throws -> Bool {
        guard isEnabled, let resetsAt = window.resetsAt, resetsAt > now else { return false }
        if activity(for: provider.id, now: now) != nil { return true }
        await stop(provider.id)
        if activity(for: provider.id, now: now) != nil { return true }
        let attributes = SessionActivityAttributes(
            providerID: provider.id,
            providerName: provider.name,
            shortName: provider.shortName,
            monogram: provider.monogram,
            tint: provider.tint,
            windowID: window.id,
            windowTitle: window.displayTitle,
            windowSeconds: window.periodSec ?? AlertRules.typicalLength(kind: window.kind)
        )
        let checkedAt = provider.checkedAt ?? provider.fetchedAt
        let state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive, checkedAt: checkedAt)
        let staleDate = LiveActivityFreshness.staleDate(resetsAt: resetsAt, checkedAt: checkedAt)
        _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate, relevanceScore: window.used), pushType: nil)
        return true
    }

    static func startMostUrgent(now: Date = .now) async throws -> Bool {
        guard let next = savedReadings?.mostUrgentToFollow(at: now) else { return false }
        return try await start(next.provider, window: next.window)
    }

    static var savedReadings: ReadingCache? {
        PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults)
    }

    static let sampleDataMessage = "Couldn't follow sample data. Turn off Sample Data in Settings to follow your own usage."

    static func update(with providers: [RelayProvider], preferences: AlertPreferences, samples: [String: [String: [(date: Date, used: Double)]]] = [:], now: Date = .now) async {
        for activity in shown {
            let old = activity.content.state
            let provider = providers.first { $0.id == activity.attributes.providerID }
            let window = provider?.windows.first { $0.id == activity.attributes.windowID }
            guard let provider, let window, let resetsAt = window.resetsAt, resetsAt > now,
                  AlertRules.isSameInstance(old.resetsAt, resetsAt)
                    || AlertRules.isSmallMove(from: old.resetsAt, to: resetsAt, usedBefore: old.used, usedNow: window.used,
                                              length: window.periodSec ?? AlertRules.typicalLength(kind: window.kind))
            else {
                if old.resetsAt <= now || window?.resetsAt != nil {
                    await end(activity, resetAt: old.resetsAt, now: now)
                }
                continue
            }
            let checkedAt = provider.checkedAt ?? provider.fetchedAt
            var state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive,
                                                               warnedRunsOut: old.warnedRunsOut, checkedAt: checkedAt)
            guard LiveActivityFreshness.needsUpdate(from: old, to: state) else { continue }
            let crossed = (provider.isLive && old.awaitingReading != true ? [95, 80] : []).first { level in
                preferences.thresholds(for: window).contains(level) && old.used < Double(level) && window.used >= Double(level)
                    && (level >= 95 || !preferences.isQuiet(at: now))
            }
            var alert = crossed.map { level in
                AlertConfiguration(
                    title: "\(provider.name): \(level)% used",
                    body: "\(window.displayTitle) \(RelativeTime.resets(resetsAt, now: now) ?? "resets soon").",
                    sound: .default
                )
            }
            if alert == nil, old.warnedRunsOut != true,
               let runsOut = AlertRules.runsOut(provider, window: window, preferences: preferences, samples: samples[provider.id]?[window.id] ?? [], now: now),
               runsOut.isUrgent || !preferences.isQuiet(at: now) {
                alert = AlertConfiguration(title: "\(runsOut.title)", body: "\(runsOut.body)", sound: .default)
                state.warnedRunsOut = true
            }
            let staleDate = LiveActivityFreshness.staleDate(resetsAt: resetsAt, checkedAt: checkedAt)
            await activity.update(ActivityContent(state: state, staleDate: staleDate, relevanceScore: window.used), alertConfiguration: alert)
        }
    }

    private static func end(_ activity: Activity<SessionActivityAttributes>, resetAt: Date, now: Date) async {
        var final = activity.content.state
        final.resetsAt = resetAt
        final.isStale = true
        final.awaitingReading = true
        await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(lingering)))
    }

    static func stop(_ providerID: String) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.attributes.providerID == providerID && activity.activityState != .dismissed {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

struct FollowUsageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Follow Usage on Lock Screen"
    static let description = IntentDescription("Shows your most urgent limit that resets within 8 hours on the Lock Screen and in the Dynamic Island, until it resets.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard LiveActivities.isEnabled else {
            return .result(dialog: "Live Activities are off for Tokenroom. Turn them on in Settings › Tokenroom.")
        }
        if LiveActivities.savedReadings?.isSample == true {
            return .result(dialog: "\(LiveActivities.sampleDataMessage)")
        }
        let started = try await LiveActivities.startMostUrgent()
        return .result(dialog: started ? "Following it until it resets." : "Nothing to follow: no 5-hour limit, or limit at 80% or more, resets within 8 hours.")
    }
}
