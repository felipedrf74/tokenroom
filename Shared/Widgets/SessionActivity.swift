import ActivityKit
import AppIntents
import Foundation

/// A Live Activity that follows one window to its reset.
struct SessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var used: Double
        var resetsAt: Date
        var isStale: Bool
        /// Whether this activity has alerted that the window runs out before its reset; once per
        /// activity, which ends at the reset. Nil in activities started before 2.1.
        var warnedRunsOut: Bool? = nil
        /// Optional for activities created by earlier versions. Usage remains the last measurement.
        var awaitingReading: Bool? = nil
    }

    var providerID: String
    var providerName: String
    var shortName: String
    var monogram: String
    var tint: String
    var windowID: String
    var windowTitle: String
    /// The window's length, for the pace tick. Nil in activities started before 2.1.
    var windowSeconds: Double? = nil
}

/// Starting, updating, and ending the usage Live Activities. Starting only works in the app
/// (and intents it runs); updates arrive whenever the app refreshes.
enum LiveActivities {
    /// How long an ended activity stays on the Lock Screen.
    static let lingering: TimeInterval = 15 * 60

    static func candidate(in provider: RelayProvider, preferring window: String? = nil, now: Date = .now) -> RelayWindow? {
        provider.windowToFollow(preferring: window, now: now)
    }

    static var isEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Activities still on screen. Past its stale date (the reset) ActivityKit marks one `stale`,
    /// and it stays on the Lock Screen until it's ended.
    private static var shown: [Activity<SessionActivityAttributes>] {
        Activity<SessionActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    /// The activity following a provider, unless its window has already reset.
    static func activity(for providerID: String, now: Date = .now) -> Activity<SessionActivityAttributes>? {
        shown.first { $0.attributes.providerID == providerID && $0.content.state.resetsAt > now }
    }

    /// One activity per provider; following it again keeps the one there is. One whose window
    /// reset, still on screen or lingering after it ended, makes way for the new one first. On
    /// the main actor, so two Follows at once (a double tap, the button and the Control) start
    /// one.
    @MainActor
    @discardableResult
    static func start(_ provider: RelayProvider, window: RelayWindow, now: Date = .now) async throws -> Bool {
        guard isEnabled, let resetsAt = window.resetsAt, resetsAt > now else { return false }
        if activity(for: provider.id, now: now) != nil { return true }
        await stop(provider.id)
        // Again: another Follow may have started one while those ended.
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
        let state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive)
        _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: resetsAt, relevanceScore: window.used), pushType: nil)
        return true
    }

    /// Follows the most urgent window that qualifies, from the readings saved for widgets.
    static func startMostUrgent(now: Date = .now) async throws -> Bool {
        let items = ReadingCache.defaultURL.flatMap(ReadingCache.load)?.presented(at: now).items ?? []
        for item in items {
            if let window = candidate(in: item.provider, now: now) {
                return try await start(item.provider, window: window)
            }
        }
        return false
    }

    /// Moves each activity to the latest reading, with an alert as it crosses 80% and 95% (when
    /// those alerts are on, and outside quiet hours but for 95%), and ends the ones whose window
    /// has reset, stale ones included.
    /// - Parameter samples: recent readings by provider id, then window id, for the pace of readings
    ///   without a measured one (the iPhone's own).
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
                // Reset (even if no newer reading has come in yet), or a new window: done. A
                // reset time the provider moved, with the window still going, is the same
                // window, even when the move is only seen after the old time.
                if old.resetsAt <= now || window?.resetsAt != nil {
                    await end(activity, resetAt: old.resetsAt, now: now)
                }
                continue
            }
            var state = SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive, warnedRunsOut: old.warnedRunsOut)
            guard state != old else { continue }
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
            // The pace alert, when its switch is on: once, and not in the same update as a level.
            if alert == nil, old.warnedRunsOut != true,
               let runsOut = AlertRules.runsOut(provider, window: window, preferences: preferences, samples: samples[provider.id]?[window.id] ?? [], now: now),
               runsOut.isUrgent || !preferences.isQuiet(at: now) {
                alert = AlertConfiguration(title: "\(runsOut.title)", body: "\(runsOut.body)", sound: .default)
                state.warnedRunsOut = true
            }
            await activity.update(ActivityContent(state: state, staleDate: resetsAt, relevanceScore: window.used), alertConfiguration: alert)
        }
    }

    private static func end(_ activity: Activity<SessionActivityAttributes>, resetAt: Date, now: Date) async {
        var final = activity.content.state
        final.resetsAt = resetAt
        final.isStale = true
        final.awaitingReading = true
        await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(lingering)))
    }

    /// Ends a provider's activities at once, ones lingering after they ended included.
    static func stop(_ providerID: String) async {
        for activity in Activity<SessionActivityAttributes>.activities where activity.attributes.providerID == providerID && activity.activityState != .dismissed {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

extension SessionActivityAttributes.ContentState {
    /// A scheduled reset isn't a new measurement. Keep the recorded amount and mark it pending.
    func shown(isStale activityIsStale: Bool, now: Date = .now) -> Self {
        guard activityIsStale || resetsAt <= now else { return self }
        var result = self
        result.isStale = true
        result.awaitingReading = true
        return result
    }
}

/// For Shortcuts, the Action button, and the Control Center control.
struct FollowUsageIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Follow Usage on Lock Screen"
    static let description = IntentDescription("Shows your most urgent limit that resets within 8 hours on the Lock Screen and in the Dynamic Island, until it resets.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = try await LiveActivities.startMostUrgent()
        return .result(dialog: started ? "Following it until it resets." : "Nothing resets within 8 hours right now.")
    }
}
