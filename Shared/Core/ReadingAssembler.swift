import Foundation

/// Puts together what the iPhone app and its widgets show: each provider's best reading across
/// collectors (see `RelayMerge`), with that collector's history, most urgent first.
enum ReadingAssembler {
    struct Output: Equatable, Sendable {
        var connected: [ReadingCache.Item]
        /// Signed out or not on a plan, alphabetical.
        var disconnected: [ReadingCache.Item]
    }

    /// - Parameters:
    ///   - sources: every collector's envelope, this iPhone's included.
    ///   - histories: each collector's history, by source ID.
    static func assemble(sources: [RelayMerge.Source], histories: [String: RelayHistory], now: Date = .now) -> Output {
        let items = RelayMerge.entries(from: sources, now: now).map { entry in
            ReadingCache.Item(
                provider: entry.provider,
                source: entry.sourceLabel,
                history: history(for: entry.provider.id, in: histories[entry.sourceID])
            )
        }
        return Output(
            connected: UsageRanking.sorted(items.filter { !$0.provider.isDisconnected }, provider: \.provider, now: now) { pace(for: $0, now: now) },
            disconnected: items.filter(\.provider.isDisconnected).sorted { $0.provider.name.localizedStandardCompare($1.provider.name) == .orderedAscending }
        )
    }

    static func pace(for item: ReadingCache.Item, now: Date = .now) -> Pace? {
        item.provider.windows.filter(\.isMetered).compactMap {
            UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: now)
        }.max { UsageRanking.urgency($0) < UsageRanking.urgency($1) }
    }

    /// One provider's weeks from a collector's history, by window ID.
    static func history(for providerID: String, in relay: RelayHistory?) -> [String: UsageHistory] {
        guard let relay else { return [:] }
        let prefix = providerID + "/"
        var result: [String: UsageHistory] = [:]
        for (key, week) in relay.series where key.hasPrefix(prefix) && !week.isEmpty {
            result[String(key.dropFirst(prefix.count))] = week
        }
        return result
    }
}

extension ReadingCache.Item {
    var primaryHistory: UsageHistory? {
        provider.primaryWindowID.flatMap { history[$0] }
    }

    /// Keep the measured value and reset boundary. Presentation labels an elapsed window as
    /// awaiting a reading, rather than inventing a new live zero.
    func rolledOver(at date: Date) -> ReadingCache.Item {
        self
    }
}
