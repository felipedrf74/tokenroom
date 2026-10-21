import CloudKit
import XCTest
@testable import Tokenroom

/// The Mac's iCloud sender against a stand-in for iCloud: nothing leaves the Mac.
final class RelayPublisherTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach(TestDefaults.remove)
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let (name, defaults) = TestDefaults.make(owner: "\(Self.self)", index: suites.count)
        suites.append(name)
        return defaults
    }

    private func envelope() -> RelayEnvelope {
        RelayEnvelope(producer: "mac", appVersion: "test", checkedAt: Date(), providers: [])
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// One call that never answers gives way at the budget, and the round after it waits that
    /// out rather than holding on iCloud call by call.
    @MainActor
    func testAniCloudCallThatNeverAnswersGivesWay() async {
        let cloud = StandInCloud(holdsPublishes: 1)
        defer { cloud.release() }
        let publisher = RelayPublisher(defaults: makeDefaults(), cloud: cloud, iCloudBudget: 0.2)
        let started = Date()
        await publisher.publish(envelope())
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(publisher.state, .failed("Couldn't reach iCloud. Trying again soon."))
        XCTAssertNil(publisher.lastSent)

        let preferences = AlertPreferences()
        let kept = await publisher.syncAlertPreferences(local: preferences)
        XCTAssertEqual(kept, preferences)
        XCTAssertEqual(cloud.preferenceReads, 0, "Waits out the call that didn't answer")
    }

    /// Sync turned off while a send is out stays Off, and turning it back on starts afresh: the
    /// zone is made again and everything is sent.
    @MainActor
    func testTurningSyncOffDuringASendKeepsItOff() async {
        let cloud = StandInCloud(holdsPublishes: 1)
        let publisher = RelayPublisher(defaults: makeDefaults(), cloud: cloud, iCloudBudget: 5)
        let sending = Task { await publisher.publish(envelope()) }
        await waitUntil { cloud.publishStarts == 1 }
        publisher.isEnabled = false
        XCTAssertEqual(publisher.state, .off)
        cloud.release()
        await sending.value
        XCTAssertEqual(cloud.envelopes.count, 1, "The send that was out still went")
        XCTAssertEqual(publisher.state, .off)

        publisher.isEnabled = true
        XCTAssertEqual(publisher.state, .waiting)
        await waitUntil { cloud.zoneResets == 1 }
        XCTAssertEqual(cloud.zoneResets, 1)
        await publisher.publish(envelope())
        XCTAssertEqual(cloud.envelopes.count, 2, "Sent again at once: what was sent before is forgotten")
    }

    /// Off stops new writes: alerts not yet sent stay queued. The one already out may still land.
    @MainActor
    func testTurningSyncOffStopsTheAlertsNotYetSent() async {
        let cloud = StandInCloud(holdsAlerts: 1)
        let publisher = RelayPublisher(defaults: makeDefaults(), cloud: cloud, iCloudBudget: 5)
        let alerts = ["a1", "a2", "a3"].map {
            UsageAlert(id: $0, provider: "claude", kind: .threshold, level: 80, title: "", body: "", isUrgent: false)
        }
        let sending = Task { await publisher.sendAlerts(alerts) }
        await waitUntil { cloud.alertStarts == 1 }
        publisher.isEnabled = false
        cloud.release()
        let sent = await sending.value
        XCTAssertEqual(cloud.savedAlerts, ["a1"])
        XCTAssertEqual(sent, ["a1"], "a2 and a3 wait in the ledger for sync to come back")
        XCTAssertEqual(publisher.state, .off)
    }
}

/// iCloud as `RelayPublisher` sees it, in memory. The first `holdsPublishes` sends, and the first
/// `holdsAlerts` alert saves, wait until `release`, whatever the caller does meanwhile, like a
/// call that doesn't answer.
final class StandInCloud: RelayCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Int
    private var heldAlerts: Int
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var sent: [RelayEnvelope] = []
    private var alerts: [String] = []
    private var starts = 0
    private var alertCalls = 0
    private var resets = 0
    private var reads = 0

    init(holdsPublishes: Int = 0, holdsAlerts: Int = 0) {
        held = holdsPublishes
        heldAlerts = holdsAlerts
    }

    var envelopes: [RelayEnvelope] { lock.withLock { sent } }
    var publishStarts: Int { lock.withLock { starts } }
    var savedAlerts: [String] { lock.withLock { alerts } }
    var alertStarts: Int { lock.withLock { alertCalls } }
    var zoneResets: Int { lock.withLock { resets } }
    var preferenceReads: Int { lock.withLock { reads } }

    private func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                if isReleased { return true }
                waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let resumed = lock.withLock {
            isReleased = true
            let resumed = waiting
            waiting = []
            return resumed
        }
        resumed.forEach { $0.resume() }
    }

    func accountStatus() async throws -> CKAccountStatus { .available }
    func accountFingerprint() async throws -> String { "test" }

    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws {
        let holds = lock.withLock {
            starts += 1
            guard held > 0 else { return false }
            held -= 1
            return true
        }
        if holds {
            await waitForRelease()
        }
        lock.withLock { sent.append(envelope) }
    }

    func publishHistory(sourceID: String, history: RelayHistory) async throws {}

    func alertPreferences() async throws -> AlertPreferences? {
        lock.withLock { reads += 1 }
        return nil
    }

    func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution {
        AlertPreferencesSync.Resolution(preferences: local, needsPublish: false)
    }

    func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date) async throws -> Bool { false }
    func saveAlert(_ alert: UsageAlert) async throws {
        let holds = lock.withLock {
            alertCalls += 1
            guard heldAlerts > 0 else { return false }
            heldAlerts -= 1
            return true
        }
        if holds {
            await waitForRelease()
        }
        lock.withLock { alerts.append(alert.id) }
    }
    func pruneEvents(now: Date) async throws {}
    func saveEvent(id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String) async throws {}

    func resetZone() async {
        lock.withLock { resets += 1 }
    }
}
