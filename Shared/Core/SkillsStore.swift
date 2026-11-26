import Foundation
import Observation

@Observable @MainActor final class SkillsStore {
    enum Answer: Sendable { case body(Data), status(Int, retryAfter: String?), unreachable, tooLarge, offline }
    static let budget: TimeInterval = 20
    static let serverErrorBackoff: [TimeInterval] = [5 * 60, 15 * 60]
    static let cacheFileName = "skills.json"
    private(set) var listings: [SkillListing] = []
    private(set) var sort: SkillSort = .trending
    private(set) var checkedAt: Date?
    private(set) var problem: String?
    private(set) var retryAt: Date?
    private(set) var isRefreshing = false
    @ObservationIgnored var allowsRefresh: @MainActor @Sendable () -> Bool = { true }
    @ObservationIgnored private let fetch: @MainActor @Sendable (URLRequest) async -> Answer
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let waitForAnswer: @Sendable (Task<Answer, Never>) async -> Answer
    @ObservationIgnored private let beforeDispatch: @Sendable () async -> Void
    @ObservationIgnored private let monotonicClock: @Sendable () -> TimeInterval
    @ObservationIgnored private let limitAnswer: @Sendable (TimeInterval, Task<Answer, Never>) async -> Answer?
    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isLive: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    }
    private final class Receipt: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false
        var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
        func expire() { lock.lock(); defer { lock.unlock() }; expired = true }
    }
    private struct Request {
        var id: UUID
        var task: Task<Answer, Never>
        var answer: Task<Answer, Never>
        var receipt: Receipt
        var deadline: TimeInterval
        var issued = false
        var waiters: [UUID: Waiter]
    }
    private var running: [SkillSort: Request] = [:]
    private var results: [SkillSort: (items: [SkillListing], date: Date)] = [:]
    private var problems: [SkillSort: String] = [:]
    private var retries: [SkillSort: Date] = [:]
    private var backoffs: [SkillSort: (until: Date, failures: Int)] = [:]
    @ObservationIgnored private let directory: URL?

    struct Saved: Codable, Equatable {
        var items: [SkillListing]
        var checkedAt: Date
    }

    init(directory: URL? = nil,
         fetch: @escaping @MainActor @Sendable (URLRequest) async -> Answer = SkillsStore.get,
         clock: @escaping @Sendable () -> Date = { .now },
         waitForAnswer: @escaping @Sendable (Task<Answer, Never>) async -> Answer = { task in
             await TimeLimit.run(SkillsStore.budget, otherwise: Answer.unreachable) { await task.value }
         },
         beforeDispatch: @escaping @Sendable () async -> Void = {},
         monotonicClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         limitAnswer: @escaping @Sendable (TimeInterval, Task<Answer, Never>) async -> Answer? = { seconds, task in
             await TimeLimit.run(seconds, otherwise: Optional<Answer>.none) { await task.value }
         }) {
        self.fetch = fetch; self.clock = clock; self.waitForAnswer = waitForAnswer
        self.beforeDispatch = beforeDispatch; self.monotonicClock = monotonicClock; self.limitAnswer = limitAnswer
        self.directory = directory
        for (sort, saved) in Self.load(from: directory) { results[sort] = (saved.items, saved.checkedAt) }
        presentSelection()
    }

    static func load(from directory: URL?) -> [SkillSort: Saved] {
        guard let url = directory?.appendingPathComponent(cacheFileName), let data = try? Data(contentsOf: url),
              let saved = try? RelayEnvelope.decoder.decode([String: Saved].self, from: data) else { return [:] }
        return Dictionary(saved.compactMap { key, value in SkillSort(rawValue: key).map { ($0, value) } }) { first, _ in first }
    }

    private func save() {
        guard let url = directory?.appendingPathComponent(Self.cacheFileName) else { return }
        let saved = Dictionary(uniqueKeysWithValues: results.map { ($0.key.rawValue, Saved(items: $0.value.items, checkedAt: $0.value.date)) })
        guard let data = try? RelayEnvelope.encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func refresh(sort selected: SkillSort, force: Bool = false) async {
        guard !Task.isCancelled, allowsRefresh() else { return }
        sort = selected
        presentSelection()
        let now = clock()
        if let retry = retries[selected], retry > now { return }
        if !force, let backoff = backoffs[selected], backoff.until > now { return }
        if running[selected] == nil, !force, let result = results[selected], now.timeIntervalSince(result.date) < 15 * 60 { return }
        let waiter = UUID(), interest = Waiter()
        let task: Task<Answer, Never>
        let requestID: UUID
        if var existing = running[selected] {
            existing.waiters[waiter] = interest
            running[selected] = existing
            task = existing.answer; requestID = existing.id
        }
        else {
            let fetch = fetch, beforeDispatch = beforeDispatch, monotonic = monotonicClock, limit = limitAnswer
            let id = UUID(), receipt = Receipt(), deadline = monotonic() + Self.budget
            let physical = Task { @MainActor [weak self] in
                await beforeDispatch()
                guard !Task.isCancelled, self?.prepareDispatch(sort: selected, requestID: id) == true else {
                    self?.discardUnissued(sort: selected, requestID: id)
                    return Answer.unreachable
                }
                let answer = await fetch(SkillFeed.request(sort: selected))
                self?.completed(answer, sort: selected, requestID: id)
                return answer
            }
            task = Task.detached { [weak self] in
                if let answer = await limit(max(0, deadline - monotonic()), physical) { return answer }
                receipt.expire()
                physical.cancel()
                await self?.expired(sort: selected, requestID: id)
                return Answer.unreachable
            }
            running[selected] = Request(id: id, task: physical, answer: task, receipt: receipt,
                                        deadline: deadline, waiters: [waiter: interest]); requestID = id
        }
        presentSelection()
        let wait = waitForAnswer
        let answer = await withTaskCancellationHandler {
            await wait(task)
        } onCancel: {
            interest.cancel()
            Task { @MainActor [weak self] in self?.releaseWaiter(waiter, sort: selected, requestID: requestID) }
        }
        if !Task.isCancelled, case .unreachable = answer, let request = running[selected], request.id == requestID, request.issued {
            problems[selected] = "Couldn't reach ClawHub. Check your connection and retry."
        }
        releaseWaiter(waiter, sort: selected, requestID: requestID)
        presentSelection()
    }
    private func prepareDispatch(sort selected: SkillSort, requestID: UUID) -> Bool {
        guard var request = running[selected], request.id == requestID,
              !request.receipt.isExpired, monotonicClock() < request.deadline,
              request.waiters.values.contains(where: { $0.isLive }), allowsRefresh() else { return false }
        request.issued = true
        running[selected] = request
        return true
    }
    private func discardUnissued(sort selected: SkillSort, requestID: UUID) {
        guard let request = running[selected], request.id == requestID, !request.issued else { return }
        running[selected] = nil
        presentSelection()
    }
    private func expired(sort selected: SkillSort, requestID: UUID) {
        guard let request = running[selected], request.id == requestID else { return }
        if request.issued, request.waiters.values.contains(where: { $0.isLive }) {
            problems[selected] = "Couldn't reach ClawHub. Check your connection and retry."
        }
        presentSelection()
    }
    private func releaseWaiter(_ waiter: UUID, sort selected: SkillSort, requestID: UUID) {
        guard var request = running[selected], request.id == requestID, request.waiters.removeValue(forKey: waiter) != nil else { return }
        if !request.waiters.values.contains(where: { $0.isLive }) { request.task.cancel() }
        running[selected] = request
        presentSelection()
    }
    private func completed(_ answer: Answer, sort selected: SkillSort, requestID: UUID) {
        guard let request = running[selected], request.id == requestID else { return }
        let hasLiveWaiter = request.waiters.values.contains(where: { $0.isLive })
        if case let .status(code, retry) = answer, code == 429 {
            retries[selected] = Self.retryDate(retry, now: clock())
            problems[selected] = "ClawHub asked us to wait before trying again."
        } else if !request.task.isCancelled, !request.receipt.isExpired, monotonicClock() < request.deadline, hasLiveWaiter {
            let hasRetainedRows = results[selected]?.items.isEmpty == false
            switch answer {
            case .body(let data):
                if let page = try? SkillFeed.parse(data) {
                    results[selected] = (page.listings, clock())
                    problems[selected] = nil; retries[selected] = nil; backoffs[selected] = nil
                    save()
                } else {
                    problems[selected] = hasRetainedRows
                        ? "ClawHub returned an unreadable ranking. Showing the last available result."
                        : "ClawHub returned an unreadable ranking. Try again later."
                }
            case .status(let code, _):
                problems[selected] = "ClawHub is unavailable. Try again later."
                if (500..<600).contains(code) {
                    let failures = (backoffs[selected]?.failures ?? 0) + 1
                    let wait = Self.serverErrorBackoff[min(failures, Self.serverErrorBackoff.count) - 1]
                    backoffs[selected] = (clock().addingTimeInterval(wait), failures)
                }
            case .unreachable: problems[selected] = "Couldn't reach ClawHub. Check your connection and retry."
            case .tooLarge: problems[selected] = "Couldn't read ClawHub's ranking: it was larger than Tokenroom reads (2 MB)."
            case .offline:
                problems[selected] = hasRetainedRows ? nil : "Skills will load when you're online."
            }
        } else if hasLiveWaiter {
            problems[selected] = "Couldn't reach ClawHub. Check your connection and retry."
        }
        running[selected] = nil
        presentSelection()
    }
    private func presentSelection() {
        listings = results[sort]?.items ?? []
        checkedAt = results[sort]?.date
        problem = problems[sort]
        retryAt = retries[sort]
        isRefreshing = running[sort].map { !$0.receipt.isExpired && $0.waiters.values.contains(where: { $0.isLive }) } == true
    }
    private static func retryDate(_ header: String?, now: Date) -> Date {
        guard let date = TokenroomHTTP.retryDate(header, now: now),
              date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 <= 253_402_300_799 else {
            return now.addingTimeInterval(15 * 60)
        }
        return max(now, date)
    }
    static func get(_ request: URLRequest) async -> Answer {
        guard !Task.isCancelled else { return .unreachable }
        return await download(request)
    }

    @concurrent nonisolated static func download(_ request: URLRequest, session: URLSession = NewsFetcher.session) async -> Answer {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            guard (200..<300).contains(http.statusCode) else { return .status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) }
            var data = Data()
            var buffer: [UInt8] = []
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                guard data.count + buffer.count < SkillFeed.sizeLimit else { return .tooLarge }
                buffer.append(byte)
                if buffer.count == buffer.capacity {
                    data.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            data.append(contentsOf: buffer)
            return .body(data)
        } catch let error as URLError where !Task.isCancelled && TokenroomHTTP.meansOffline(error) {
            return .offline
        } catch { return .unreachable }
    }
}
