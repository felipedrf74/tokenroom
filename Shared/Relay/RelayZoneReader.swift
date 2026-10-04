import Foundation
import Synchronization

/// An in-memory zone snapshot. Each successful read applies only changes since the last one;
/// failed pages never advance the token or replace a complete snapshot with a partial one.
actor RelayZoneReader<ID: Hashable & Sendable, Record: Sendable, Token: Sendable> {
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
    private var records: [ID: Record] = [:]
    private var token: Token?
    private var generation = UUID()
    private var scope: UUID?
    private var running: Task<[ID: Record], any Error>?

    init(fetch: @escaping @Sendable (Token?) async throws -> Page,
         recovery: @escaping @Sendable (any Error) -> Recovery) {
        self.fetch = fetch
        self.recovery = recovery
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

    /// A timed-out request may ignore cancellation. Let the next caller start a new read, keep
    /// the last complete snapshot, and reject any late result from the abandoned generation.
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
        token = nil
        running?.cancel()
        running = nil
    }

    private func read() async throws -> [ID: Record] {
        let started = generation
        var staged = records
        var cursor = token
        var restarted = false
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
                    staged = [:]
                    cursor = nil
                    restarted = true
                    continue
                case .emptyZone:
                    records = [:]
                    token = nil
                    return [:]
                default:
                    throw error
                }
            }
            try Task.checkCancellation()
            guard generation == started else { throw CancellationError() }
            for (id, result) in page.modifications { staged[id] = try result.get() }
            for id in page.deletions { staged[id] = nil }
            cursor = page.token
            if !page.moreComing {
                records = staged
                token = cursor
                return records
            }
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
