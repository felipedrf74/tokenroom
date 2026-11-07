import Foundation

/// What a Watch process knows about its iCloud account, for taking the iPhone's handovers.
enum WatchAccountKnowledge: String, Sendable, Equatable {
    /// Not asked yet in this process: a cold background launch to take a handover.
    case unknown
    /// `accountStatus()` answered `.available`, or an iCloud read went through.
    case available
    /// Confirmed signed out of iCloud, with the sign-out cutoff recorded.
    case noAccount
    /// The iCloud read or the account check failed, or didn't answer in time.
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

/// `accountStatus()` as the Watch takes it: there, signed out, couldn't tell, or no iCloud in
/// this build.
enum RelayAccountCheck: Sendable, Equatable {
    case available
    case noAccount
    case failed
    case unavailable
}

/// Whether the Watch applies a handover from its iPhone now, keeps it until it knows its
/// account, or drops it. Never one saved at or before the last sign-out cutoff, whatever else
/// is known: a cache from before a sign-out or an account change can't come back. Otherwise
/// it's applied once this process has read iCloud, or `accountStatus()` said `.available`
/// (within `accountCheckBudget`), or the Watch has no account, or its iCloud read failed: the
/// paired iPhone's readings since the cutoff are this person's, and with iCloud off or out of
/// reach they're all the Watch has. Until one of those is known (a cold launch to take the
/// handover), it's held, and saved (`WatchPendingHandoff`) so it outlives the process.
enum WatchHandoffAcceptance {
    /// How long a cold launch waits for `accountStatus()` before taking the check as failed.
    static let accountCheckBudget: TimeInterval = 5

    enum Decision: Equatable, Sendable {
        case apply
        case hold
        case drop
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

/// A handover the Watch held, saved beside the readings in its App Group so a process that ends
/// before it knows its account doesn't lose it. Readings only, as the handover itself; only the
/// Watch app reads it, and only through `WatchHandoffAcceptance`. Complications never do.
enum WatchPendingHandoff {
    static let fileName = "readings-pending.json"

    static var defaultURL: URL? {
        AppGroup.containerURL?.appendingPathComponent(fileName)
    }

    static func save(_ cache: ReadingCache, at url: URL?) {
        guard let url, !cache.isSample else { return }
        try? cache.save(to: url)
    }

    /// Nil when there's none, or it was saved at or before `signedOutAt`.
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

/// Why the Watch shows what it shows.
enum WatchProblem: Equatable, Sendable {
    case noAccount
    case unreachable

    /// The iPhone's readings were just applied: iCloud being out of reach no longer explains
    /// anything shown. Signed out of iCloud still does.
    func afterPhoneData() -> WatchProblem? {
        self == .unreachable ? nil : self
    }
}

/// A Watch refresh asks iCloud and its iPhone at once. iCloud's answer is applied as soon as it
/// comes, rather than after the iPhone's reply (which can take `WatchStore.phoneBudget`); the
/// iPhone's follows when it comes. `applyCloud` returns false to skip the reply (an account
/// change meanwhile); the iPhone's request is then cancelled, not waited for.
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
