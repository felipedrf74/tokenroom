import Foundation

enum WatchAccountKnowledge: String, Sendable, Equatable {
    case unknown
    case available
    case noAccount
    case readFailed

    init(_ check: RelayAccountCheck) {
        switch check {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .failed: self = .readFailed
        case .unavailable: self = .unknown
        }
    }
}

enum RelayAccountCheck: Sendable, Equatable {
    case available
    case noAccount
    case failed
    case unavailable
}

enum WatchHandoffAcceptance {
    static let accountCheckBudget: TimeInterval = 5

    enum Decision: Equatable, Sendable {
        case apply
        case hold
        case drop
    }

    static func signOutCutoff(now: Date, recordedCutoff: Date?, held: ReadingCache?) -> Date {
        guard recordedCutoff == nil, let held, !held.isSample, held.savedAt <= now else { return now }
        return held.savedAt.addingTimeInterval(-1)
    }

    static func decide(_ cache: ReadingCache, validated: Bool, account: WatchAccountKnowledge, signedOutAt: Date?) -> Decision {
        guard !cache.isSample, cache.v <= ReadingCache.version else { return .drop }
        if let signedOutAt, cache.savedAt <= signedOutAt { return .drop }
        if validated { return .apply }
        switch account {
        case .available, .noAccount, .readFailed: return .apply
        case .unknown: return .hold
        }
    }
}

enum WatchPendingHandoff {
    static let fileName = "readings-pending.json"

    static var defaultURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    static func save(_ cache: ReadingCache, at url: URL?) {
        guard let url, !cache.isSample else { return }
        try? cache.save(to: url)
    }

    static func load(at url: URL?, signedOutAt: Date?) -> ReadingCache? {
        guard let cache = url.flatMap(ReadingCache.load), !cache.isSample else { return nil }
        guard signedOutAt.map({ cache.savedAt > $0 }) != false else {
            clear(at: url)
            return nil
        }
        return cache
    }

    static func clear(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

enum WatchProblem: Equatable, Sendable {
    case noAccount
    case unreachable

    func afterPhoneData() -> WatchProblem? {
        self == .unreachable ? nil : self
    }
}

enum WatchRefreshOrder {
    @MainActor
    static func run<Cloud: Sendable, Phone: Sendable>(
        cloud: @escaping @Sendable () async -> Cloud,
        phone: @escaping @Sendable () async -> Phone,
        applyCloud: (Cloud) -> Bool,
        applyPhone: (Phone) -> Void
    ) async {
        let reply = Task { await phone() }
        let outcome = await cloud()
        guard applyCloud(outcome) else {
            reply.cancel()
            return
        }
        applyPhone(await reply.value)
    }
}
