import XCTest
@testable import Tokenroom

/// 2.1's alert changes: separate levels for 5-hour limits, the run-out alert, and the names.
final class AlertLimitTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!

    private var preferences: AlertPreferences {
        var preferences = AlertPreferences()
        preferences.timeZoneID = "UTC"
        preferences.quietHours = false
        return preferences
    }

    private func claude(_ windows: [RelayWindow]) -> RelayProvider {
        RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: windows.first?.id, windows: windows
        )
    }

    private func session(_ used: Double, resetsIn: TimeInterval) -> RelayWindow {
        RelayWindow(id: "session", kind: "session", title: "Session", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 5 * 3600)
    }

    private func weekly(_ used: Double, resetsIn: TimeInterval) -> RelayWindow {
        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 7 * 86_400)
    }

    private func alerts(from before: [RelayWindow], to after: [RelayWindow], _ preferences: AlertPreferences? = nil) -> [UsageAlert] {
        AlertRules.alerts(previous: claude(before), current: claude(after), preferences: preferences ?? self.preferences, now: now)
    }

    // MARK: Levels and names

    func testSessionsAndLongerLimitsHaveTheirOwnLevels() {
        var choices = preferences
        choices.sessionThresholds = [95]
        let raised = alerts(from: [session(70, resetsIn: 3 * 3600), weekly(70, resetsIn: 3 * 86_400)],
                            to: [session(82, resetsIn: 3 * 3600), weekly(82, resetsIn: 3 * 86_400)], choices)
        XCTAssertEqual(raised.filter { $0.kind == .threshold }.map(\.window), ["weekly"], "Sessions at 80% stay quiet with only 95% on")
        XCTAssertEqual(raised.first { $0.kind == .threshold }?.title, "Claude: 80% of weekly limit used")

        let ninetyFive = alerts(from: [session(90, resetsIn: 3600)], to: [session(96, resetsIn: 3600)], choices)
        XCTAssertEqual(ninetyFive.map(\.title), ["Claude: 95% of 5-hour limit used"])
        XCTAssertEqual(ninetyFive.first?.windowKind, "session")
        XCTAssertTrue(ninetyFive.first?.isSession == true)
    }

    func testOlderChoicesGiveSessionsTheSameLevels() throws {
        let saved = Data(#"{"thresholds":[95],"resets":false}"#.utf8)
        let choices = try RelayEnvelope.decoder.decode(AlertPreferences.self, from: saved)
        XCTAssertEqual(choices.sessionThresholds, [95])
        XCTAssertTrue(choices.sessionRunsOut)
        XCTAssertTrue(choices.limitRunsOut)
        XCTAssertEqual(choices.subscribedKeys, ["threshold-95", "runsOut", "lowBalance-80", "lowBalance-95", "bankedNew", "bankedExpiring-48", "bankedExpiring-6", "test"])

        var off = choices
        off.sessionRunsOut = false
        off.limitRunsOut = false
        XCTAssertFalse(off.subscribedKeys.contains("runsOut"))

        let roundTrip = try RelayEnvelope.decoder.decode(AlertPreferences.self, from: RelayEnvelope.encoder.encode(choices))
        XCTAssertEqual(roundTrip, choices)
    }

    func testHeldAlertsFollowTheSwitchesForTheirKindOfLimit() {
        var choices = preferences
        choices.sessionThresholds = [95]
        choices.limitRunsOut = false
        let sessionEighty = UsageAlert(id: "a", provider: "claude", kind: .threshold, level: 80, title: "", body: "", isUrgent: false, window: "session", instance: "i", windowKind: "session")
        let weeklyEighty = UsageAlert(id: "b", provider: "claude", kind: .threshold, level: 80, title: "", body: "", isUrgent: false, window: "weekly", instance: "i", windowKind: "weekly")
        let olderEighty = UsageAlert(id: "c", provider: "claude", kind: .threshold, level: 80, title: "", body: "", isUrgent: false)
        let sessionRunsOut = UsageAlert(id: "d", provider: "claude", kind: .runsOut, level: 0, title: "", body: "", isUrgent: false, windowKind: "session")
        let weeklyRunsOut = UsageAlert(id: "e", provider: "claude", kind: .runsOut, level: 0, title: "", body: "", isUrgent: false, windowKind: "weekly")
        XCTAssertFalse(choices.allows(sessionEighty))
        XCTAssertTrue(choices.allows(weeklyEighty))
        XCTAssertTrue(choices.allows(olderEighty), "Alerts raised before 2.1 carry no kind and follow the general levels")
        XCTAssertTrue(choices.allows(sessionRunsOut))
        XCTAssertFalse(choices.allows(weeklyRunsOut))
        XCTAssertEqual(sessionRunsOut.key, "runsOut")
    }

    func testLevelsMergeOneByOneForSessionsToo() {
        let base = AlertPreferences()
        var local = base
        local.sessionThresholds = [95]
        var remote = base
        remote.thresholds = [80]
        let merged = AlertPreferences.merged(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.sessionThresholds, [95])
        XCTAssertEqual(merged.thresholds, [80])
    }

    // MARK: Runs out

    func testASessionOnCourseToRunOutBeforeItsResetAlertsOnce() {
        // 60% used 2.5 hours into 5: 24% an hour runs out 1h40m from now, 50 minutes early.
        let raised = alerts(from: [session(55, resetsIn: 2.5 * 3600 + 600)], to: [session(60, resetsIn: 2.5 * 3600)])
        XCTAssertEqual(raised.count, 1)
        let alert = raised[0]
        XCTAssertEqual(alert.kind, .runsOut)
        XCTAssertEqual(alert.id, "evt-claude-session-runsOut-\(AlertRules.instance(now.addingTimeInterval(2.5 * 3600), window: session(60, resetsIn: 2.5 * 3600), now: now))")
        XCTAssertTrue(alert.title.hasPrefix("Claude: 5-hour limit runs out at "), alert.title)
        XCTAssertEqual(alert.body, "60% used, 50 min before it resets.")
        XCTAssertFalse(alert.isUrgent)
        XCTAssertEqual(alert.windowKind, "session")

        var ledger = AlertLedger()
        ledger.process([claude([session(55, resetsIn: 2.5 * 3600 + 600)])], preferences: preferences, now: now)
        XCTAssertEqual(ledger.process([claude([session(60, resetsIn: 2.5 * 3600)])], preferences: preferences, now: now).map(\.kind), [.runsOut])
        XCTAssertTrue(ledger.process([claude([session(62, resetsIn: 2.5 * 3600 - 300)])], preferences: preferences, now: now.addingTimeInterval(300)).isEmpty, "The same window instance alerts once")
    }

    func testARunOutWithinTheHourIsUrgent() {
        // 88% used 3.5 hours in: out in under half an hour, an hour and a half before the reset.
        let raised = alerts(from: [session(87, resetsIn: 1.5 * 3600 + 300)], to: [session(88, resetsIn: 1.5 * 3600)])
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].isUrgent)
    }

    func testRunOutAlertsStayQuietWhenTheyAddNothing() {
        // Under half used.
        XCTAssertTrue(alerts(from: [session(35, resetsIn: 3.6 * 3600)], to: [session(40, resetsIn: 3.5 * 3600)]).isEmpty)
        // Switched off.
        var off = preferences
        off.sessionRunsOut = false
        XCTAssertTrue(alerts(from: [session(55, resetsIn: 2.5 * 3600 + 600)], to: [session(60, resetsIn: 2.5 * 3600)], off).isEmpty)
        // Crossing 80% in the same reading: the threshold alert says it.
        XCTAssertEqual(alerts(from: [session(78, resetsIn: 2 * 3600 + 600)], to: [session(81, resetsIn: 2 * 3600)]).map(\.kind), [.threshold])
        // Past 95%: the 95% alert has said it.
        XCTAssertTrue(alerts(from: [session(96, resetsIn: 3600 + 300)], to: [session(97, resetsIn: 3600)]).isEmpty)
        // A weekly limit running out only hours before its reset.
        XCTAssertTrue(alerts(from: [weekly(88, resetsIn: 12 * 3600 + 3600)], to: [weekly(89, resetsIn: 12 * 3600)]).isEmpty)
    }

    func testALongerLimitAlertsWhenItRunsOutADayOrMoreEarly() {
        // 78% used 94 hours into the week: out in about 26 hours, two days before the reset.
        let raised = alerts(from: [weekly(77, resetsIn: 74 * 3600 + 3600)], to: [weekly(78, resetsIn: 74 * 3600)])
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].title.hasPrefix("Claude: weekly limit runs out "), raised[0].title)
        XCTAssertFalse(raised[0].title.contains(" at "), "A run-out on another day names the day, not \"at\"")
        XCTAssertEqual(raised[0].body, "78% used, 2 days before it resets.")

        var off = preferences
        off.limitRunsOut = false
        XCTAssertTrue(alerts(from: [weekly(77, resetsIn: 74 * 3600 + 3600)], to: [weekly(78, resetsIn: 74 * 3600)], off).isEmpty)
    }

    func testAHeldRunOutGivesWayToTheNinetyFivePercentAlert() {
        let run = UsageAlert(id: "r", provider: "claude", kind: .runsOut, level: 0, title: "", body: "", resetsAt: now.addingTimeInterval(3 * 3600),
                             isUrgent: false, window: "session", instance: "i", windowKind: "session")
        var ledger = AlertLedger()
        ledger.pending = [AlertLedger.Pending(alert: run, raisedAt: now)]
        XCTAssertEqual(ledger.due(preferences: preferences, now: now).map(\.id), ["r"])
        ledger.levelsSent["claude/session/threshold"] = AlertLedger.LevelSent(level: 95, sentAt: now.addingTimeInterval(60))
        XCTAssertTrue(ledger.due(preferences: preferences, now: now.addingTimeInterval(120)).isEmpty)
    }
}
