import Foundation

struct UsageTile: Equatable, Sendable {
    var ring: RelayWindow?
    var bar: RelayWindow?
    var balance: RelayWindow?
}

struct CloseWindow: Equatable, Sendable, Identifiable {
    var provider: RelayProvider
    var window: RelayWindow
    var pace: Pace?

    var id: String { provider.id + "/" + window.id }
}

enum UsageTiles {
    static let closeUse = Double(AlertPreferences.supportedThresholds.min() ?? 80)
    static let closeRowLimit = 4

    static func tile(for provider: RelayProvider) -> UsageTile {
        let metered = provider.windows.filter(\.isMetered)
        let session = metered.first { $0.windowKind == .session }
        let ring = provider.primaryWindow.flatMap { $0.isMetered && $0.windowKind != .session ? $0 : nil }
            ?? metered.first { $0.windowKind == .weekly }
            ?? metered.first { $0.windowKind != .session }
            ?? session
        let bar = session.flatMap { $0.id == ring?.id ? nil : $0 }
        let balance = ring == nil ? provider.windows.first { !$0.isMetered } : nil
        return UsageTile(ring: ring, bar: bar, balance: balance)
    }

    static func isClose(_ window: RelayWindow, pace: Pace?) -> Bool {
        guard window.isMetered else { return false }
        if window.used >= closeUse { return true }
        guard let pace else { return false }
        return pace.verdict == .limitReached || pace.runOutNeedsAttention
    }

    static func paces(for provider: RelayProvider, history: [String: UsageHistory], now: Date = .now) -> [Pace?] {
        let isStale = !provider.isLive
        return provider.windows.map { window in
            guard window.isMetered, !window.isAwaitingReading(at: now) else { return nil }
            return UsageRanking.pace(for: window, isStale: isStale, history: history[window.id], now: now)
        }
    }

    static func closeWindows(in provider: RelayProvider, paces: [Pace?], now: Date = .now) -> [CloseWindow] {
        var found: [CloseWindow] = []
        for (window, pace) in zip(provider.windows, paces) where window.isMetered && !window.isAwaitingReading(at: now) {
            if isClose(window, pace: pace) {
                found.append(CloseWindow(provider: provider, window: window, pace: pace))
            }
        }
        return found
    }

    static func closeWindows(_ readings: [(provider: RelayProvider, history: [String: UsageHistory])], now: Date = .now) -> [CloseWindow] {
        mostUrgentFirst(readings.flatMap { reading in
            closeWindows(in: reading.provider, paces: paces(for: reading.provider, history: reading.history, now: now), now: now)
        })
    }

    static func mostUrgentFirst(_ found: [CloseWindow]) -> [CloseWindow] {
        found.sorted { lhs, rhs in
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

    static func ordered<Item>(_ items: [Item], id: (Item) -> String, as order: [String]) -> [Item] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        return items.enumerated()
            .map { (item: $0.element, key: (position[id($0.element)] ?? order.count + $0.offset, $0.offset)) }
            .sorted { $0.key < $1.key }
            .map(\.item)
    }

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
