import Foundation
import XCTest
@testable import Tokenroom

final class UsageFactsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!

    private func window(used: Double, resetsIn: TimeInterval?) -> RelayWindow {
        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    private func pace(_ verdict: Pace.Verdict, severity: Pace.Severity = .none, runsOut: Date? = nil) -> Pace {
        Pace(verdict: verdict, delta: 0, elapsedFraction: 0.54, resetsAt: now.addingTimeInterval(86_400), runsOutAt: runsOut, severity: severity)
    }

    func testAWindowReadsAsResetsPacePlanAndCheck() {
        let facts = UsageFacts.facts(for: window(used: 78, resetsIn: 3 * 86_400 + 3_600), pace: pace(.onPace), plan: "Pro",
                                     checkedAt: now.addingTimeInterval(-120), isStale: false, now: now, timeZone: utc)
        XCTAssertEqual(facts.map(\.label), ["Resets", "Pace", "Plan", "Checked"])
        XCTAssertEqual(facts[0].value, "3d 1h")
        XCTAssertNotNil(facts[0].detail, "When, as a moment")
        XCTAssertEqual(facts[1].value, "On pace")
        XCTAssertEqual(facts[1].detail, "Even pace 54%")
        XCTAssertNil(facts[1].severity)
        XCTAssertEqual(facts[2].value, "Pro")
        XCTAssertEqual(facts[3].value, "2m ago")
    }

    func testAheadOfPaceSaysWhenItRunsOutAndNeedsAttention() {
        let runsOut = now.addingTimeInterval(7_200)
        let fact = UsageFacts.paceFact(pace(.ahead, severity: .tight, runsOut: runsOut), now: now, timeZone: utc)
        XCTAssertEqual(fact.value, "Ahead")
        XCTAssertEqual(fact.detail, "Runs out \(Pace.shortMoment(runsOut, now: now, timeZone: utc))")
        XCTAssertEqual(fact.severity, .tight)
    }

    func testAStaleOrElapsedWindowShowsNoPace() {
        let stale = UsageFacts.facts(for: window(used: 40, resetsIn: 3_600), pace: pace(.onPace), plan: nil, checkedAt: nil, isStale: true, now: now)
        XCTAssertEqual(stale.map(\.label), ["Resets"])
        let elapsed = UsageFacts.facts(for: window(used: 40, resetsIn: -60), pace: pace(.onPace), plan: nil, checkedAt: nil, isStale: false, now: now)
        XCTAssertEqual(elapsed.map(\.label), ["Resets"])
        XCTAssertEqual(elapsed.first?.detail, "Awaiting reading", "Never a made-up live zero")
    }

    func testCountdowns() {
        XCTAssertEqual(UsageFacts.countdown(to: now.addingTimeInterval(2 * 3_600 + 600), now: now), "2h 10m")
        XCTAssertEqual(UsageFacts.countdown(to: now.addingTimeInterval(30), now: now), "1m")
        XCTAssertEqual(UsageFacts.countdown(to: now.addingTimeInterval(-1), now: now), "Reset due")
    }
}
