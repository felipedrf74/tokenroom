import Foundation

enum ReadingAssembler {
    struct Output: Equatable, Sendable {
        var connected: [ReadingCache.Item]
        var disconnected: [ReadingCache.Item]
    }

    static func assemble(sources: [RelayMerge.Source], histories: [String: RelayHistory], now: Date = .now) -> Output {
        let items = RelayMerge.entries(from: sources, now: now).filter { !$0.provider.isAwaitingFirstReading }.map { entry in
            ReadingCache.Item(
                provider: entry.provider,
                source: entry.sourceLabel,
                history: history(for: entry.provider.id, in: histories[entry.sourceID]),
                origin: entry.origin,
                sourceID: entry.sourceID
            )
        }
        return Output(
            connected: UsageRanking.sorted(items.filter { !$0.provider.isDisconnected }, provider: \.provider, now: now, windowPace: { item, window in
                UsageRanking.pace(for: window, isStale: !item.provider.isLive, history: item.history[window.id], now: now)
            }),
            disconnected: items.filter(\.provider.isDisconnected).sorted { $0.provider.name.localizedStandardCompare($1.provider.name) == .orderedAscending }
        )
    }

    static func pace(for item: ReadingCache.Item, now: Date = .now) -> Pace? {
        item.provider.windows.filter(\.isMetered).compactMap {
            UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: now)
        }.max { UsageRanking.urgency($0) < UsageRanking.urgency($1) }
    }

    static func history(for providerID: String, in relay: RelayHistory?) -> [String: UsageHistory] {
        guard let relay else { return [:] }
        let prefix = providerID + "/"
        var result: [String: UsageHistory] = [:]
        for (key, week) in relay.series where key.hasPrefix(prefix) && !week.isEmpty {
            result[String(key.dropFirst(prefix.count))] = week.migratingLegacyAmounts(for: providerID)
        }
        return result
    }
}

extension ReadingCache.Item {
    var primaryHistory: UsageHistory? {
        provider.primaryWindowID.flatMap { history[$0] }
    }

    func rolledOver(at date: Date) -> ReadingCache.Item {
        self
    }
}
