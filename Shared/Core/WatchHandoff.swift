import Foundation

/// What the iPhone and the Watch say to each other over WatchConnectivity. Readings only, plus
/// non-secret requests: whether the iPhone can show its connect screen, and the Watch asking
/// for it or for up-to-date readings. Never a token, a key, or an identity.
enum WatchHandoff {
    /// The `ReadingCache`, encoded.
    static let readingsKey = "readings"
    /// `true` while the iPhone's connect screen is on; absent otherwise.
    static let connectAvailableKey = "connectAvailable"
    static let openKey = "open"
    static let openConnect = "connect"
    static let refreshKey = "refresh"

    /// The whole application context: `updateApplicationContext` replaces it in one go, so the
    /// readings and the flag travel together, or a flag-only update would drop the readings.
    static func context(readings: Data, connectAvailable: Bool) -> [String: Any] {
        var context: [String: Any] = [readingsKey: readings]
        if connectAvailable {
            context[connectAvailableKey] = true
        }
        return context
    }

    /// False when the key is missing, as it is from an iPhone with the connect screen off.
    static func connectAvailable(in context: [String: Any]) -> Bool {
        context[connectAvailableKey] as? Bool ?? false
    }

    /// The Watch's one request: open the connect screen. No provider, nothing else.
    static var openConnectMessage: [String: Any] {
        [openKey: openConnect]
    }

    static func asksToOpenConnect(_ message: [String: Any]) -> Bool {
        message.count == 1 && message[openKey] as? String == openConnect
    }

    static var refreshReadingsMessage: [String: Any] {
        [refreshKey: readingsKey]
    }

    /// A refresh can never choose a provider or carry credentials into the paired iPhone.
    static func asksToRefreshReadings(_ message: [String: Any]) -> Bool {
        message.count == 1 && message[refreshKey] as? String == readingsKey
    }

    struct Payload: Sendable {
        var cache: ReadingCache
        var connectAvailable: Bool
    }

    static func payload(in context: [String: Any]) -> Payload? {
        guard let data = context[readingsKey] as? Data,
              let cache = try? RelayEnvelope.decoder.decode(ReadingCache.self, from: data),
              cache.v <= ReadingCache.version, !cache.isSample else { return nil }
        return Payload(cache: cache, connectAvailable: connectAvailable(in: context))
    }

    /// A reply has seconds, while its iPhone's collector may have a longer provider/cloud
    /// deadline. Stopping the reply's wait must not throw away successful key readings.
    static func collectForReply(budget: TimeInterval, collect: @escaping @Sendable () async -> ReadingCache?) async -> ReadingCache? {
        let collection = Task { await collect() }
        return await TimeLimit.run(budget, otherwise: Optional<ReadingCache>.none) { await collection.value }
    }

    /// A launch retains its last handed-over cache while the shared file is updated by later
    /// checks or widgets. The handover must use their newest real readings.
    static func cacheToSend(retained: ReadingCache?, saved: ReadingCache?, accountGeneration: String? = nil) -> ReadingCache? {
        let eligible = [retained, saved].compactMap { $0 }.filter {
            !$0.isSample && $0.v <= ReadingCache.version && $0.accountGeneration == accountGeneration
        }
        guard let retained = eligible.first else { return nil }
        guard eligible.count > 1 else { return retained }
        return retained.mergingUpdate(eligible[1])
    }
}

// MARK: Payload size

extension WatchHandoff {
    /// The most the encoded readings take in the application context or a reply. Well under
    /// what WatchConnectivity takes, which it doesn't promise.
    static let payloadLimit = 48 * 1024
    /// The hours of history kept, in turn, when the week doesn't fit; 0 sends none.
    static let historySteps = [48, 24, 0]

    struct EncodedReadings: Sendable {
        var data: Data
        /// Nil with the whole week; otherwise the hours of history kept.
        var historyHours: Int?
        /// Still over `payloadLimit` without any history: sent anyway.
        var isOverLimit: Bool
    }

    /// The readings, encoded within `limit` by cutting history (the oldest hours first). Which
    /// providers there are (`items`), the paired phone's own membership (`localSource`), and
    /// the iCloud read's (`relaySnapshot`) are never cut: the Watch reconciles membership with
    /// them.
    static func encodedReadings(_ cache: ReadingCache, limit: Int = payloadLimit) -> EncodedReadings? {
        guard let whole = try? RelayEnvelope.encoder.encode(cache) else { return nil }
        if whole.count <= limit { return EncodedReadings(data: whole, historyHours: nil, isOverLimit: false) }
        var last = whole
        for hours in historySteps {
            guard let data = try? RelayEnvelope.encoder.encode(cache.trimmingHistory(toLast: hours)) else { return nil }
            last = data
            if data.count <= limit { return EncodedReadings(data: data, historyHours: hours, isOverLimit: false) }
        }
        return EncodedReadings(data: last, historyHours: 0, isOverLimit: true)
    }
}

extension ReadingCache {
    /// Every item's history cut to its last `hours`; with 0, none.
    func trimmingHistory(toLast hours: Int) -> ReadingCache {
        var copy = self
        copy.items = items.map { item in
            var item = item
            item.history = item.history.compactMapValues { $0.trimmed(toLast: hours) }
            return item
        }
        return copy
    }
}

// MARK: When the iPhone hands over

/// The iPhone hands its readings to the Watch when what they'd draw changes (`materialHash`), a
/// measured run-out moves an hour, or a shown reading's check has moved forward `checkStep` since
/// it was last handed over. The last, because the hash leaves check times out: a Mac's checks
/// that find the same numbers would otherwise never reach the Watch, which fades a reading an
/// hour after the check it holds.
enum WatchHandoffSchedule {
    static let checkStep: TimeInterval = 30 * 60

    /// Each shown reading's last check, by provider.
    static func checks(in cache: ReadingCache) -> [String: Date] {
        Dictionary(cache.items.compactMap { item in
            (item.provider.checkedAt ?? item.provider.fetchedAt).map { (item.id, $0) }
        }, uniquingKeysWith: { first, second in max(first, second) })
    }

    /// Whether any provider handed over before has been checked `checkStep` or more since. One
    /// handed over for the first time is a change of what's drawn, which goes anyway.
    static func checksMoved(_ checks: [String: Date], since handedOver: [String: Date]) -> Bool {
        checks.contains { id, checked in
            handedOver[id].map { checked.timeIntervalSince($0) >= checkStep } ?? false
        }
    }
}

/// Coalesces Watch refresh requests and keeps the one-minute foreground spacing in one place.
struct WatchRefreshGate {
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private var requestedAgain = false

    mutating func begin(force: Bool, now: Date) -> Bool {
        if !force, let lastRefresh, (0..<60).contains(now.timeIntervalSince(lastRefresh)) { return false }
        guard !isRefreshing else {
            requestedAgain = true
            return false
        }
        isRefreshing = true
        lastRefresh = now
        return true
    }

    mutating func finish() -> Bool {
        isRefreshing = false
        defer { requestedAgain = false }
        return requestedAgain
    }

    mutating func accountChanged() {
        lastRefresh = nil
    }
}
