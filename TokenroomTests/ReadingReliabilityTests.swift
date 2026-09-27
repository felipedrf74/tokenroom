import XCTest
@testable import Tokenroom

final class ReadingReliabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)
    private func item(_ id: String, age: TimeInterval, used: Double = 40) -> ReadingCache.Item {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400)
        let provider = RelayProvider(id: id, name: id, shortName: id, monogram: "X", tint: "#000000", state: "live", checkedAt: now.addingTimeInterval(-age), primaryWindowID: window.id, windows: [window])
        return .init(provider: provider, source: "Mac")
    }

    func testIndividualReadingAgeOverridesFreshEnvelopeAndCacheTimes() {
        let items = [item("fresh", age: 60), item("stale", age: 3601), item("expired", age: 7 * 86_400 + 1)]
        let source = RelayMerge.Source(id: "mac", label: "Mac", envelope: .init(producer: "mac", appVersion: "1", checkedAt: now, providers: items.map(\.provider)))
        let output = ReadingAssembler.assemble(sources: [source], histories: [:], now: now)
        XCTAssertEqual(Set(output.connected.map(\.id)), ["fresh", "stale"])
        XCTAssertEqual(output.connected.first { $0.id == "stale" }?.provider.state, "stale")
        let cache = ReadingCache(savedAt: now, isSample: false, items: items).presented(at: now)
        XCTAssertEqual(cache.staleCount(at: now), 1)
        XCTAssertEqual(cache.checkedAt, now.addingTimeInterval(-3601))
    }

    func testPartialUpdateKeepsEachNewestReadingAndHonorsRemoval() {
        let previous = ReadingCache(savedAt: now, isSample: false, items: [item("olderIncoming", age: 0), item("newerIncoming", age: 60), item("removed", age: 0)])
        let incoming = ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: [item("olderIncoming", age: 120), item("newerIncoming", age: 0)])
        let merged = previous.mergingUpdate(incoming)
        XCTAssertEqual(merged.items.map(\.id), ["olderIncoming", "newerIncoming"])
        XCTAssertTrue(merged.items.allSatisfy { $0.provider.checkedAt == now })
        XCTAssertEqual(merged.mergingUpdate(previous), merged, "A delayed whole cache cannot undo removals")
    }

    func testWatchSignOutRejectsOldHandoverEvenAfterRevalidation() {
        var gate = WatchAccountGate()
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("one", age: 0)])
        XCTAssertFalse(gate.accepts(cache), "Startup must validate iCloud first")
        gate.confirmAvailable()
        XCTAssertTrue(gate.accepts(cache))
        gate.signOut(at: now.addingTimeInterval(10))
        XCTAssertFalse(gate.accepts(cache))
        gate.confirmAvailable()
        XCTAssertFalse(gate.accepts(cache))
        var fresh = cache
        fresh.savedAt = now.addingTimeInterval(20)
        XCTAssertTrue(gate.accepts(fresh))
    }

    func testExhaustedSecondarySessionRanksAheadOfHealthyHeadline() {
        var urgent = item("urgent", age: 0, used: 10)
        urgent.provider.windows.append(.init(id: "session", kind: "session", title: "5-hour", used: 100, resetsAt: now.addingTimeInterval(3600), periodSec: 5 * 3600))
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("ordinary", age: 0, used: 70), urgent]).presented(at: now)
        XCTAssertEqual(cache.items.first?.id, "urgent")
        XCTAssertEqual(cache.items.first?.provider.primaryWindow?.used, 10)
        XCTAssertEqual(UsageRanking.limitWarning(for: urgent.provider, now: now), "5-hour limit reached")
        XCTAssertNil(UsageRanking.limitWarning(for: urgent.provider, now: now.addingTimeInterval(3600)))
    }

    func testElapsedWindowCannotForecastAlertOrRankAsReached() {
        var previous = item("one", age: 0, used: 60).provider
        previous.windows[0].resetsAt = now
        var current = previous
        current.windows[0].used = 100
        XCTAssertTrue(AlertRules.alerts(previous: previous, current: current, preferences: AlertPreferences(), now: now).isEmpty)
        XCTAssertNil(UsageRanking.pace(for: current.windows[0], isStale: false, history: nil, now: now))
        XCTAssertEqual(ReadingText.reset(current.windows[0], now: now), "Reset · awaiting reading")
    }
    func testWidgetTimelinesIncludeFreshnessAndExpiryBoundaries() {
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("old", age: 3500)])
        let dates = cache.presentationDates(after: now, until: now.addingTimeInterval(8 * 3600))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(101)))
        let expiring = ReadingCache(savedAt: now, isSample: false, items: [item("old", age: 7 * 86_400 - 60)])
        XCTAssertTrue(expiring.presentationDates(after: now, until: now.addingTimeInterval(3600)).contains(now.addingTimeInterval(61)))
        XCTAssertTrue(expiring.presented(at: now.addingTimeInterval(61)).items.isEmpty)
    }

}
