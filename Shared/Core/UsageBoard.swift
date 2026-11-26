import Foundation

struct UsageBoard: Equatable, Sendable {
    struct Plan: Equatable, Sendable {
        var tile: UsageTile
        var ringPace: Pace?
        var barPace: Pace?
        var isClose: Bool
        var warnedWindows: Set<String>
    }

    var close: [CloseWindow]
    var plans: [Plan]
    var hasMixedOrigins: Bool
    var staleCount: Int
    var latestChecked: Date?
    var sourceSummary: String?

    init(
        _ readings: [(provider: RelayProvider, history: [String: UsageHistory], source: String, origin: CollectorKind)],
        showsAllClose: Bool,
        now: Date = .now
    ) {
        var found: [CloseWindow] = []
        var plans: [Plan] = []
        var origins: Set<CollectorKind> = []
        var sources: Set<String> = []
        var stale = 0
        var latest: Date?
        plans.reserveCapacity(readings.count)
        for reading in readings {
            let provider = reading.provider
            let paces = UsageTiles.paces(for: provider, history: reading.history, now: now)
            found += UsageTiles.closeWindows(in: provider, paces: paces, now: now)
            let tile = UsageTiles.tile(for: provider)
            let ringPace = Self.pace(of: tile.ring, in: provider, paces: paces)
            let barPace = Self.pace(of: tile.bar, in: provider, paces: paces)
            let isClose = Self.isClose(tile.ring, pace: ringPace, now: now) || Self.isClose(tile.bar, pace: barPace, now: now)
            plans.append(Plan(tile: tile, ringPace: ringPace, barPace: barPace, isClose: isClose, warnedWindows: []))
            origins.insert(reading.origin)
            sources.insert(reading.source)
            if !provider.isLive { stale += 1 }
            if let checked = provider.checkedAt ?? provider.fetchedAt, latest.map({ checked > $0 }) ?? true { latest = checked }
        }
        let close = UsageTiles.mostUrgentFirst(found)
        var warned: [String: Set<String>] = [:]
        for item in close.prefix(showsAllClose ? close.count : UsageTiles.closeRowLimit) {
            warned[item.provider.id, default: []].insert(item.window.id)
        }
        if !warned.isEmpty {
            for index in plans.indices {
                plans[index].warnedWindows = warned[readings[index].provider.id] ?? []
            }
        }
        self.close = close
        self.plans = plans
        hasMixedOrigins = origins.count > 1
        staleCount = stale
        latestChecked = latest
        sourceSummary = Self.sourceSummary(sources)
    }

    static func sourceSummary(_ sources: some Sequence<String>) -> String? {
        let labels = Array(Set(sources)).sorted()
        switch labels.count {
        case 0: return nil
        case 1: return labels[0]
        default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }

    private static func pace(of window: RelayWindow?, in provider: RelayProvider, paces: [Pace?]) -> Pace? {
        guard let window, let index = provider.windows.firstIndex(of: window) else { return nil }
        return paces[index]
    }

    private static func isClose(_ window: RelayWindow?, pace: Pace?, now: Date) -> Bool {
        guard let window, !window.isAwaitingReading(at: now) else { return false }
        return UsageTiles.isClose(window, pace: pace)
    }
}
