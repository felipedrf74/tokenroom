import Foundation

/// What a Usage tile shows for one provider: its long window (weekly, a month, a billing cycle)
/// as a ring, and its 5-hour session as a bar. A balance with no limit shows its amount instead.
struct UsageTile: Equatable, Sendable {
    /// The window the ring shows. Nil for a balance with no meter.
    var ring: RelayWindow?
    /// The session window the bar shows, when the provider has one besides the ring's.
    var bar: RelayWindow?
    /// An amount-only window (a balance), shown as its amount.
    var balance: RelayWindow?
}

/// A window close to its limit, for the list at the top of the Usage tab.
struct CloseWindow: Equatable, Sendable {
    var provider: RelayProvider
    var window: RelayWindow
    var pace: Pace?
}

enum UsageTiles {
    /// The first alert level: a window at this much used is close to its limit.
    static let closeUse = Double(AlertPreferences.supportedThresholds.min() ?? 80)

    static func tile(for provider: RelayProvider) -> UsageTile {
        let metered = provider.windows.filter(\.isMetered)
        let session = metered.first { $0.windowKind == .session }
        // The long window: the primary when it isn't the session, else the first weekly, else
        // any other metered window. A provider with only a session shows it as the ring.
        let ring = provider.primaryWindow.flatMap { $0.isMetered && $0.windowKind != .session ? $0 : nil }
            ?? metered.first { $0.windowKind == .weekly }
            ?? metered.first { $0.windowKind != .session }
            ?? session
        let bar = session.flatMap { $0.id == ring?.id ? nil : $0 }
        let balance = ring == nil ? provider.windows.first { !$0.isMetered } : nil
        return UsageTile(ring: ring, bar: bar, balance: balance)
    }

    /// 80% or more used, the limit reached, or running ahead of pace toward a run-out before
    /// the reset.
    static func isClose(_ window: RelayWindow, pace: Pace?) -> Bool {
        guard window.isMetered else { return false }
        if window.used >= closeUse { return true }
        guard let pace else { return false }
        return pace.verdict == .limitReached || (pace.verdict == .ahead && pace.runsOutAt != nil)
    }

    /// Every live window close to its limit, most urgent first: the limit reached, then the
    /// soonest run-out, then the most used.
    static func closeWindows(_ readings: [(provider: RelayProvider, history: [String: UsageHistory])], now: Date = .now) -> [CloseWindow] {
        var found: [CloseWindow] = []
        for reading in readings where reading.provider.isLive {
            for window in reading.provider.windows where window.isMetered {
                let pace = UsageRanking.pace(for: window, isStale: false, history: reading.history[window.id], now: now)
                if isClose(window, pace: pace) {
                    found.append(CloseWindow(provider: reading.provider, window: window, pace: pace))
                }
            }
        }
        return found.sorted { lhs, rhs in
            let lhsOut = lhs.window.used >= 100 || lhs.pace?.verdict == .limitReached
            let rhsOut = rhs.window.used >= 100 || rhs.pace?.verdict == .limitReached
            if lhsOut != rhsOut { return lhsOut }
            switch (lhs.pace?.runsOutAt, rhs.pace?.runsOutAt) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.window.used > rhs.window.used
            }
        }
    }

    /// How long before the reset a window runs out: "35 min before it resets",
    /// "3 hours before it resets", "2 days before it resets".
    static func lead(runsOut: Date, resetsAt: Date) -> String {
        let seconds = max(resetsAt.timeIntervalSince(runsOut), 60)
        let when: String
        if seconds < 3600 {
            when = "\(Int((seconds / 60).rounded())) min"
        } else if seconds < 86_400 {
            let hours = Int((seconds / 3600).rounded())
            when = hours == 1 ? "1 hour" : "\(hours) hours"
        } else {
            let days = Int((seconds / 86_400).rounded())
            when = days == 1 ? "1 day" : "\(days) days"
        }
        return "\(when) before it resets"
    }
}
