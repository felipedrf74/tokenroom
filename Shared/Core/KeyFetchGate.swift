import Darwin
import Foundation

struct KeyFetchGate: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lockDirectory: URL?
    static let legacyKey = "keyFetchGate"

    init(defaults: UserDefaults = AppGroup.defaults, lockDirectory: URL? = AppGroup.containerURL?.appendingPathComponent("key-fetch-locks", isDirectory: true)) {
        self.defaults = defaults
        self.lockDirectory = lockDirectory
        migrate()
    }

    func isResting(_ provider: Provider, now: Date = .now) -> Bool {
        if let blocked = blockedUntil(provider), blocked > now, blocked.timeIntervalSince(now) <= ProviderStatus.longestRetry {
            return true
        }
        if let attempt = lastAttempt(provider) {
            let elapsed = now.timeIntervalSince(attempt)
            if elapsed >= 0, elapsed < provider.minimumInterval { return true }
        }
        return false
    }

    func lastAttempt(_ provider: Provider) -> Date? {
        defaults.object(forKey: Self.attemptKey(provider)) as? Date
    }

    func blockedUntil(_ provider: Provider) -> Date? {
        defaults.object(forKey: Self.blockedKey(provider)) as? Date
    }

    func recordAttempt(_ provider: Provider, at date: Date?) {
        defaults.set(date, forKey: Self.attemptKey(provider))
        defaults.removeObject(forKey: Self.claimKey(provider))
    }

    func claim(_ provider: Provider, at date: Date = .now) -> FetchClaim? {
        synchronized(provider) {
            guard !isResting(provider, now: date),
                  let lease = FetchLease.acquire(provider, directory: lockDirectory)
            else { return nil }
            let previous = lastAttempt(provider)
            let id = UUID().uuidString
            recordAttempt(provider, at: date)
            defaults.set(id, forKey: Self.claimKey(provider))
            return FetchClaim(id: id, provider: provider, written: date, previous: previous, lease: lease)
        }
    }

    func restoreAttempt(_ claim: FetchClaim) {
        synchronized(claim.provider) {
            guard owns(claim), lastAttempt(claim.provider) == claim.written else { return }
            defaults.set(claim.previous, forKey: Self.attemptKey(claim.provider))
        }
    }

    func complete(_ claim: FetchClaim, result: Result<QuotaSnapshot, ProviderError>, at date: Date = .now) {
        switch result {
        case .success:
            block(claim.provider, until: nil, matching: claim)
        case .failure(.rateLimited(let until)):
            block(claim.provider, until: ProviderStatus.clampedRetry(until, now: date), matching: claim)
        case .failure:
            break
        }
        claim.finish()
    }

    func block(_ provider: Provider, until date: Date?, matching claim: FetchClaim) {
        synchronized(provider) {
            guard provider == claim.provider, owns(claim) else { return }
            block(provider, until: date)
        }
    }

    private func owns(_ claim: FetchClaim) -> Bool {
        defaults.string(forKey: Self.claimKey(claim.provider)) == claim.id
    }

    struct FetchClaim: Sendable {
        fileprivate let id: String
        fileprivate let provider: Provider
        fileprivate let written: Date
        fileprivate let previous: Date?
        fileprivate let lease: FetchLease

        func finish() { lease.finish() }
    }

    fileprivate final class FetchLease: @unchecked Sendable {
        private static let registry = NSLock()
        nonisolated(unsafe) private static var active: Set<String> = []
        private let key: String
        private var descriptor: Int32?
        private var finished = false

        private init(key: String, descriptor: Int32?) {
            self.key = key
            self.descriptor = descriptor
        }

        static func acquire(_ provider: Provider, directory: URL?) -> FetchLease? {
            registry.lock()
            defer { registry.unlock() }
            let key = (directory?.path ?? "process") + "/" + provider.rawValue
            guard !active.contains(key) else { return nil }
            var descriptor: Int32?
            if let directory {
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                catch { return nil }
                let fd = Darwin.open(directory.appendingPathComponent(provider.rawValue + ".fetch").path, O_CREAT | O_RDWR, 0o600)
                guard fd >= 0 else { return nil }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
                descriptor = fd
            }
            active.insert(key)
            return FetchLease(key: key, descriptor: descriptor)
        }

        func finish() {
            Self.registry.lock()
            defer { Self.registry.unlock() }
            guard !finished else { return }
            finished = true
            if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
            descriptor = nil
            Self.active.remove(key)
        }

        deinit { finish() }
    }

    func block(_ provider: Provider, until date: Date?) {
        defaults.set(date, forKey: Self.blockedKey(provider))
    }

    func reset(_ provider: Provider) {
        synchronized(provider) {
            recordAttempt(provider, at: nil)
            block(provider, until: nil)
        }
    }

    private func synchronized<T>(_ provider: Provider, _ body: () -> T) -> T {
        let thread = Self.threadLocks.lock(for: provider)
        thread.lock()
        defer { thread.unlock() }
        guard let fd = openLease(provider) else { return body() }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return body()
    }

    private func openLease(_ provider: Provider) -> Int32? {
        guard let folder = lockDirectory else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = Darwin.open(folder.appendingPathComponent(provider.rawValue).path, O_CREAT | O_RDWR, 0o644)
        return fd >= 0 ? fd : nil
    }

    private static let threadLocks = ThreadLocks()

    private final class ThreadLocks: @unchecked Sendable {
        private let gate = NSLock()
        private var locks: [String: NSLock] = [:]

        func lock(for provider: Provider) -> NSLock {
            gate.lock()
            defer { gate.unlock() }
            if let existing = locks[provider.rawValue] { return existing }
            let created = NSLock()
            locks[provider.rawValue] = created
            return created
        }
    }

    private static func attemptKey(_ provider: Provider) -> String {
        "keyFetchGate.\(provider.rawValue).attemptAt"
    }

    private static func blockedKey(_ provider: Provider) -> String {
        "keyFetchGate.\(provider.rawValue).blockedUntil"
    }

    private static func claimKey(_ provider: Provider) -> String {
        "keyFetchGate.\(provider.rawValue).claimID"
    }

    private func migrate() {
        guard let data = defaults.data(forKey: Self.legacyKey) else { return }
        defaults.removeObject(forKey: Self.legacyKey)
        struct Entry: Codable {
            var attemptAt: Date?
            var blockedUntil: Date?
        }
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (id, entry) in entries {
            guard let provider = Provider(rawValue: id) else { continue }
            if lastAttempt(provider) == nil, let attempt = entry.attemptAt {
                recordAttempt(provider, at: attempt)
            }
            if blockedUntil(provider) == nil, let blocked = entry.blockedUntil {
                block(provider, until: blocked)
            }
        }
    }
}
