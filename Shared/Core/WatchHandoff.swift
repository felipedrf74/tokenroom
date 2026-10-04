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
