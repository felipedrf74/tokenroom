import Foundation
import Synchronization

actor RelayZoneReader<ID: Hashable & Sendable, Record: Sendable, Token: Sendable> {
    struct Saved: Sendable {
        var records: [ID: Record]
        var quarantined: Set<ID>
        var token: Token?
        var pass: Set<ID>?
    }

    struct Page: Sendable {
        var modifications: [ID: Result<Record, any Error>]
        var deletions: [ID] = []
        var token: Token
        var moreComing = false
    }

    enum Recovery: Sendable {
        case retryFromStart
        case emptyZone
        case fail
    }

    private let fetch: @Sendable (Token?) async throws -> Page
    private let recovery: @Sendable (any Error) -> Recovery
    /// A successful nil result means the record was deleted; a per-ID failure keeps it absent.
    /// An operation-level throw, unlike a per-ID failure, rolls back the staged zone read.
    private let retry: (@Sendable ([ID]) async throws -> [ID: Result<Record?, any Error>])?
    private var records: [ID: Record] = [:]
    private var quarantined: Set<ID> = []
    private var token: Token?
    private var pass: Set<ID>?
    private var generation = UUID()
    private var scope: UUID?
    private var running: Task<[ID: Record], any Error>?
    private var persist: (@Sendable (Saved?) -> Void)?

    init(fetch: @escaping @Sendable (Token?) async throws -> Page,
         recovery: @escaping @Sendable (any Error) -> Recovery,
         retry: (@Sendable ([ID]) async throws -> [ID: Result<Record?, any Error>])? = nil) {
        self.fetch = fetch
        self.recovery = recovery
        self.retry = retry
    }

    func restore(_ saved: Saved?, scope: UUID?, persist: @escaping @Sendable (Saved?) -> Void) {
        guard running == nil else { return }
        if self.scope != scope {
            invalidate()
            self.scope = scope
        }
        self.persist = persist
        guard let saved, records.isEmpty, token == nil else { return }
        records = saved.records
        quarantined = saved.quarantined
        token = saved.token
        pass = saved.pass
    }

    func contents(scope: UUID? = nil) async throws -> [ID: Record] {
        try Task.checkCancellation()
        if self.scope != scope {
            invalidate()
            self.scope = scope
        }
        if let running, running.isCancelled { abandon(running) }
        if let running { return try await wait(for: running) }
        let task = Task { try await read() }
        running = task
        defer { if running == task { running = nil } }
        return try await wait(for: task)
    }

    private func wait(for task: Task<[ID: Record], any Error>) async throws -> [ID: Record] {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { await self.abandon(task) }
        }
    }

    private func abandon(_ task: Task<[ID: Record], any Error>) {
        guard running == task else { return }
        generation = UUID()
        running = nil
        task.cancel()
    }

    /// Account changes invalidate both the token and any outstanding read of the old account.
    func invalidate() {
        generation = UUID()
        scope = nil
        records = [:]
        quarantined = []
        token = nil
        pass = nil
        running?.cancel()
        running = nil
        persist?(nil)
        persist = nil
    }

    private func commit(records: [ID: Record], quarantined: Set<ID>, token: Token?, pass: Set<ID>?) {
        self.records = records
        self.quarantined = quarantined
        self.token = token
        self.pass = pass
        persist?(Saved(records: records, quarantined: quarantined, token: token, pass: pass))
    }

    private func read() async throws -> [ID: Record] {
        let started = generation
        var staged = records
        var stagedQuarantine = quarantined
        // Newly failed IDs wait until a later read; retries are not a same-pass retry loop.
        let retryIDs = quarantined
        var cursor = token
        var seen = pass ?? (cursor == nil && !staged.isEmpty ? [] : nil)
        var restarted = false
        var madeProgress = false
        var newRecordFailure: (any Error)?
        while true {
            try Task.checkCancellation()
            guard generation == started else { throw CancellationError() }
            let page: Page
            do {
                page = try await fetch(cursor)
            } catch {
                guard generation == started else { throw CancellationError() }
                switch recovery(error) {
                case .retryFromStart where !restarted && cursor != nil:
                    seen = []
                    stagedQuarantine = []
                    cursor = nil
                    restarted = true
                    madeProgress = false
                    newRecordFailure = nil
                    continue
                case .emptyZone:
                    commit(records: [:], quarantined: [], token: nil, pass: nil)
                    return [:]
                default:
                    throw error
                }
            }
            try Task.checkCancellation()
            guard generation == started else { throw CancellationError() }
            for (id, result) in page.modifications {
                seen?.insert(id)
                switch result {
                case .success(let record):
                    staged[id] = record
                    stagedQuarantine.remove(id)
                    madeProgress = true
                case .failure(let error):
                    if !quarantined.contains(id), newRecordFailure == nil { newRecordFailure = error }
                    staged[id] = nil
                    stagedQuarantine.insert(id)
                }
            }
            for id in page.deletions {
                staged[id] = nil
                stagedQuarantine.remove(id)
                seen?.remove(id)
                madeProgress = true
            }
            cursor = page.token
            if page.moreComing {
                if madeProgress || newRecordFailure == nil {
                    commit(records: staged, quarantined: stagedQuarantine, token: cursor, pass: seen)
                }
                continue
            }
            let pending = retryIDs.intersection(stagedQuarantine)
            if let retry, !pending.isEmpty {
                let results = try await retry(Array(pending))
                try Task.checkCancellation()
                guard generation == started else { throw CancellationError() }
                for id in pending {
                    guard case .success(let record) = results[id] else { continue }
                    staged[id] = record
                    stagedQuarantine.remove(id)
                    if record != nil { seen?.insert(id) }
                    madeProgress = true
                }
            }
            if !madeProgress, let newRecordFailure { throw newRecordFailure }
            if let seen {
                for id in staged.keys where !seen.contains(id) && !stagedQuarantine.contains(id) {
                    staged[id] = nil
                }
            }
            commit(records: staged, quarantined: stagedQuarantine, token: cursor, pass: nil)
            return staged
        }
    }
}

/// Owns the observer without passing a Foundation observer token across actor boundaries.
final class RelayAccountObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(name: Notification.Name, changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in changed() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

/// A synchronous account fence: observers close it before actor work is enqueued.
final class RelayAccountEpoch: Sendable {
    private let current = Mutex(UUID())
    var value: UUID { current.withLock { $0 } }
    func invalidate() { current.withLock { $0 = UUID() } }
}
