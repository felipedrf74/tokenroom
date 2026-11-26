import Foundation

enum RelayMerge {
    struct Source: Sendable {
        var id: String
        var label: String
        var envelope: RelayEnvelope
        var kind: CollectorKind? = nil
    }

    struct Entry: Identifiable, Equatable, Sendable {
        var provider: RelayProvider
        var sourceID: String
        var sourceLabel: String
        var origin: CollectorKind? = nil
        var id: String { provider.id }
    }

    static let maxSourceAge: TimeInterval = 7 * 86_400

    static func entries(from sources: [Source], now: Date = .now) -> [Entry] {
        var best: [String: (entry: Entry, rank: Int, checked: Date)] = [:]
        var signIn: [String: (message: String, checked: Date)] = [:]
        for source in sources where now.timeIntervalSince(source.envelope.checkedAt) <= maxSourceAge {
            for saved in source.envelope.providers {
                guard let provider = ReadingFreshness.present(saved, fallback: source.envelope.checkedAt, now: now) else { continue }
                let rank = provider.isLive ? 3 : !provider.windows.isEmpty ? 2 : provider.isAwaitingFirstReading ? 0 : 1
                let checked = ReadingFreshness.ordering(provider.checkedAt ?? provider.fetchedAt ?? source.envelope.checkedAt, now: now)
                let candidate = (Entry(provider: provider, sourceID: source.id, sourceLabel: source.label, origin: source.kind), rank, checked)
                if rank == 1, ["signedOut", "expired", "notEntitled"].contains(provider.state), let message = provider.message,
                   signIn[provider.id].map({ checked > $0.checked }) ?? true {
                    signIn[provider.id] = (message, checked)
                }
                guard let current = best[provider.id] else {
                    best[provider.id] = candidate
                    continue
                }
                if rank > current.rank || (rank == current.rank && checked > current.checked) {
                    best[provider.id] = candidate
                }
            }
        }
        return best.values.map { kept -> Entry in
            var entry = kept.entry
            if kept.rank == 2, let status = signIn[entry.id], status.checked > kept.checked {
                entry.provider.message = status.message
            }
            return entry
        }.sorted { lhs, rhs in
            let left = lhs.provider.primaryWindow?.used ?? -1
            let right = rhs.provider.primaryWindow?.used ?? -1
            return left == right ? lhs.provider.name < rhs.provider.name : left > right
        }
    }
}

extension ReadingCache {
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
            let kind = items.lazy.compactMap(\.origin).first ?? CollectorKind(legacyLabel: label, localLabel: localLabel)
            return (RelayMerge.Source(id: "previous-" + label, label: label, envelope: envelope, kind: kind), RelayHistory(series: series))
        }
    }
}
