import Foundation

/// The iPhone's last merged readings, saved in the App Group so its widgets can show them without
/// a network call. Readings only, like the relay records: never keys, tokens, or identities.
struct ReadingCache: Codable, Equatable, Sendable {
    static let version = 1
    static let fileName = "readings.json"

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var provider: RelayProvider
        /// The collector it came from, e.g. "Mac", "This iPhone", or "Sample".
        var source: String
        /// A week of hourly usage per window ID, when the collector sent it.
        var history: [String: UsageHistory] = [:]
        /// Which device the reading came from, as the iPhone that saved this saw it. Nil in a
        /// cache saved before readings kept it: `CollectorKind(legacyLabel:)` stands in.
        var origin: CollectorKind? = nil
        /// Anonymous collector record ID, distinct from any provider or Apple Account identity.
        var sourceID: String? = nil

        var id: String { provider.id }

        /// The origin, or the label's best guess for an older cache.
        var resolvedOrigin: CollectorKind {
            origin ?? CollectorKind(legacyLabel: source)
        }
    }

    var v: Int = ReadingCache.version
    var savedAt: Date
    var isSample: Bool
    /// Most urgent first.
    var items: [Item]
    /// A device-local random cache generation, never an account identifier or relay field.
    /// iPhone widgets use it to reject caches written before an Apple Account change.
    var accountGeneration: String? = nil
    /// Complete cloud membership, captured only after the whole read succeeds.
    var relaySnapshot: RelaySnapshot? = nil
    /// The paired phone's own authoritative membership, including an empty provider list.
    /// Unlike merged rows, this retains a phone reading even when a Mac wins that row.
    var localSource: SourceSnapshot? = nil

    struct SourceSnapshot: Codable, Equatable, Sendable {
        var id: String
        var label: String
        var kind: CollectorKind?
        var envelope: RelayEnvelope
        /// Only the phone-local snapshot carries its device-local cache generation.
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
    }

    /// Nil leaves the established legacy-cache policy in place when exact provenance is absent.
    func reconcilingSourceUpdate(_ incoming: ReadingCache) -> ReadingCache? {
        // A legacy handover cannot claim exact source membership from its displayed rows.
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
                // Exact local provenance belongs to one paired phone and one validated cache
                // generation. A new scope must not inherit the previous scope's cloud sources.
                return incoming.savedAt >= savedAt ? incoming : self
            }
            local = candidate.envelope.checkedAt > retained.envelope.checkedAt ? candidate : retained
            local?.accountGeneration = candidateGeneration
        }

        let relay: RelaySnapshot?
        switch (relaySnapshot, incoming.relaySnapshot) {
        case (nil, let candidate): relay = candidate
        case (let retained, nil): relay = retained
        case (let retained?, let candidate?):
            relay = candidate.checkedAt > retained.checkedAt ? candidate : retained
        }
        guard let relay, var local, local.envelope.isReadable else { return nil }

        var sources = Dictionary(relay.sources.filter { $0.envelope.isReadable }.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, second in
            second.envelope.checkedAt > first.envelope.checkedAt ? second : first
        })
        if let published = sources[local.id], published.envelope.checkedAt > local.envelope.checkedAt {
            // A newer published snapshot can remove a provider too. Keep the paired source's
            // local scope and wording, but use the source's actual published membership.
            local.envelope = published.envelope
        }
        sources[local.id] = local

        // Histories are already stored with displayed items. Carry only ones belonging to the
        // exact winning collector; raw snapshots need no duplicate week of hourly samples.
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

        var result = incoming.savedAt >= savedAt ? incoming : self
        result.savedAt = max(result.savedAt, relay.checkedAt)
        result.relaySnapshot = relay
        result.localSource = local
        result.items = ReadingAssembler.assemble(sources: sources.values.sorted { $0.id < $1.id }.map(\.source),
                                               histories: histories, now: result.savedAt).connected
        return result
    }

    /// The oldest last-success time, so one fresh provider never dates older readings as current.
    var checkedAt: Date? {
        items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min()
    }

    /// Whether this can replace `shown`: none of the providers both hold is older here. The
    /// newest reading overall would do instead, but then a provider gone from this one (a key
    /// removed, iCloud data deleted) would hold it back.
    func isAtLeastAsFresh(as shown: ReadingCache) -> Bool {
        let shownTimes = Dictionary(shown.items.map { ($0.id, $0.provider.checkedAt ?? $0.provider.fetchedAt) }, uniquingKeysWith: { first, _ in first })
        return items.allSatisfy { item in
            guard let shownTime = shownTimes[item.id] ?? nil else { return true }
            guard let time = item.provider.checkedAt ?? item.provider.fetchedAt else { return false }
            return time >= shownTime
        }
    }

    /// Measured run-outs, keyed `provider/window` (`RelayEnvelope.runOuts`).
    var runOuts: [String: Date] {
        RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).runOuts
    }

    /// Changes only when what widgets draw changes, not on every check.
    var materialHash: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        hasher.combine(items.map(\.id))
        hasher.combine(RelayEnvelope(producer: "cache", appVersion: "", checkedAt: .distantPast, providers: items.map(\.provider)).materialHash)
        return hasher.finalize()
    }

    /// What a reload asked for from the background is spent on, out of WidgetKit's daily budget:
    /// a provider added or gone, its state, a level crossed (80%, 95%, used up), a window
    /// starting over. Smaller moves wait for the next timeline, which reads the saved readings.
    var reloadSignature: Int {
        var hasher = Hasher()
        hasher.combine(isSample)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.provider.state)
            for window in item.provider.windows where window.isMetered {
                hasher.combine(window.id)
                hasher.combine(window.used >= 100 ? 3 : window.used >= 95 ? 2 : window.used >= 80 ? 1 : 0)
                // Rounded, not cut off: a reset worked out as now plus seconds lands a second
                // either side of the hour it's on.
                hasher.combine(window.resetsAt.map { Int(($0.timeIntervalSince1970 / 3600).rounded()) })
            }
        }
        return hasher.finalize()
    }

    static var defaultURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    /// Nil when missing, damaged, or written by a newer version.
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

/// When widgets and complications ask for their next timeline: every 30 minutes while a live
/// window is at 80% or more and resets within 12 hours, when fresh readings matter most,
/// otherwise hourly. A month-long budget sitting at 85% doesn't need more. Countdowns tick and
/// meters roll over at resets without a reload, and the apps reload widgets themselves when
/// readings change. A widget that has already reloaded 32 times in the last 24 hours, whatever
/// asked for them, waits the hour: 32 half an hour apart and hourly ones after them fit any day
/// within WidgetKit's budget of about 40 reloads a widget, even one that's busy throughout.
enum WidgetSchedule {
    static let busyInterval: TimeInterval = 30 * 60
    static let calmInterval: TimeInterval = 60 * 60
    static let busyUse = 80.0
    static let busyHorizon: TimeInterval = 12 * 3600
    static let busyAllowance = 32

    /// - Parameter reloads: the widget's timeline builds in the last 24 hours, this one included
    ///   (`WidgetReloadLog.record`).
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
            return [checked.addingTimeInterval(ReadingFreshness.staleAfter + 1), checked.addingTimeInterval(ReadingFreshness.expiresAfter + 1)]
        }.filter { $0 > now }
        return min(scheduled, boundaries.min() ?? scheduled)
    }

    /// When the Watch's Smart Stack offers a live provider's windows: the last 8 hours before the
    /// window a Live Activity would follow resets, and the next half day for its busiest window at
    /// 80% or more. Both, so a session resetting soon doesn't hide a week that's nearly spent.
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
