import XCTest
@testable import Tokenroom

/// The refresh loop around the checks: what's shown, and when a check or a share goes out.
/// Stubbed providers and a throwaway snapshot folder only: no logins, no network, no iCloud.
final class RefreshReliabilityTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        suites = []
        folders = []
        super.tearDown()
    }

    /// Named by the class and a count rather than at random: macOS keeps an empty preferences
    /// file for every name, so runs reuse a few instead of leaving one behind per test.
    private func makeDefaults(enabled: [Provider]) -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        return defaults
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func snapshot(_ provider: Provider, used: Double = 40, fetchedAt: Date = .now) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            usedPercent: used,
            resetsAt: fetchedAt.addingTimeInterval(86_400),
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: nil)]
        )
    }

    @MainActor
    private func makeStore(_ clients: [any ProviderClient], enabled: [Provider]) throws -> QuotaStore {
        QuotaStore(
            settings: AppSettings(defaults: makeDefaults(enabled: enabled)),
            clients: clients,
            cache: SnapshotCache(directory: try makeFolder())
        )
    }

    /// Waits on the main actor, so the store's own tasks run meanwhile.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: Settings

    /// Turned on in Settings: checked now, not left on "Checking…" until the timer's next check.
    @MainActor
    func testAProviderTurnedOnIsCheckedAtOnce() async throws {
        let cursor = Scripted(provider: .cursor, results: [.success(snapshot(.cursor))])
        let devin = Scripted(provider: .devin, results: [.success(snapshot(.devin, used: 12))])
        let store = try makeStore([cursor, devin], enabled: [.cursor])
        await store.refresh(force: true)
        XCTAssertEqual(devin.calls, 0)
        store.setEnabled(.devin, true)
        XCTAssertTrue(store.settings.isEnabled(.devin))
        await waitUntil { devin.calls == 1 }
        XCTAssertEqual(devin.calls, 1)
        await waitUntil { store.statuses[.devin]?.snapshot != nil }
        guard case .live(let reading) = store.statuses[.devin] else {
            return XCTFail("Expected a reading, got \(String(describing: store.statuses[.devin]))")
        }
        XCTAssertEqual(reading.usedPercent, 12)
        XCTAssertEqual(cursor.calls, 1, "Only the provider turned on")
    }

    /// Turned off in Settings: the iPhone's list loses it with a round sent at once, not at the
    /// timer's next check.
    @MainActor
    func testAProviderTurnedOffLeavesTheiPhonesListAtOnce() async throws {
        let cloud = StandInCloud()
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults(enabled: [.cursor, .devin])),
            clients: [Scripted(provider: .cursor, results: [.success(snapshot(.cursor))]),
                      Scripted(provider: .devin, results: [.success(snapshot(.devin))])],
            cache: SnapshotCache(directory: try makeFolder()),
            relay: RelayPublisher(defaults: makeDefaults(enabled: []), cloud: cloud, iCloudBudget: 5)
        )
        await store.refresh(force: true)
        XCTAssertEqual(cloud.envelopes.map { $0.providers.map(\.id) }, [["cursor", "devin"]])
        store.setEnabled(.devin, false)
        await waitUntil { cloud.envelopes.count == 2 }
        XCTAssertEqual(cloud.envelopes.last?.providers.map(\.id), ["cursor"])
    }

    /// A new "Refresh every" starts the timer's wait over, instead of after the wait under way.
    @MainActor
    func testANewRefreshIntervalStartsTheWaitOver() async throws {
        let store = try makeStore([Scripted(provider: .cursor, results: [.success(snapshot(.cursor))])], enabled: [.cursor])
        XCTAssertEqual(store.settings.refreshMinutes, 10)
        store.start()
        defer { store.stop() }
        await waitUntil { store.nextTimedCheck != nil }
        XCTAssertEqual(try XCTUnwrap(store.nextTimedCheck).timeIntervalSinceNow, 600, accuracy: 30)

        store.setRefreshMinutes(30)
        XCTAssertEqual(store.settings.refreshMinutes, 30)
        await waitUntil { (store.nextTimedCheck?.timeIntervalSinceNow ?? 0) > 1200 }
        XCTAssertEqual(try XCTUnwrap(store.nextTimedCheck).timeIntervalSinceNow, 1800, accuracy: 30)

        store.setRefreshMinutes(5)
        await waitUntil { (store.nextTimedCheck?.timeIntervalSinceNow ?? .infinity) < 400 }
        XCTAssertEqual(try XCTUnwrap(store.nextTimedCheck).timeIntervalSinceNow, 300, accuracy: 30)
    }

    // MARK: Waking

    /// Every call failed to connect (awake before the Wi-Fi): checked once more soon after.
    @MainActor
    func testACheckThatCouldntConnectAtAllIsTriedOnceMore() async throws {
        let cursor = Scripted(provider: .cursor, results: [.failure(.unreachable), .success(snapshot(.cursor))])
        let devin = Scripted(provider: .devin, results: [.failure(.unreachable), .success(snapshot(.devin))])
        let store = try makeStore([cursor, devin], enabled: [.cursor, .devin])
        defer { store.stop() }
        store.offlineRetryDelay = 0.05
        await store.refresh(force: true)
        await waitUntil { cursor.calls == 2 && devin.calls == 2 }
        XCTAssertEqual(cursor.calls, 2)
        XCTAssertEqual(devin.calls, 2)
        await waitUntil { store.statuses[.cursor]?.snapshot != nil && store.statuses[.devin]?.snapshot != nil }
        guard case .live = store.statuses[.cursor], case .live = store.statuses[.devin] else {
            return XCTFail("Expected readings after the retry, got \(store.statuses)")
        }

        // Once: a retry that still can't connect is left to the timer.
        let offline = [Scripted(provider: .cursor, results: [.failure(.unreachable)]),
                       Scripted(provider: .devin, results: [.failure(.unreachable)])]
        let still = try makeStore(offline, enabled: [.cursor, .devin])
        defer { still.stop() }
        still.offlineRetryDelay = 0.05
        await still.refresh(force: true)
        await waitUntil(timeout: 0.6) { false }
        XCTAssertEqual(offline.map(\.calls), [2, 2])

        // One provider alone can't tell an outage from being offline: no retry.
        let alone = Scripted(provider: .cursor, results: [.failure(.unreachable)])
        let single = try makeStore([alone], enabled: [.cursor])
        defer { single.stop() }
        single.offlineRetryDelay = 0.05
        await single.refresh(force: true)
        await waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(alone.calls, 1)
    }

    /// A share asked for while the round going to sleep cancelled is still ending gets a round of
    /// its own, rather than being folded into one that won't go round again.
    @MainActor
    func testAShareAskedForWhileACancelledRoundEndsStillGoesOut() async throws {
        let cloud = StandInCloud(holdsPublishes: 1)
        defer { cloud.release() }
        let store = QuotaStore(
            settings: AppSettings(defaults: makeDefaults(enabled: [.cursor])),
            clients: [Scripted(provider: .cursor, results: [.success(snapshot(.cursor))])],
            cache: SnapshotCache(directory: try makeFolder()),
            relay: RelayPublisher(defaults: makeDefaults(enabled: []), cloud: cloud, iCloudBudget: 5)
        )
        let first = Task { await store.share() }
        await waitUntil { cloud.publishStarts == 1 }
        store.willSleep()
        await store.share()
        XCTAssertEqual(cloud.publishStarts, 2, "The request after sleep sent a round of its own")
        XCTAssertEqual(cloud.envelopes.count, 1)
        await first.value
    }

    // MARK: Menu bar

    /// Rate limited before its first reading: connected, so the popover lists it and the menu
    /// bar keeps its place with a placeholder.
    @MainActor
    func testARateLimitedProviderWithoutAReadingKeepsItsPlaceInTheMenuBar() async throws {
        let client = Scripted(provider: .cursor, results: [.failure(.rateLimited(until: Date().addingTimeInterval(600)))])
        let store = try makeStore([client], enabled: [.cursor])
        await store.refresh(force: true)
        guard case .rateLimited(_, nil) = store.statuses[.cursor] else {
            return XCTFail("Expected rate limited without a reading, got \(String(describing: store.statuses[.cursor]))")
        }
        XCTAssertEqual(store.connectedProviders, [.cursor])
        let meter = try XCTUnwrap(store.menuMeters.first { $0.provider == .cursor })
        XCTAssertTrue(meter.isPlaceholder)
        XCTAssertEqual(meter.displayValue, "–%")
    }

    // MARK: Budgets

    /// A new budget goes on the reading the status shows, and doesn't bring back one the
    /// 24-hour grace of an expired session already dropped.
    @MainActor
    func testABudgetGoesOnTheReadingShownAndNotOnADroppedOne() async throws {
        let old = Date().addingTimeInterval(-2 * 86_400)
        let spend = OrgSpend.snapshot(.openaiOrg, window: OrgSpend.spendWindow(250, now: old), fetchedAt: old)
        let client = Scripted(provider: .openaiOrg, results: [.success(spend), .failure(.expired(Provider.openaiOrg.expiredHint))])
        let store = try makeStore([client], enabled: [.openaiOrg])
        await store.refresh(force: true)
        await store.refresh(force: true)
        guard case .expired(_, nil) = store.statuses[.openaiOrg] else {
            return XCTFail("Expected an expired session without its two-day-old reading, got \(String(describing: store.statuses[.openaiOrg]))")
        }
        store.settings.setBudget(500, for: .openaiOrg)
        store.budgetDidChange(for: .openaiOrg)
        guard case .expired(_, nil) = store.statuses[.openaiOrg] else {
            return XCTFail("The dropped reading came back: \(String(describing: store.statuses[.openaiOrg]))")
        }

        // A reading kept from the last launch takes the budget at once.
        let folder = try makeFolder()
        let now = Date()
        SnapshotCache(directory: folder).save([.openaiOrg: OrgSpend.snapshot(.openaiOrg, window: OrgSpend.spendWindow(250, now: now), fetchedAt: now)])
        let relaunched = QuotaStore(
            settings: AppSettings(defaults: makeDefaults(enabled: [.openaiOrg])),
            clients: [],
            cache: SnapshotCache(directory: folder)
        )
        guard case .stale = relaunched.statuses[.openaiOrg] else {
            return XCTFail("Expected the saved reading, got \(String(describing: relaunched.statuses[.openaiOrg]))")
        }
        relaunched.settings.setBudget(500, for: .openaiOrg)
        relaunched.budgetDidChange(for: .openaiOrg)
        guard case .stale(let rebudgeted) = relaunched.statuses[.openaiOrg] else {
            return XCTFail("Expected the saved reading, got \(String(describing: relaunched.statuses[.openaiOrg]))")
        }
        XCTAssertEqual(rebudgeted.usedPercent, 50, accuracy: 0.001)
    }
}

/// Answers each check with the next scripted result, repeating the last one.
private final class Scripted: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let lock = NSLock()
    private var results: [Result<QuotaSnapshot, ProviderError>]
    private var count = 0

    init(provider: Provider, results: [Result<QuotaSnapshot, ProviderError>]) {
        self.provider = provider
        self.results = results
    }

    var calls: Int {
        lock.withLock { count }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}
