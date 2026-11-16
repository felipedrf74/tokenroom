import Foundation

/// Readings straight from iCloud, for devices that read no provider themselves: the Watch and
/// its complications. Every collector's record counts, the iPhone's included.
enum RelayReadings {
    #if os(watchOS)
    static var accountDefaults: UserDefaults? { AppGroup.defaults }
    #else
    static var accountDefaults: UserDefaults? { nil }
    #endif

    static func cached(at url: URL?) -> ReadingCache? {
        if let defaults = accountDefaults { return WatchCacheAccess.load(at: url, defaults: defaults) }
        return url.flatMap(ReadingCache.load)
    }
    enum Outcome: Sendable {
        case readings(ReadingCache)
        /// No iCloud account on this device.
        case noAccount
        /// This build has no iCloud container (not signed for it).
        case unavailable
        /// iCloud didn't answer.
        case failed
    }

    /// The account alone, for a Watch launched only to take a handover: no zone read.
    static func accountCheck() async -> RelayAccountCheck {
        guard let container = RelayAvailability.containerIdentifier else { return .unavailable }
        guard let status = try? await CloudRelay.shared(containerIdentifier: container).accountStatus() else { return .failed }
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        default: return .failed
        }
    }

    static let zoneShare: TimeInterval = 7
    static let extensionShare: TimeInterval = 3

    static func read(now: Date = .now, known: ReadingCache? = nil,
                     isExtension: Bool = Bundle.main.bundleURL.pathExtension == "appex") async -> Outcome {
        guard let container = RelayAvailability.containerIdentifier else { return .unavailable }
        let relay = CloudRelay.shared(containerIdentifier: container)
        guard let status = try? await relay.accountStatus() else { return .failed }
        if status == .noAccount { return .noAccount }
        guard status == .available else { return .failed }
        let snapshot = known.flatMap { $0.isSample ? nil : $0.relaySnapshot }
        let names = RelaySourceRefresh.names(in: snapshot)
        async let byName: CloudRelay.SourceRead? = names.isEmpty ? nil : try? await relay.sources(named: names)
        let share = names.isEmpty ? nil : isExtension ? extensionShare : zoneShare
        let complete: CloudRelay.Contents? = if let share {
            await TimeLimit.run(share, otherwise: Optional<CloudRelay.Contents>.none) { try? await relay.contents(known: names) }
        } else {
            try? await relay.contents(known: names)
        }
        if let complete { return .readings(cache(from: complete, now: .now)) }
        guard let snapshot, let read = await byName else { return .failed }
        let contents = RelaySourceRefresh.contents(from: snapshot, histories: known?.historiesBySource ?? [:], read: read, now: .now)
        let readAt = Date.now
        return .readings(cache(from: contents, now: readAt, membershipAt: snapshot.checkedAt,
                               removed: RelaySourceRefresh.removals(of: snapshot, after: read, now: readAt)))
    }

    /// Nil when this build has no iCloud container, there's no account, or iCloud didn't answer.
    static func fetch(now: Date = .now) async -> ReadingCache? {
        if case .readings(let cache) = await read(now: now) {
            return cache
        }
        return nil
    }

    static func cache(from contents: CloudRelay.Contents, now: Date = .now, membershipAt: Date? = nil,
                      removed: [String: Date]? = nil) -> ReadingCache {
        let sources = contents.sources.compactMap { source in
            source.envelope.map { RelayMerge.Source(id: source.id, label: source.label, envelope: $0, kind: CollectorKind(recordKind: source.kind)) }
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: contents.histories, now: now)
        return ReadingCache(savedAt: now, isSample: false, items: output.connected,
                            relaySnapshot: .init(checkedAt: membershipAt ?? now, sources: sources.map(ReadingCache.SourceSnapshot.init),
                                                 removed: removed))
    }

    /// The cache, or a fresh read when it's older than `maxAge`, within `budget` seconds.
    static func cache(at url: URL?, maxAge: TimeInterval, budget: TimeInterval, now: Date = .now) async -> ReadingCache? {
        let known = cached(at: url)
        return await cache(at: url, maxAge: maxAge, budget: budget, now: now,
                           defaults: accountDefaults, readOutcome: { await read(now: now, known: known) })
    }

    /// Production and regression source share the outcome path, including durable sign-out.
    static func cache(
        at url: URL?, maxAge: TimeInterval, budget: TimeInterval, now: Date,
        defaults: UserDefaults?, readOutcome: @escaping @Sendable () async -> Outcome
    ) async -> ReadingCache? {
        let cutoff = defaults?.object(forKey: WatchCacheAccess.cutoffKey) as? Date
        let cached = if let defaults { WatchCacheAccess.load(at: url, defaults: defaults) } else { url.flatMap(ReadingCache.load) }
        if let cached, isRecent(cached, maxAge: maxAge, now: now) { return cached.presented(at: now) }
        let outcome = await TimeLimit.run(budget, otherwise: .failed, readOutcome)
        guard defaults == nil || (defaults?.object(forKey: WatchCacheAccess.cutoffKey) as? Date) == cutoff else { return nil }
        switch outcome {
        case .readings(let fresh):
            guard cutoff.map({ fresh.savedAt > $0 }) != false else { return nil }
            if let defaults { WatchCacheAccess.noteAccountAvailable(in: defaults) }
            let merged = cached?.mergingUpdate(fresh, now: now) ?? fresh
            if let defaults { try? WatchCacheAccess.saveValidated(merged, at: url, defaults: defaults, cutoff: cutoff) }
            else if let url { try? merged.save(to: url) }
            return merged.presented(at: now)
        case .noAccount:
            if let defaults, !WatchCacheAccess.confirmNoAccount(in: defaults, at: now) {
                // Still signed out since the sign-out recorded: the iPhone's handovers the Watch
                // took since then stay (`WatchHandoffAcceptance`).
                return WatchCacheAccess.load(at: url, defaults: defaults)?.presented(at: now)
                    ?? ReadingCache(savedAt: now, isSample: false, items: [])
            }
            let empty = ReadingCache(savedAt: now, isSample: false, items: [])
            if let url { try? empty.save(to: url) }
            return empty
        case .failed, .unavailable:
            let retained = if let defaults { WatchCacheAccess.load(at: url, defaults: defaults) } else { url.flatMap(ReadingCache.load) }
            return retained?.presented(at: now)
        }
    }

    /// Optional-reading compatibility for existing regression source.
    static func cache(
        at url: URL?, maxAge: TimeInterval, budget: TimeInterval, now: Date,
        read: @escaping @Sendable () async -> ReadingCache?
    ) async -> ReadingCache? {
        await cache(at: url, maxAge: maxAge, budget: budget, now: now, defaults: nil,
                    readOutcome: { (await read()).map(Outcome.readings) ?? .failed })
    }

    #if DEBUG
    /// Screenshots: a sample cache saved on the Watch stays until real readings replace it. The
    /// iPhone doesn't hand samples over any more; release builds let an old one age out.
    static let keepsSamples = true
    #else
    static let keepsSamples = false
    #endif

    /// Whether `cached` can be shown without reading iCloud first. Outside debug builds a sample
    /// cache ages like any other, so it doesn't outlive sample mode.
    /// One saved recently that holds a live reading about to go stale isn't recent: it's read
    /// again (`ReadingCache.nearsStale`).
    static func isRecent(_ cached: ReadingCache, maxAge: TimeInterval, now: Date, keepsSamples: Bool = RelayReadings.keepsSamples) -> Bool {
        (keepsSamples && cached.isSample)
            || ((0..<maxAge).contains(now.timeIntervalSince(cached.savedAt)) && !cached.nearsStale(at: now))
    }
}
