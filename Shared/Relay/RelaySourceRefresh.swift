import Foundation

enum RelaySourceRefresh {
    static func names(in snapshot: ReadingCache.RelaySnapshot?) -> [String] {
        snapshot?.sources.map(\.id) ?? []
    }

    static func contents(from snapshot: ReadingCache.RelaySnapshot, histories: [String: RelayHistory],
                         read: CloudRelay.SourceRead, now: Date) -> CloudRelay.Contents {
        let fetched = Dictionary(read.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = snapshot.sources.compactMap { known -> CloudRelay.Source? in
            if read.missing.contains(known.id) { return nil }
            let retained = CloudRelay.Source(id: known.id, kind: recordKind(known.kind), label: known.label,
                                             modifiedAt: nil, envelope: known.envelope, needsNewerApp: false)
            guard let current = fetched[known.id] else { return retained }
            guard let envelope = current.envelope else {
                return current
            }
            return newer(envelope, than: known.envelope, now: now) ? current : retained
        }
        return CloudRelay.Contents(sources: sources, histories: histories.filter { id, _ in sources.contains { $0.id == id } })
    }

    static func removals(of snapshot: ReadingCache.RelaySnapshot, after read: CloudRelay.SourceRead, now: Date) -> [String: Date]? {
        var removed = snapshot.removals(after: snapshot.checkedAt, now: now)
        for source in snapshot.sources where read.missing.contains(source.id) {
            removed[source.id] = now
        }
        return removed.isEmpty ? nil : removed
    }

    static func newer(_ candidate: RelayEnvelope, than kept: RelayEnvelope, now: Date) -> Bool {
        ReadingFreshness.ordering(candidate.checkedAt, now: now) >= ReadingFreshness.ordering(kept.checkedAt, now: now)
    }

    static func recordKind(_ kind: CollectorKind?) -> String {
        switch kind {
        case .thisPhone, .otherPhone: "iphone"
        case .mac, nil: "mac"
        }
    }
}

extension ReadingCache {
    var historiesBySource: [String: RelayHistory] {
        var series: [String: [String: UsageHistory]] = [:]
        for item in items {
            guard let sourceID = item.sourceID else { continue }
            for (window, week) in item.history {
                series[sourceID, default: [:]][RelayHistory.key(provider: item.id, window: window)] = week
            }
        }
        return series.mapValues { RelayHistory(series: $0) }
    }
}
