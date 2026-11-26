import Foundation

struct ReadingCache: Codable, Equatable, Sendable {
    static let version = 1
    static let fileName = "readings.json"

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var provider: RelayProvider
        var source: String
        var history: [String: UsageHistory] = [:]
        var origin: CollectorKind? = nil
        var sourceID: String? = nil

        var id: String { provider.id }

        func attention(now: Date) -> String? {
            ReadingText.attention(provider, now: now, lead: provider.leadWindow(now: now, history: history))
        }

        var resolvedOrigin: CollectorKind {
            origin ?? CollectorKind(legacyLabel: source)
        }
    }

    var v: Int = ReadingCache.version
    var savedAt: Date
    var isSample: Bool
    var items: [Item]
    var accountGeneration: String? = nil
    var relaySnapshot: RelaySnapshot? = nil
    var localSource: SourceSnapshot? = nil
    var cloudReadAt: Date? = nil

    func needsWidgetRefresh(at now: Date, maxAge: TimeInterval) -> Bool {
        guard let cloudReadAt, (0..<maxAge).contains(now.timeIntervalSince(cloudReadAt)) else { return true }
        return nearsStale(at: now)
    }

    struct SourceSnapshot: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var kind: CollectorKind?
        var envelope: RelayEnvelope
        var accountGeneration: String? = nil

        init(_ source: RelayMerge.Source) {
            id = source.id
            label = source.label
            kind = source.kind
            envelope = source.envelope
        }

        var source: RelayMerge.Source {
            .init(id: id, label: label, envelope: envelope, kind: kind)
        }
    }

    struct RelaySnapshot: Codable, Equatable, Sendable {
        var checkedAt: Date
        var sources: [SourceSnapshot]
        var removed: [String: Date]? = nil

        func removals(after date: Date, now: Date) -> [String: Date] {
            (removed ?? [:]).filter { ReadingFreshness.ordering($0.value, now: now) > ReadingFreshness.ordering(date, now: now) }
        }
    }

    func reconcilingSourceUpdate(_ incoming: ReadingCache, now: Date = .now) -> ReadingCache? {
        let order = { (date: Date) in ReadingFreshness.ordering(date, now: now) }
        let incomingIsNewer = order(incoming.savedAt) >= order(savedAt)
        guard relaySnapshot != nil || localSource != nil,
              incoming.relaySnapshot != nil || incoming.localSource != nil else { return nil }

        var local: SourceSnapshot?
        switch (localSource, incoming.localSource) {
        case (nil, var candidate):
            let generation = candidate?.accountGeneration ?? incoming.accountGeneration
            candidate?.accountGeneration = generation
            local = candidate
        case (var retained, nil):
            let generation = retained?.accountGeneration ?? accountGeneration
            retained?.accountGeneration = generation
            local = retained
        case (let retained?, let candidate?):
            let retainedGeneration = retained.accountGeneration ?? accountGeneration
            let candidateGeneration = candidate.accountGeneration ?? incoming.accountGeneration
            if retained.id != candidate.id || retainedGeneration != candidateGeneration {
                return incomingIsNewer ? incoming : self
            }
            local = order(candidate.envelope.checkedAt) > order(retained.envelope.checkedAt) ? candidate : retained
            local?.accountGeneration = candidateGeneration
        }

        let relay: RelaySnapshot?
        var other: RelaySnapshot?
        switch (relaySnapshot, incoming.relaySnapshot) {
        case (nil, let candidate): relay = candidate
        case (let retained, nil): relay = retained
        case (let retained?, let candidate?):
            let candidateWins = order(candidate.checkedAt) >= order(retained.checkedAt)
            relay = candidateWins ? candidate : retained
            other = candidateWins ? retained : candidate
        }
        guard let relay else { return nil }
        if let local, !local.envelope.isReadable { return nil }

        var sources = Dictionary(relay.sources.filter { $0.envelope.isReadable }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, second in
            order(second.envelope.checkedAt) > order(first.envelope.checkedAt) ? second : first
        })
        for candidate in other?.sources ?? [] where candidate.envelope.isReadable {
            guard let kept = sources[candidate.id], order(candidate.envelope.checkedAt) > order(kept.envelope.checkedAt) else { continue }
            sources[candidate.id] = candidate
        }
        var removed = relay.removals(after: relay.checkedAt, now: now)
        for (id, date) in other?.removals(after: relay.checkedAt, now: now) ?? [:] where removed[id].map({ order(date) > order($0) }) ?? true {
            removed[id] = date
        }
        if let local { removed[local.id] = nil }
        for id in removed.keys { sources[id] = nil }
        if var paired = local {
            if let published = sources[paired.id], order(published.envelope.checkedAt) > order(paired.envelope.checkedAt) {
                paired.envelope = published.envelope
            }
            sources[paired.id] = paired
            local = paired
        }

        var histories: [String: RelayHistory] = [:]
        var historyChecks: [String: Date] = [:]
        for cache in [self, incoming] {
            for item in cache.items {
                guard let sourceID = item.sourceID, sources[sourceID] != nil, !item.history.isEmpty else { continue }
                let key = RelayHistory.key(provider: sourceID, window: item.id)
                let checked = item.provider.checkedAt ?? item.provider.fetchedAt ?? cache.savedAt
                guard historyChecks[key].map({ checked >= $0 }) != false else { continue }
                historyChecks[key] = checked
                for (window, week) in item.history {
                    histories[sourceID, default: RelayHistory(series: [:])].series[RelayHistory.key(provider: item.id, window: window)] = week
                }
            }
        }

        var result = incomingIsNewer ? incoming : self
        result.savedAt = max(result.savedAt, relay.checkedAt)
        result.relaySnapshot = RelaySnapshot(checkedAt: relay.checkedAt, sources: relay.sources.compactMap { source in
            source.id == local?.id ? source : removed[source.id] == nil ? sources[source.id] ?? source : nil
        }, removed: removed.isEmpty ? nil : removed)
        result.localSource = local
        result.items = ReadingAssembler.assemble(sources: sources.values.sorted { $0.id < $1.id }.map(\.source),
                                               histories: histories, now: result.savedAt).connected
        return result
    }

    var checkedAt: Date? {
        items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min()
    }

    func isAtLeastAsFresh(as shown: ReadingCache) -> Bool {
        let shownTimes = Dictionary(shown.items.map { ($0.id, $0.provider.checkedAt ?? $0.provider.fetchedAt) }, uniquingKeysWith: { first, _ in first })
        return items.allSatisfy { item in
            guard let shownTime = shownTimes[item.id] ?? nil else { return true }
            guard let time = item.provider.checkedAt ?? item.provider.fetchedAt else { return false }
            return time >= shownTime
        }
    }

    var runOuts: [String: Date] {
        RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).runOuts
    }

    var materialHash: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        hasher.combine(items.map(\.id))
        hasher.combine(RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).materialHash)
        return hasher.finalize()
    }

    var reloadSignature: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.provider.state)
            for window in item.provider.windows where window.isMetered {
                hasher.combine(window.id)
                hasher.combine(window.used >= 100 ? 3 : window.used >= 95 ? 2 : window.used >= 80 ? 1 : 0)
                hasher.combine(window.resetsAt.map { Int(($0.timeIntervalSince1970 / 3600).rounded()) })
            }
        }
        return hasher.finalize()
    }

    func materialHash(at date: Date) -> Int {
        presented(at: date).materialHash
    }

    func reloadSignature(at date: Date) -> Int {
        presented(at: date).reloadSignature
    }

    func nextReload(after now: Date, reloads: Int) -> Date {
        WidgetSchedule.nextReload(after: now, items: presented(at: now).items, reloads: reloads)
    }

    func changes(since previous: ReadingCache?, at date: Date) -> (shown: Bool, worthReload: Bool) {
        (materialHash(at: date) != previous?.materialHash(at: date),
         reloadSignature(at: date) != previous?.reloadSignature(at: date))
    }

    static var defaultURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    static func load(from url: URL) -> ReadingCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? RelayEnvelope.decoder.decode(ReadingCache.self, from: data),
              cache.v <= version
        else { return nil }
        return cache
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RelayEnvelope.encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum WidgetSchedule {
    static let busyInterval: TimeInterval = 30 * 60
    static let calmInterval: TimeInterval = 60 * 60
    static let busyUse = 80.0
    static let busyHorizon: TimeInterval = 12 * 3600
    static let busyAllowance = 32

    static func nextReload(after now: Date, items: [ReadingCache.Item], reloads: Int = 0) -> Date {
        guard reloads < busyAllowance else { return now.addingTimeInterval(calmInterval) }
        let busy = items.map { $0.rolledOver(at: now) }.contains { item in
            item.provider.isLive && item.provider.windows.contains { window in
                guard window.isMetered, window.used >= busyUse, let resetsAt = window.resetsAt else { return false }
                return resetsAt > now && resetsAt.timeIntervalSince(now) <= busyHorizon
            }
        }
        let scheduled = now.addingTimeInterval(busy ? busyInterval : calmInterval)
        let boundaries = items.flatMap { item -> [Date] in
            guard let checked = item.provider.checkedAt ?? item.provider.fetchedAt else { return [] }
            let expiry = checked.addingTimeInterval(ReadingFreshness.expiresAfter + 1)
            guard item.provider.isLive else { return [expiry] }
            return [checked.addingTimeInterval(ReadingFreshness.staleAfter - ReadingFreshness.staleLead), expiry]
        }.filter { $0 > now }
        return min(scheduled, boundaries.min() ?? scheduled)
    }

    static func relevance(of provider: RelayProvider, now: Date) -> [(window: RelayWindow, span: ClosedRange<Date>)] {
        guard provider.isLive else { return [] }
        var spans: [(window: RelayWindow, span: ClosedRange<Date>)] = []
        let followed = provider.windowToFollow(now: now)
        if let followed, let resetsAt = followed.resetsAt {
            spans.append((followed, max(now, resetsAt.addingTimeInterval(-RelayProvider.followHorizon))...resetsAt))
        }
        let busiest = provider.windows.filter { $0.isMetered && $0.used >= busyUse && !$0.isAwaitingReading(at: now) }.max { $0.used < $1.used }
        if let busiest, busiest.id != followed?.id {
            let end = min(busiest.resetsAt ?? now.addingTimeInterval(busyHorizon), now.addingTimeInterval(busyHorizon))
            if end > now {
                spans.append((busiest, now...end))
            }
        }
        return spans
    }
}
