import Foundation

/// Merges what several collectors (Macs, an iPhone with API keys) published into one reading
/// per provider.
enum RelayMerge {
    struct Source: Sendable {
        var id: String
        var label: String
        var envelope: RelayEnvelope
        /// What kind of device published it, when the reader knows: a record's `kind` after
        /// iCloud answered, or the origin a cached reading kept.
        var kind: CollectorKind? = nil
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var provider: RelayProvider
        var sourceID: String
        var sourceLabel: String
        var origin: CollectorKind? = nil
        var id: String { provider.id }
    }

    /// Collectors silent for longer than this are left out.
    static let maxSourceAge: TimeInterval = 7 * 86_400

    /// A live reading beats one that still has windows to show (stale, rate limited, expired
    /// within its grace), which beats one with none (signed out, not on a plan, failed before a
    /// first reading), which beats one still waiting for its first check; within each, the most
    /// recently checked wins. So a collector that isn't signed in doesn't hide another's older
    /// reading, which shows faded until it ages out. Sorted with the most used first.
    static func entries(from sources: [Source], now: Date = .now) -> [Entry] {
        var best: [String: (entry: Entry, rank: Int, checked: Date)] = [:]
        for source in sources where now.timeIntervalSince(source.envelope.checkedAt) <= maxSourceAge {
            for saved in source.envelope.providers {
                guard let provider = ReadingFreshness.present(saved, fallback: source.envelope.checkedAt, now: now) else { continue }
                let rank = provider.isLive ? 3 : !provider.windows.isEmpty ? 2 : provider.isAwaitingFirstReading ? 0 : 1
                let checked = ReadingFreshness.ordering(provider.checkedAt ?? provider.fetchedAt ?? source.envelope.checkedAt, now: now)
                let candidate = (Entry(provider: provider, sourceID: source.id, sourceLabel: source.label, origin: source.kind), rank, checked)
                guard let current = best[provider.id] else {
                    best[provider.id] = candidate
                    continue
                }
                if rank > current.rank || (rank == current.rank && checked > current.checked) {
                    best[provider.id] = candidate
                }
            }
        }
        return best.values.map(\.entry).sorted { lhs, rhs in
            let left = lhs.provider.primaryWindow?.used ?? -1
            let right = rhs.provider.primaryWindow?.used ?? -1
            return left == right ? lhs.provider.name < rhs.provider.name : left > right
        }
    }
}

extension ReadingCache {
    /// Other devices' readings in this cache, as merge sources with their history. They stand in
    /// while iCloud can't be read, so a reader doesn't drop to only this iPhone's providers; each
    /// is dated by its own checks, so it ages out if iCloud stays away.
    func carriedSources(excluding localLabel: String) -> [(source: RelayMerge.Source, history: RelayHistory)] {
        guard !isSample else { return [] }
        let others = Dictionary(grouping: items.filter { $0.source != localLabel }, by: \.source)
        return others.keys.sorted().map { label in
            let items = others[label] ?? []
            var series: [String: UsageHistory] = [:]
            for item in items {
                for (window, week) in item.history {
                    series[RelayHistory.key(provider: item.id, window: window)] = week
                }
            }
            let checkedAt = items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max() ?? savedAt
            let envelope = RelayEnvelope(producer: "cache", appVersion: TokenroomIdentity.version, checkedAt: checkedAt, providers: items.map(\.provider))
            // The producer is "cache" here, so the kind comes from what the cache kept, or, for a
            // cache from before readings kept it, from the label.
            let kind = items.lazy.compactMap(\.origin).first ?? CollectorKind(legacyLabel: label, localLabel: localLabel)
            return (RelayMerge.Source(id: "previous-" + label, label: label, envelope: envelope, kind: kind), RelayHistory(series: series))
        }
    }
}
