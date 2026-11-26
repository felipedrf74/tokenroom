import Foundation

enum WatchHandoff {
    static let readingsKey = "readings"
    static let connectAvailableKey = "connectAvailable"
    static let openKey = "open"
    static let openConnect = "connect"
    static let refreshKey = "refresh"

    static func context(readings: Data, connectAvailable: Bool) -> [String: Any] {
        var context: [String: Any] = [readingsKey: readings]
        if connectAvailable {
            context[connectAvailableKey] = true
        }
        return context
    }

    static func connectAvailable(in context: [String: Any]) -> Bool {
        context[connectAvailableKey] as? Bool ?? false
    }

    static var openConnectMessage: [String: Any] {
        [openKey: openConnect]
    }

    static func asksToOpenConnect(_ message: [String: Any]) -> Bool {
        message.count == 1 && message[openKey] as? String == openConnect
    }

    static var refreshReadingsMessage: [String: Any] {
        [refreshKey: readingsKey]
    }

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

    static func collectForReply(budget: TimeInterval, collect: @escaping @Sendable () async -> ReadingCache?) async -> ReadingCache? {
        let collection = Task { await collect() }
        return await TimeLimit.run(budget, otherwise: Optional<ReadingCache>.none) { await collection.value }
    }

    static func cacheToSend(retained: ReadingCache?, saved: ReadingCache?, accountGeneration: String? = nil) -> ReadingCache? {
        let eligible = [retained, saved].compactMap { $0 }.filter {
            !$0.isSample && $0.v <= ReadingCache.version && $0.accountGeneration == accountGeneration
        }
        guard let retained = eligible.first else { return nil }
        guard eligible.count > 1 else { return retained }
        return retained.mergingUpdate(eligible[1])
    }
}

extension WatchHandoff {
    static let payloadLimit = 48 * 1024
    static let historySteps = [48, 24, 0]

    struct EncodedReadings: Sendable {
        var data: Data
        var historyHours: Int?
        var isOverLimit: Bool
    }

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

enum WatchHandoffSchedule {
    static let checkStep: TimeInterval = 30 * 60

    static func checks(in cache: ReadingCache) -> [String: Date] {
        Dictionary(cache.items.compactMap { item in
            (item.provider.checkedAt ?? item.provider.fetchedAt).map { (item.id, $0) }
        }, uniquingKeysWith: { first, second in max(first, second) })
    }

    static func checksMoved(_ checks: [String: Date], since handedOver: [String: Date]) -> Bool {
        checks.contains { id, checked in
            handedOver[id].map { checked.timeIntervalSince($0) >= checkStep } ?? false
        }
    }
}

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
