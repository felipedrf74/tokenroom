import XCTest
@testable import Tokenroom

final class PopoverHeaderTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        folders = []
        suites = []
        super.tearDown()
    }

    @MainActor
    private func makeStore(clients: [any ProviderClient], enabled: [Provider]) throws -> QuotaStore {
        let suite = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return QuotaStore(settings: AppSettings(defaults: defaults), clients: clients, cache: SnapshotCache(directory: folder))
    }

    private func snapshot(_ provider: Provider, at date: Date) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, usedPercent: 40, resetsAt: nil, fetchedAt: date, primaryTitle: "Weekly",
                      windows: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 40, resetsAt: nil)])
    }

    @MainActor
    private func header(_ store: QuotaStore) -> String {
        PopoverView(store: store, onSettings: {}).checkedHeaderText
    }

    @MainActor
    func testFailedRefreshLeavesHeaderOnPreviousSuccessfulCheck() async throws {
        let now = Date.now
        let measuredAt = now.addingTimeInterval(-2 * 3_600)
        let client = HeaderClient(provider: .cursor, results: [.success(snapshot(.cursor, at: measuredAt)), .failure(.unreachable)])
        let store = try makeStore(clients: [client], enabled: [.cursor])
        defer { store.stop() }
        await store.refresh(force: true)
        store.ageReadings(at: now)
        let expected = "Checked \(RelativeTime.ago(measuredAt, now: now))"
        XCTAssertEqual(header(store), expected)
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 2, "The failed refresh actually called the mocked provider")
        XCTAssertEqual(store.lastChecked(.cursor), measuredAt)
        XCTAssertEqual(header(store), expected, "Attempt time must not advertise a new successful check")
    }

    @MainActor
    func testFullySkippedRefreshLeavesHeaderOnPreviousSuccessfulCheck() async throws {
        let now = Date.now
        let measuredAt = now.addingTimeInterval(-30 * 60)
        let client = HeaderClient(provider: .claude, results: [.success(snapshot(.claude, at: measuredAt))])
        let store = try makeStore(clients: [client], enabled: [.claude])
        defer { store.stop() }
        await store.refresh(force: true)
        store.ageReadings(at: now)
        let expected = "Checked \(RelativeTime.ago(measuredAt, now: now))"
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1, "Claude's cooldown skipped the endpoint")
        XCTAssertEqual(client.betweenCalls, 1, "The mocked local fallback returned no reading")
        XCTAssertEqual(store.lastChecked(.claude), measuredAt)
        XCTAssertEqual(header(store), expected)
    }

    @MainActor
    func testHeaderUsesOldestEnabledSuccessfulCheckIncludingSnapshotFallback() throws {
        let store = try makeStore(clients: [], enabled: [.claude, .cursor])
        defer { store.stop() }
        let now = Date.now
        let oldestCheck = now.addingTimeInterval(-2 * 3_600)
        store.statuses[.claude] = .live(snapshot(.claude, at: now.addingTimeInterval(-5 * 3_600)))
        store.checkedAt[.claude] = now.addingTimeInterval(-60)
        store.statuses[.cursor] = .stale(snapshot(.cursor, at: oldestCheck))
        store.checkedAt[.grok] = now.addingTimeInterval(-10 * 3_600)
        store.lastAttempt = now
        store.ageReadings(at: now)
        XCTAssertEqual(header(store), "Checked \(RelativeTime.ago(oldestCheck, now: now))",
                       "Use lastChecked, including snapshot fallback; a disabled provider is not presented")
        XCTAssertEqual(store.lastChecked(.claude), now.addingTimeInterval(-60), "Cards retain their individual check times")
        XCTAssertEqual(store.lastChecked(.cursor), oldestCheck)
    }

    @MainActor
    func testClockRollbackDoesNotReplaceSuccessfulCheckWithFailedAttempt() async throws {
        let attemptTime = Date.now
        let measuredAt = attemptTime.addingTimeInterval(2 * 3_600)
        let client = HeaderClient(provider: .cursor, results: [.success(snapshot(.cursor, at: measuredAt)), .failure(.unreachable)])
        let store = try makeStore(clients: [client], enabled: [.cursor])
        defer { store.stop() }
        await store.refresh(force: true)
        // The machine's clock moved back after the measurement. Presentation clamps its
        // future check to "just now", instead of aging the newly failed attempt as success.
        store.ageReadings(at: attemptTime.addingTimeInterval(3_600))
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(store.lastChecked(.cursor), measuredAt)
        XCTAssertEqual(header(store), "Checked just now")
    }

    @MainActor
    func testSuccessfulCheckAdvancesHeaderEvenWhenValuesAreUnchanged() async throws {
        let now = Date.now
        let first = snapshot(.cursor, at: now.addingTimeInterval(-2 * 3_600))
        let later = snapshot(.cursor, at: now.addingTimeInterval(-60))
        let client = HeaderClient(provider: .cursor, results: [.success(first), .success(later)])
        let store = try makeStore(clients: [client], enabled: [.cursor])
        defer { store.stop() }
        await store.refresh(force: true)
        await store.refresh(force: true)
        store.ageReadings(at: now)
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(store.lastChanged(.cursor), first.fetchedAt, "Equal values retain the earlier measurement")
        XCTAssertEqual(store.lastChecked(.cursor), later.fetchedAt, "The real successful mocked collection advances checkedAt")
        XCTAssertEqual(header(store), "Checked \(RelativeTime.ago(later.fetchedAt, now: now))")
    }

    @MainActor
    func testRefreshingHeaderStillSaysChecking() throws {
        let store = try makeStore(clients: [], enabled: [.cursor])
        defer { store.stop() }
        store.isRefreshing = true
        XCTAssertEqual(header(store), "Checking…")
    }

    @MainActor
    func testFailedCheckWithoutSuccessfulReadingStillSaysNever() async throws {
        let client = HeaderClient(provider: .cursor, results: [.failure(.unreachable)])
        let store = try makeStore(clients: [client], enabled: [.cursor])
        defer { store.stop() }
        await store.refresh(force: true)
        XCTAssertEqual(client.calls, 1)
        XCTAssertNil(store.lastChecked(.cursor))
        XCTAssertEqual(header(store), "Checked never")
    }
}

private final class HeaderClient: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var results: [Result<QuotaSnapshot, ProviderError>]
    private var fetchCount = 0
    private var fallbackCount = 0

    init(provider: Provider, results: [Result<QuotaSnapshot, ProviderError>]) {
        self.provider = provider
        self.results = results
    }

    var calls: Int { lock.withLock { fetchCount } }
    var betweenCalls: Int { lock.withLock { fallbackCount } }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        lock.withLock {
            fetchCount += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        lock.withLock { fallbackCount += 1 }
        return nil
    }
}
