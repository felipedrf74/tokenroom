import Darwin
import Foundation

/// When each key-read provider was last called, and until when it asked to be left alone. The
/// iPhone app and its widgets run in separate processes; they share this through the App Group,
/// so a widget refresh counts toward Anthropic's 15-minute spacing and honors a 429. Each value
/// is a defaults key of its own, written whole, so one process never overwrites another's
/// values with an older copy. UserDefaults is thread-safe, which Swift can't see.
///
/// Checking and then recording is one step (`claim`). A file lock in the App Group covers the
/// app and a widget; a process lock covers threads in one process when that container is absent.
struct KeyFetchGate: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lockDirectory: URL?
    /// Where 2.0.0 kept every provider's values together, rewritten on each change.
    static let legacyKey = "keyFetchGate"

    init(defaults: UserDefaults = AppGroup.defaults, lockDirectory: URL? = AppGroup.containerURL?.appendingPathComponent("key-fetch-locks", isDirectory: true)) {
        self.defaults = defaults
        self.lockDirectory = lockDirectory
        migrate()
    }

    /// Whether a call now would come too soon after the last one, or before a Retry-After. Times
    /// from before the clock was set back don't count, so they can't hold calls off for as long
    /// as it moved.
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

    /// A call going out now, or nil to take one back (it was cut short and didn't count).
    func recordAttempt(_ provider: Provider, at date: Date?) {
        defaults.set(date, forKey: Self.attemptKey(provider))
        defaults.removeObject(forKey: Self.claimKey(provider))
    }

    /// Owns the actual fetch, including providers with no minimum spacing. The lease stays
    /// with the worker when its caller times out; it ends only once that worker finishes.
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

    /// The prior attempt is captured with the claim, rather than before another process can
    /// write. A reset or a newer claim, even at the same timestamp, fences this restoration.
    func restoreAttempt(_ claim: FetchClaim) {
        synchronized(claim.provider) {
            guard owns(claim), lastAttempt(claim.provider) == claim.written else { return }
            // Keep ownership until the worker stops: a late 429 still applies to this key.
            defaults.set(claim.previous, forKey: Self.attemptKey(claim.provider))
        }
    }

    /// Persist the physical response before releasing the lease. Doing it in the waiting
    /// caller leaves a gap between worker completion and that caller resuming, or loses a
    /// response that arrived after the caller's budget expired.
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

    /// flock descriptors are shared by copies of a claim. Closing is idempotent; the process
    /// registry also excludes a second worker in builds without an App Group.
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

    /// A 429's wait, or nil to clear it after a good answer.
    func block(_ provider: Provider, until date: Date?) {
        defaults.set(date, forKey: Self.blockedKey(provider))
    }

    /// A key saved or removed: the old key's spacing and 429 wait don't apply to the new one.
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

    /// Shared by the app and its widgets. Nil where there is no App Group, which is also
    /// where the two processes do not share this gate's defaults.
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

    /// Moves 2.0.0's shared entry to the keys above, once.
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
