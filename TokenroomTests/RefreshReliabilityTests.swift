import XCTest
@testable import Tokenroom

/// The refresh loop around the checks: what's shown, and when a check or a share goes out.
/// Stubbed providers and a throwaway snapshot folder only: no logins, no network, no iCloud.
final class RefreshReliabilityTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        suites.forEach(TestDefaults.remove)
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        suites = []
        folders = []
        super.tearDown()
    }

    private func makeDefaults(enabled: [Provider]) -> UserDefaults {
        let (name, defaults) = TestDefaults.make(owner: "\(Self.self)", index: suites.count)
        suites.append(name)
        defaults.set(enabled.map(\.rawValue), forKey: "enabledProviders")
        return defaults
    }

    /// Calls through `TokenroomHTTP` answer with `status`, or fail with `failure` before any
    /// answer, as the network would.
    private func network(status: Int = 200, failure: URLError.Code? = nil) {
        StubURLProtocol.handler = { _ in (status, Data("{}".utf8)) }
        StubURLProtocol.failure = failure.map { URLError($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
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

    /// Turning a provider off and on again isn't a new login: its spacing and Retry-After hold.
    @MainActor
    func testTurningAProviderBackOnKeepsItsSpacingAndRetryAfter() async throws {
        let claude = Scripted(provider: .claude, results: [.success(snapshot(.claude))])
        let cursor = Scripted(provider: .cursor, results: [.failure(.rateLimited(until: Date().addingTimeInterval(600)))])
        let store = try makeStore([claude, cursor], enabled: [.claude, .cursor])
        await store.refresh(force: true)
        XCTAssertEqual([claude.calls, cursor.calls], [1, 1])
        for provider in [Provider.claude, .cursor] {
            await store.setEnabled(provider, false)?.value
            await store.setEnabled(provider, true)?.value
        }
        XCTAssertEqual(claude.calls, 1, "Checked a moment ago: its five minutes hold")
        XCTAssertEqual(cursor.calls, 1, "No call before its Retry-After")
        guard case .rateLimited = store.statuses[.cursor] else {
            return XCTFail("Expected the rate limit kept, got \(String(describing: store.statuses[.cursor]))")
        }
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

    /// No call reached the network (awake before the Wi-Fi): checked once more soon after.
    @MainActor
    func testACheckThatCouldntReachTheNetworkIsTriedOnceMore() async throws {
        network(failure: .notConnectedToInternet)
        let cursor = ReachingClient(provider: .cursor, reading: snapshot(.cursor))
        let devin = ReachingClient(provider: .devin, reading: snapshot(.devin))
        let store = try makeStore([cursor, devin], enabled: [.cursor, .devin])
        let gate = TestGate()
        store.waitBeforeOfflineRetry = { await gate.wait() }
        defer { gate.open(); store.stop() }
        await store.refresh(force: true)
        let retry = try XCTUnwrap(store.offlineRetry)
        network(status: 200)
        gate.open()
        await retry.value
        XCTAssertEqual([cursor.calls, devin.calls], [2, 2])
        guard case .live = store.statuses[.cursor], case .live = store.statuses[.devin] else {
            return XCTFail("Expected readings after the retry, got \(store.statuses)")
        }
        XCTAssertNil(store.offlineRetry)

        // Once: a retry that still can't connect is left to the timer.
        network(failure: .cannotFindHost)
        let offline = [ReachingClient(provider: .cursor, reading: snapshot(.cursor)), ReachingClient(provider: .devin, reading: snapshot(.devin))]
        let still = try makeStore(offline, enabled: [.cursor, .devin])
        defer { still.stop() }
        still.waitBeforeOfflineRetry = {}
        await still.refresh(force: true)
        await still.offlineRetry?.value
        XCTAssertEqual(offline.map(\.calls), [2, 2])
        XCTAssertNil(still.offlineRetry, "No second retry")

        // One provider alone can't tell an outage from being offline: no retry.
        let alone = ReachingClient(provider: .cursor, reading: snapshot(.cursor))
        let single = try makeStore([alone], enabled: [.cursor])
        defer { single.stop() }
        await single.refresh(force: true)
        XCTAssertNil(single.offlineRetry)
    }

    /// A server that answered with an error, or was too slow, was reached: that isn't the Mac
    /// being offline. No retry, and Claude's five minutes between calls hold.
    @MainActor
    func testServerErrorsAndTimeoutsKeepTheSpacingAndArentRetried() async throws {
        for (status, failure) in [(500, nil), (404, nil), (400, nil), (200, URLError.Code.timedOut)] as [(Int, URLError.Code?)] {
            network(status: status, failure: failure)
            let claude = ReachingClient(provider: .claude, reading: snapshot(.claude))
            let cursor = ReachingClient(provider: .cursor, reading: snapshot(.cursor))
            let store = try makeStore([claude, cursor], enabled: [.claude, .cursor])
            let gate = TestGate()
            store.waitBeforeOfflineRetry = { await gate.wait() }
            defer { gate.open(); store.stop() }
            await store.refresh(force: true)
            XCTAssertNil(store.offlineRetry, "\(status) \(String(describing: failure)) isn't offline")
            await store.refresh(force: true)
            XCTAssertEqual(claude.calls, 1, "\(status) \(String(describing: failure)): its server was called, so the spacing holds")
            XCTAssertEqual(cursor.calls, 2)
        }
    }

    /// The retry is an ordinary check: a provider resting after a recent call stays resting.
    @MainActor
    func testTheOfflineRetryKeepsEachProvidersSpacing() async throws {
        network(status: 200)
        let claude = ReachingClient(provider: .claude, reading: snapshot(.claude))
        let cursor = ReachingClient(provider: .cursor, reading: snapshot(.cursor))
        let devin = ReachingClient(provider: .devin, reading: snapshot(.devin))
        let store = try makeStore([claude, cursor, devin], enabled: [.claude, .cursor, .devin])
        let gate = TestGate()
        store.waitBeforeOfflineRetry = { await gate.wait() }
        defer { gate.open(); store.stop() }
        await store.refresh(force: true)
        XCTAssertEqual(claude.calls, 1)

        network(failure: .networkConnectionLost)
        await store.refresh(force: true)
        let retry = try XCTUnwrap(store.offlineRetry, "Cursor and Devin couldn't reach the network")
        network(status: 200)
        gate.open()
        await retry.value
        XCTAssertEqual([cursor.calls, devin.calls], [3, 3])
        XCTAssertEqual(claude.calls, 1, "Claude, called a moment ago, isn't called by the retry")
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

    // MARK: Time zone

    /// A change made here is dated in the zone the Mac is in now, read again rather than the one
    /// Foundation kept from launch.
    @MainActor
    func testAlertChoicesChangedHereAreDatedInTheMacsZoneNow() throws {
        let store = try makeStore([], enabled: [])
        let travelled = TimeZone.current.identifier == "Pacific/Chatham" ? "Pacific/Auckland" : "Pacific/Chatham"
        store.currentTimeZone = { TimeZone(identifier: travelled)! }
        store.updateAlertPreferences { $0.quietHours.toggle() }
        XCTAssertEqual(store.settings.alertPreferences.timeZoneID, travelled)
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

/// Holds whoever waits on it until `open`.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock {
            isOpen = true
            let resumed = waiting
            waiting = []
            return resumed
        }
        resumed.forEach { $0.resume() }
    }
}

/// Checks through `TokenroomHTTP`, so what the stubbed network does is what the store sees: an
/// answer of 200 is this reading, any other answer or failure is the client's usual error.
final class ReachingClient: ProviderClient, @unchecked Sendable {
    let provider: Provider
    private let reading: QuotaSnapshot
    private let lock = NSLock()
    private var count = 0

    init(provider: Provider, reading: QuotaSnapshot) {
        self.provider = provider
        self.reading = reading
    }

    var calls: Int {
        lock.withLock { count }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        lock.withLock { count += 1 }
        do {
            _ = try await TokenroomHTTP.get(URL(string: "https://usage.example.invalid/\(provider.rawValue)")!, token: nil, provider: provider)
            return .success(reading)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
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
