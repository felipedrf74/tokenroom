import XCTest
@testable import Tokenroom

/// The iPhone Usage tab's tiles and its Close to a limit list, tested on the Mac.
final class UsageTileTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    private func provider(id: String = "claude", state: String = "live", primary: String? = nil, _ windows: [RelayWindow]) -> RelayProvider {
        RelayProvider(
            id: id, name: id, shortName: id, monogram: "C", tint: "#D97757", state: state,
            checkedAt: now, fetchedAt: now, primaryWindowID: primary ?? windows.first?.id, windows: windows
        )
    }

    private func weekly(_ used: Double, resetsIn: TimeInterval = 3 * 86_400) -> RelayWindow {
        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 7 * 86_400)
    }

    private func session(_ used: Double, resetsIn: TimeInterval = 2 * 3600, period: Double? = 5 * 3600) -> RelayWindow {
        RelayWindow(id: "session", kind: "session", title: "Session", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: period)
    }

    func testTheRingTakesTheLongWindowAndTheBarTheSession() {
        // A primary session (as Claude's status line can report) still leaves the weekly for the ring.
        let both = UsageTiles.tile(for: provider(primary: "session", [session(40), weekly(64)]))
        XCTAssertEqual(both.ring?.id, "weekly")
        XCTAssertEqual(both.bar?.id, "session")
        XCTAssertNil(both.balance)

        let weeklyOnly = UsageTiles.tile(for: provider([weekly(23)]))
        XCTAssertEqual(weeklyOnly.ring?.id, "weekly")
        XCTAssertNil(weeklyOnly.bar)

        let sessionOnly = UsageTiles.tile(for: provider([session(30)]))
        XCTAssertEqual(sessionOnly.ring?.id, "session", "A provider with only a session shows it as the ring")
        XCTAssertNil(sessionOnly.bar)

        let cycle = RelayWindow(id: "cycle", kind: "billingCycle", title: "This cycle", used: 57, resetsAt: now.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(UsageTiles.tile(for: provider(id: "cursor", [cycle])).ring?.id, "cycle")

        let balance = RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 0, resetsAt: nil, amount: QuotaAmount(remaining: 12.4, unit: "usd"), metered: false)
        let balanceTile = UsageTiles.tile(for: provider(id: "deepseek", [balance]))
        XCTAssertNil(balanceTile.ring)
        XCTAssertNil(balanceTile.bar)
        XCTAssertEqual(balanceTile.balance?.id, "balance-usd")
    }

    func testSessionsAreNamedByTheirLength() {
        XCTAssertEqual(session(10).displayTitle, "5-hour")
        XCTAssertEqual(session(10, period: nil).displayTitle, "5-hour", "Sessions are 5 hours unless the provider says otherwise")
        XCTAssertEqual(session(10, period: 4 * 3600).displayTitle, "4-hour")
        XCTAssertEqual(weekly(10).displayTitle, "Weekly")
        XCTAssertEqual(session(10).limitName, "5-hour limit")
        XCTAssertEqual(weekly(10).limitName, "weekly limit")
        XCTAssertEqual(RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 1, resetsAt: nil).limitName, "limit for premium requests")
        XCTAssertEqual(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 10, resetsAt: nil, windowSeconds: 5 * 3600).displayTitle, "5-hour")
    }

    func testCloseMeansEightyPercentUsedOrRunningOutBeforeTheReset() {
        XCTAssertTrue(UsageTiles.isClose(weekly(80), pace: nil))
        XCTAssertFalse(UsageTiles.isClose(weekly(79), pace: nil))

        // 60% of a 5-hour window, 2.5 hours in: ahead of pace, out before the reset.
        let hot = session(60, resetsIn: 2.5 * 3600)
        let hotPace = UsageRanking.pace(for: hot, isStale: false, history: nil, now: now)
        XCTAssertEqual(hotPace?.verdict, .ahead)
        XCTAssertNotNil(hotPace?.runsOutAt)
        XCTAssertTrue(UsageTiles.isClose(hot, pace: hotPace))

        // Ahead of pace, but lasting to the reset, is not close.
        let lasting = Pace(verdict: .ahead, delta: 12, elapsedFraction: 0.5, resetsAt: now.addingTimeInterval(3600), runsOutAt: nil, severity: .none)
        XCTAssertFalse(UsageTiles.isClose(session(62), pace: lasting))

        let calm = session(20, resetsIn: 2.5 * 3600)
        XCTAssertFalse(UsageTiles.isClose(calm, pace: UsageRanking.pace(for: calm, isStale: false, history: nil, now: now)))

        let balance = RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 90, resetsAt: nil, metered: false)
        XCTAssertFalse(UsageTiles.isClose(balance, pace: nil), "An amount-only balance has no limit to be close to")
    }

    func testCloseWindowsPutTheMostUrgentFirst() {
        let readings: [(provider: RelayProvider, history: [String: UsageHistory])] = [
            // Past 80%, no reset known: close, but nothing runs out.
            (provider(id: "copilot", [RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 83, resetsAt: nil)]), [:]),
            // Weekly at 78%, 94 hours into the week: runs out in about a day.
            (provider(id: "openai", [weekly(78, resetsIn: 74 * 3600), session(22, resetsIn: 3 * 3600 + 40 * 60)]), [:]),
            // 5-hour at 86%, 3h48m in: runs out in about half an hour.
            (provider(id: "claude", primary: "weekly", [session(86, resetsIn: 72 * 60), weekly(64, resetsIn: 53 * 3600)]), [:]),
            // The limit is reached.
            (provider(id: "kimiCode", [session(100, resetsIn: 90 * 60)]), [:]),
            // Stale readings and calm windows stay out.
            (provider(id: "zai", state: "stale", [weekly(95)]), [:]),
            (provider(id: "grok", [weekly(23, resetsIn: 102 * 3600)]), [:]),
        ]
        let close = UsageTiles.closeWindows(readings, now: now)
        XCTAssertEqual(close.map { "\($0.provider.id)/\($0.window.id)" }, ["kimiCode/session", "claude/session", "openai/weekly", "copilot/premium"])
    }

    func testLeadSaysHowLongBeforeTheReset() {
        XCTAssertEqual(UsageTiles.lead(runsOut: now, resetsAt: now.addingTimeInterval(35 * 60)), "35 min before it resets")
        XCTAssertEqual(UsageTiles.lead(runsOut: now, resetsAt: now.addingTimeInterval(3600)), "1 hour before it resets")
        XCTAssertEqual(UsageTiles.lead(runsOut: now, resetsAt: now.addingTimeInterval(3 * 3600)), "3 hours before it resets")
        XCTAssertEqual(UsageTiles.lead(runsOut: now, resetsAt: now.addingTimeInterval(26 * 3600)), "1 day before it resets")
        XCTAssertEqual(UsageTiles.lead(runsOut: now, resetsAt: now.addingTimeInterval(47 * 3600)), "2 days before it resets")
    }
}
