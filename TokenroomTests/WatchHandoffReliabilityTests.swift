import XCTest
@testable import Tokenroom

final class WatchHandoffReliabilityTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)

    private func cache(_ date: Date, used: Double = 40, sample: Bool = false) -> ReadingCache {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used,
                                 resetsAt: now.addingTimeInterval(86_400), periodSec: 7 * 86_400)
        let provider = RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C",
                                     tint: "#000000", state: "live", checkedAt: date,
                                     primaryWindowID: window.id, windows: [window])
        return ReadingCache(savedAt: date, isSample: sample, items: [.init(provider: provider, source: "Mac")])
    }

    func testFreshSavedCheckWinsEvenWhenUsageDidNotChange() throws {
        let retained = cache(now)
        let saved = cache(now.addingTimeInterval(3601))
        XCTAssertEqual(retained.materialHash, saved.materialHash)
        let sent = try XCTUnwrap(WatchHandoff.cacheToSend(retained: retained, saved: saved))
        XCTAssertEqual(sent.checkedAt, saved.checkedAt,
                       "A Watch requesting readings must not age unchanged usage from the last context")
        XCTAssertEqual(sent.items.first?.provider.primaryWindow?.used, 40)
    }

    func testOldDiskCannotUndoNewestMembership() throws {
        let saved = cache(now)
        let removed = ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: [])
        XCTAssertEqual(WatchHandoff.cacheToSend(retained: removed, saved: saved), removed)
    }

    func testSampleAndNewerSchemaNeverReachWatch() {
        XCTAssertNil(WatchHandoff.cacheToSend(retained: cache(now, sample: true), saved: nil))
        var future = cache(now)
        future.v = ReadingCache.version + 1
        XCTAssertNil(WatchHandoff.cacheToSend(retained: future, saved: nil))
        XCTAssertEqual(WatchHandoff.cacheToSend(retained: future, saved: cache(now)), cache(now))
    }

    func testForcedRefreshDuringRefreshCoalescesIntoOneFollowUp() {
        var gate = WatchRefreshGate()
        XCTAssertTrue(gate.begin(force: false, now: now))
        XCTAssertFalse(gate.begin(force: true, now: now.addingTimeInterval(1)))
        XCTAssertFalse(gate.begin(force: true, now: now.addingTimeInterval(2)))
        XCTAssertTrue(gate.finish(), "An account change or explicit refresh cannot disappear during iCloud work")
        XCTAssertTrue(gate.begin(force: true, now: now.addingTimeInterval(10)))
        XCTAssertFalse(gate.finish(), "The coalesced request runs once")
    }

    func testForegroundSpacingSurvivesClockMovingBackwards() {
        var gate = WatchRefreshGate()
        XCTAssertTrue(gate.begin(force: false, now: now))
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.begin(force: false, now: now.addingTimeInterval(30)))
        XCTAssertTrue(gate.begin(force: false, now: now.addingTimeInterval(-60)),
                      "Setting the clock back must not disable refresh until the previous clock catches up")
        XCTAssertFalse(gate.finish())
    }

    func testAccountChangeQueuesRevalidationInsteadOfReusingThrottle() {
        var gate = WatchRefreshGate()
        XCTAssertTrue(gate.begin(force: false, now: now))
        gate.accountChanged()
        XCTAssertFalse(gate.begin(force: true, now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.finish())
        XCTAssertTrue(gate.begin(force: false, now: now.addingTimeInterval(2)))
    }

    func testFreshnessRequestCarriesNoProviderOrCredential() {
        XCTAssertEqual(WatchHandoff.refreshReadingsMessage as? [String: String], ["refresh": "readings"])
        XCTAssertTrue(WatchHandoff.asksToRefreshReadings(["refresh": "readings"]))
        XCTAssertFalse(WatchHandoff.asksToRefreshReadings(["refresh": "readings", "provider": "claude"]))
        XCTAssertFalse(WatchHandoff.asksToRefreshReadings(["refresh": "keys"]))
        XCTAssertFalse(WatchHandoff.asksToRefreshReadings(["open": "connect"]))
        XCTAssertFalse(WatchHandoff.asksToRefreshReadings([:]))
    }

    func testIncomingHandoffRequiresRealReadableCache() throws {
        let real = cache(now)
        let data = try RelayEnvelope.encoder.encode(real)
        let context = WatchHandoff.context(readings: data, connectAvailable: true)
        let payload = try XCTUnwrap(WatchHandoff.payload(in: context))
        XCTAssertEqual(payload.cache, real)
        XCTAssertTrue(payload.connectAvailable)
        XCTAssertNil(WatchHandoff.payload(in: ["readings": Data("broken".utf8)]))
        XCTAssertNil(WatchHandoff.payload(in: ["readings": "not data"]))
        XCTAssertNil(WatchHandoff.payload(in: ["connectAvailable": true]))
        var future = real
        future.v = ReadingCache.version + 1
        XCTAssertNil(WatchHandoff.payload(in: ["readings": try RelayEnvelope.encoder.encode(future)]))
        XCTAssertNil(WatchHandoff.payload(in: ["readings": try RelayEnvelope.encoder.encode(cache(now, sample: true))]))
    }

    func testAccountChangeRejectsRetainedAndFailedToClearOldDisk() {
        let previous = cache(now)
        XCTAssertNil(WatchHandoff.cacheToSend(retained: previous, saved: previous, accountGeneration: "generation-new"),
                     "Both retained memory and a disk file left after a failed clear stay quarantined")
        var current = cache(now.addingTimeInterval(10), used: 20)
        current.accountGeneration = "generation-new"
        XCTAssertEqual(WatchHandoff.cacheToSend(retained: previous, saved: current, accountGeneration: "generation-new"), current)
        var late = cache(now.addingTimeInterval(20), used: 90)
        late.accountGeneration = "generation-old"
        XCTAssertEqual(WatchHandoff.cacheToSend(retained: current, saved: late, accountGeneration: "generation-new"), current,
                       "A newer timestamp cannot cross the account fence")
    }
}
