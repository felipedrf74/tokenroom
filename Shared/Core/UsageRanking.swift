import Foundation

/// Orders providers by how soon they need attention: a reached limit and a quick run-out first,
/// then the most used. Balances without a limit come last.
enum UsageRanking {
    private struct WindowRank {
        var urgency: Int
        var used: Double
    }

    /// Pace for a provider's headline window.
    static func pace(for provider: RelayProvider, history: UsageHistory?, now: Date = .now) -> Pace? {
        guard let window = provider.primaryWindow, window.isMetered else { return nil }
        return pace(for: window, isStale: !provider.isLive, history: history, now: now)
    }

    static func pace(for window: RelayWindow, isStale: Bool, history: UsageHistory?, now: Date = .now) -> Pace? {
        pace(for: window, isStale: isStale, samples: history?.points ?? [], now: now)
    }

    static func pace(for window: RelayWindow, isStale: Bool, samples: [(date: Date, used: Double)], now: Date = .now) -> Pace? {
        guard !window.isAwaitingReading(at: now) else { return nil }
        return Pace.evaluate(
            used: window.used,
            kind: window.windowKind,
            resetsAt: window.resetsAt,
            startsAt: window.startsAt,
            windowSeconds: window.periodSec,
            samples: samples,
            measured: window.pace,
            isStale: isStale,
            now: now
        )
    }

    static func urgency(_ pace: Pace?) -> Int {
        guard let pace else { return 0 }
        return urgency(severity: pace.severity)
    }

    private static func urgency(severity: Pace.Severity) -> Int {
        switch severity {
        case .critical: return 3
        case .tight: return 2
        case .watch: return 1
        case .none: return 0
        }
    }

    static func limitWarning(for provider: RelayProvider, now: Date = .now) -> String? {
        guard provider.isLive, let window = provider.windows.first(where: {
            $0.id != provider.primaryWindow?.id && $0.isMetered && $0.used >= 100 && !$0.isAwaitingReading(at: now)
        }) else { return nil }
        return "\(window.displayTitle) limit reached"
    }

    /// Most urgent first; ties by name.
    static func sorted<Item>(_ items: [Item], provider: (Item) -> RelayProvider, now: Date = .now, pace: (Item) -> Pace?) -> [Item] {
        sorted(items, provider: provider, now: now, windowPace: { item, _ in pace(item) })
    }

    /// Rank by one window's urgency and percentage together, so a calm week cannot inflate
    /// the rank of a less urgent session. The primary headline stays unchanged.
    static func sorted<Item>(_ items: [Item], provider: (Item) -> RelayProvider, now: Date = .now, windowPace: (Item, RelayWindow) -> Pace?) -> [Item] {
        let keyed: [(item: Item, metered: Bool, urgency: Int, used: Double, name: String)] = items.map { item in
            let reading = provider(item)
            let active = reading.windows.filter { $0.isMetered && !$0.isAwaitingReading(at: now) }
            let ranks: [WindowRank] = active.map { window in
                let level: Int
                if reading.isLive && window.used >= 100 { level = urgency(severity: .critical) }
                else { level = urgency(windowPace(item, window)) }
                return WindowRank(urgency: level, used: window.used)
            }
            let window = ranks.max { lhs, rhs in
                lhs.urgency == rhs.urgency ? lhs.used < rhs.used : lhs.urgency < rhs.urgency
            }
            return (item: item, metered: window != nil, urgency: window?.urgency ?? 0, used: window?.used ?? 0, name: reading.name)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.metered != rhs.metered { return lhs.metered }
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            if lhs.used != rhs.used { return lhs.used > rhs.used }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map { $0.item }
    }
}
