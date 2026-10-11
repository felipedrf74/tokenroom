import XCTest
@testable import Tokenroom

final class AlertProjectionRegressionTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23))!

    private var preferences: AlertPreferences {
        var result = AlertPreferences()
        result.timeZoneID = "UTC"
        result.quietHours = false
        return result
    }

    private func reading(used: Double = 60, state: String, runsOutIn: TimeInterval? = 20 * 60) -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: state, checkedAt: now, fetchedAt: now, primaryWindowID: "session",
            windows: [RelayWindow(
                id: "session", kind: "session", title: "Session", used: used,
                resetsAt: now.addingTimeInterval(4 * 3600), periodSec: 5 * 3600,
                pace: runsOutIn.map { RelayPace(runsOutAt: now.addingTimeInterval($0)) }
            )]
        )
    }

    func testStaleMoneyProjectionNeverRaisesUsageRunOut() {
        for lowBalance in [false, true] {
            var choices = preferences
            choices.lowBalance = lowBalance
            let window = RelayWindow(
                id: "spend-month", kind: "monthly", title: "This month", used: 60,
                resetsAt: now.addingTimeInterval(10 * 86_400), periodSec: 30 * 86_400,
                amount: QuotaAmount(used: 600, limit: 1000, unit: "usd"), metered: true,
                pace: RelayPace(runsOutAt: now.addingTimeInterval(2 * 86_400))
            )
            var provider = RelayProvider(
                id: "anthropicOrg", name: "Anthropic API", shortName: "Anthropic API", monogram: "AN", tint: "#B85C38",
                state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: window.id, windows: [window]
            )
            var ledger = AlertLedger()
            XCTAssertTrue(ledger.process([provider], preferences: choices, now: now).isEmpty)
            provider.state = "stale"
            XCTAssertTrue(ledger.process([provider], preferences: choices, now: now).isEmpty,
                          "A spend budget must not turn into a subscription run-out alert when stale")
        }
    }

    func testPendingProjectedRunOutStopsBeingUrgentAnHourAfterProjection() throws {
        var ledger = AlertLedger()
        ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: preferences, now: now)
        let raised = try XCTUnwrap(ledger.process([reading(state: "stale")], preferences: preferences, now: now).first)
        XCTAssertTrue(raised.isUrgent)
        // A failed delivery can leave this pending through a relaunch.
        ledger = try RelayEnvelope.decoder.decode(AlertLedger.self, from: RelayEnvelope.encoder.encode(ledger))
        let later = now.addingTimeInterval(2 * 3600)
        let retried = try XCTUnwrap(ledger.due(preferences: preferences, now: later).first)
        XCTAssertFalse(retried.isUrgent, "A projection over an hour in the past must no longer interrupt quiet hours")
        var quiet = preferences
        quiet.quietHours = true
        XCTAssertTrue(ledger.due(preferences: quiet, now: later).isEmpty)
    }

    func testHeldProjectedRunOutBecomesUrgentWithinTheHour() throws {
        var quiet = preferences
        quiet.quietHours = true
        var ledger = AlertLedger()
        ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: quiet, now: now)
        let raised = try XCTUnwrap(ledger.process([reading(state: "stale", runsOutIn: 90 * 60)], preferences: quiet, now: now).first)
        XCTAssertFalse(raised.isUrgent)
        XCTAssertTrue(ledger.due(preferences: quiet, now: now).isEmpty)
        let due = ledger.due(preferences: quiet, now: now.addingTimeInterval(31 * 60))
        XCTAssertEqual(due.count, 1, "A held projection now 59 minutes away must bypass quiet hours")
        XCTAssertEqual(due.first?.isUrgent, true)
    }

    func testProjectedUrgencyUsesStrictOneHourBounds() throws {
        let heldProvider = reading(state: "stale", runsOutIn: 90 * 60)
        let held = try XCTUnwrap(AlertRules.runsOut(heldProvider, window: heldProvider.windows[0], preferences: preferences, now: now))
        for (remaining, urgent) in [(-3601.0, false), (-3600, false), (-3599, true), (0, true), (3599, true), (3600, false), (3601, false)] {
            let provider = reading(state: "stale", runsOutIn: remaining)
            let alert = try XCTUnwrap(AlertRules.runsOut(provider, window: provider.windows[0], preferences: preferences, now: now))
            XCTAssertEqual(alert.isUrgent, urgent, "Remaining \(remaining) seconds")
            let retryAt = now.addingTimeInterval(90 * 60 - remaining)
            XCTAssertEqual(AlertRules.refreshed(held, now: retryAt).isUrgent, urgent, "Retry with \(remaining) seconds remaining")
        }
    }

    func testOlderPendingRunOutKeepsItsStoredUrgency() throws {
        let data = Data(#"{"id":"legacy","provider":"claude","kind":"runsOut","level":0,"title":"Usage","body":"Last reading","resetsAt":1800000000,"isUrgent":true,"window":"session","instance":"old","windowKind":"session"}"#.utf8)
        let older = try RelayEnvelope.decoder.decode(UsageAlert.self, from: data)
        XCTAssertNil(older.projectedRunsOutAt)
        XCTAssertTrue(AlertRules.refreshed(older, now: now.addingTimeInterval(2 * 3600)).isUrgent,
                      "Older alerts did not persist a projection time and retain their stored urgency")
    }

    func testStaleRunOutNeedsLiveBaselineAndDeduplicatesAfterPersistence() throws {
        var ledger = AlertLedger()
        let stale = reading(state: "stale")
        XCTAssertTrue(ledger.process([stale], preferences: preferences, now: now).isEmpty)
        XCTAssertTrue(ledger.lastSeen.isEmpty)
        let live = reading(used: 40, state: "live", runsOutIn: nil)
        XCTAssertTrue(ledger.process([live], preferences: preferences, now: now).isEmpty)
        let raised = ledger.process([stale], preferences: preferences, now: now)
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].body.contains("at last check"))
        XCTAssertEqual(ledger.lastSeen[live.id], live)
        ledger.markSent(raised.map(\.id), at: now)
        ledger = try RelayEnvelope.decoder.decode(AlertLedger.self, from: RelayEnvelope.encoder.encode(ledger))
        XCTAssertTrue(ledger.process([stale], preferences: preferences, now: now.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(ledger.lastSeen[live.id], live)
    }

    func testElapsedProjectionDoesNotRaiseOrRemainDue() {
        var ledger = AlertLedger()
        ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: preferences, now: now)
        let stale = reading(state: "stale")
        XCTAssertEqual(ledger.process([stale], preferences: preferences, now: now).map(\.kind), [.runsOut])
        let later = now.addingTimeInterval(4 * 3600)
        XCTAssertTrue(ledger.process([stale], preferences: preferences, now: later).isEmpty)
        XCTAssertTrue(ledger.due(preferences: preferences, now: later).isEmpty)
        XCTAssertNil(AlertRules.runsOut(stale, window: stale.windows[0], preferences: preferences, now: later))
    }

    func testLiveRunOutKeepsTheMeasuredPercentageBody() throws {
        let provider = reading(state: "live")
        let alert = try XCTUnwrap(AlertRules.runsOut(provider, window: provider.windows[0], preferences: preferences, now: now))
        XCTAssertEqual(alert.body, "60% used, 4 hours before it resets.")
    }

    func testResetDriftDoesNotDuplicateAPendingProjectionAfterRelaunch() throws {
        var ledger = AlertLedger()
        ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: preferences, now: now)
        let raised = ledger.process([reading(state: "stale")], preferences: preferences, now: now)
        XCTAssertEqual(raised.count, 1)
        ledger = try RelayEnvelope.decoder.decode(AlertLedger.self, from: RelayEnvelope.encoder.encode(ledger))
        var moved = reading(state: "stale")
        moved.windows[0].resetsAt = now.addingTimeInterval(4 * 3600 + 600)
        XCTAssertTrue(ledger.process([moved], preferences: preferences, now: now.addingTimeInterval(60)).isEmpty,
                      "A ten-minute reset move must not queue the same projection under a second rounded ID")
        XCTAssertEqual(ledger.pending.count, 1)
        XCTAssertEqual(ledger.due(preferences: preferences, now: now.addingTimeInterval(60)).map(\.id), raised.map(\.id))
    }

    func testResetDriftDoesNotRepeatADeliveredProjectionButANewWindowRearms() throws {
        for state in ["live", "stale"] {
            var ledger = AlertLedger()
            ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: preferences, now: now)
            let raised = ledger.process([reading(state: "stale")], preferences: preferences, now: now)
            ledger.markSent(raised.map(\.id), at: now)
            ledger = try RelayEnvelope.decoder.decode(AlertLedger.self, from: RelayEnvelope.encoder.encode(ledger))
            var moved = reading(state: state)
            moved.windows[0].resetsAt = now.addingTimeInterval(4 * 3600 + 600)
            XCTAssertTrue(ledger.process([moved], preferences: preferences, now: now.addingTimeInterval(60)).isEmpty,
                          "A delivered projection must not repeat when a \(state) reading moves the same reset")
            var next = reading(state: state, runsOutIn: 5.5 * 3600)
            next.windows[0].resetsAt = now.addingTimeInterval(9 * 3600)
            XCTAssertEqual(ledger.process([next], preferences: preferences, now: now.addingTimeInterval(5 * 3600)).map(\.kind), [.runsOut],
                           "The next actual window can raise its own run-out")
        }
    }

    func testLegacyDeliveredRunOutDoesNotRepeatWhenItsResetDrifts() throws {
        var ledger = AlertLedger()
        ledger.process([reading(used: 40, state: "live", runsOutIn: nil)], preferences: preferences, now: now)
        let raised = ledger.process([reading(state: "stale")], preferences: preferences, now: now)
        ledger.markSent(raised.map(\.id), at: now)
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: RelayEnvelope.encoder.encode(ledger)) as? [String: Any])
        older.removeValue(forKey: "runOutInstances")
        ledger = try RelayEnvelope.decoder.decode(AlertLedger.self, from: JSONSerialization.data(withJSONObject: older))
        var moved = reading(state: "stale")
        moved.windows[0].resetsAt = now.addingTimeInterval(4 * 3600 + 600)
        XCTAssertTrue(ledger.process([moved], preferences: preferences, now: now.addingTimeInterval(60)).isEmpty,
                      "An older ledger's sent IDs and live baseline identify the run-out already delivered")
    }
}
