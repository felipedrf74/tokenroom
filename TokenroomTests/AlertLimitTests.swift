import XCTest
@testable import Tokenroom

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

    func testASessionOnCourseToRunOutBeforeItsResetAlertsOnce() {
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

    func testRecentReadingsDecideTheRunOutWhenTheReadingHasNoMeasuredPace() {
        let idle = [25.0, 15, 5, 0].map { (date: now.addingTimeInterval(-$0 * 60), used: 60.0) }
        let before = claude([session(55, resetsIn: 2.5 * 3600 + 600)])
        let after = claude([session(60, resetsIn: 2.5 * 3600)])
        XCTAssertTrue(AlertRules.alerts(previous: before, current: after, preferences: preferences, samples: ["session": idle], now: now).isEmpty)

        var ledger = AlertLedger()
        ledger.process([before], preferences: preferences, now: now)
        XCTAssertTrue(ledger.process([after], preferences: preferences, samples: ["claude": ["session": idle]], now: now).isEmpty, "The iPhone passes its own readings")

        let busy = [(25.0, 40.0), (15, 47), (5, 55), (0, 60)].map { (date: now.addingTimeInterval(-$0.0 * 60), used: $0.1) }
        let raised = AlertRules.alerts(previous: before, current: after, preferences: preferences, samples: ["session": busy], now: now)
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].isUrgent)
    }

    func testARunOutWithinTheHourIsUrgent() {
        let raised = alerts(from: [session(87, resetsIn: 1.5 * 3600 + 300)], to: [session(88, resetsIn: 1.5 * 3600)])
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].isUrgent)
    }

    func testRunOutAlertsStayQuietWhenTheyAddNothing() {
        XCTAssertTrue(alerts(from: [session(35, resetsIn: 3.6 * 3600)], to: [session(40, resetsIn: 3.5 * 3600)]).isEmpty)
        var off = preferences
        off.sessionRunsOut = false
        XCTAssertTrue(alerts(from: [session(55, resetsIn: 2.5 * 3600 + 600)], to: [session(60, resetsIn: 2.5 * 3600)], off).isEmpty)
        XCTAssertEqual(alerts(from: [session(78, resetsIn: 2 * 3600 + 600)], to: [session(81, resetsIn: 2 * 3600)]).map(\.kind), [.threshold])
        XCTAssertTrue(alerts(from: [session(96, resetsIn: 3600 + 300)], to: [session(97, resetsIn: 3600)]).isEmpty)
        XCTAssertTrue(alerts(from: [weekly(88, resetsIn: 12 * 3600 + 3600)], to: [weekly(89, resetsIn: 12 * 3600)]).isEmpty)
    }

    func testALongerLimitAlertsWhenItRunsOutADayOrMoreEarly() {
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

    func testARunOutGoesOutOnceWhileItsResetJittersOrMoves() throws {
        var ledger = AlertLedger()
        ledger.process([claude([session(55, resetsIn: 2.5 * 3600 + 600)])], preferences: preferences, now: now)
        let first = ledger.process([claude([session(60, resetsIn: 2.5 * 3600)])], preferences: preferences, now: now)
        XCTAssertEqual(first.map(\.kind), [.runsOut])
        ledger.markSent(first.map(\.id), at: now)
        let jittered = claude([session(62, resetsIn: 2.5 * 3600 + 20 * 60)])
        let renamed = try XCTUnwrap(AlertRules.runsOut(jittered, window: jittered.windows[0], preferences: preferences, now: now.addingTimeInterval(300)))
        XCTAssertNotEqual(renamed.id, first.first?.id, "Rounded to another name")
        XCTAssertTrue(ledger.process([jittered], preferences: preferences, now: now.addingTimeInterval(300)).isEmpty)

        var weeks = AlertLedger()
        weeks.process([claude([weekly(77, resetsIn: 74 * 3600 + 3600)])], preferences: preferences, now: now)
        let week = weeks.process([claude([weekly(78, resetsIn: 74 * 3600)])], preferences: preferences, now: now)
        XCTAssertEqual(week.map(\.kind), [.runsOut])
        weeks.markSent(week.map(\.id), at: now)
        let moved = claude([weekly(79, resetsIn: 77 * 3600)])
        let movedName = try XCTUnwrap(AlertRules.runsOut(moved, window: moved.windows[0], preferences: preferences, now: now.addingTimeInterval(600)))
        XCTAssertNotEqual(movedName.id, week.first?.id)
        XCTAssertTrue(weeks.process([moved], preferences: preferences, now: now.addingTimeInterval(600)).isEmpty)
    }

    func testAHeldRunOutGivesWayToANinetyFivePercentAlertGoingOutWithIt() {
        var ledger = AlertLedger()
        ledger.process([claude([session(55, resetsIn: 2.5 * 3600 + 600)])], preferences: preferences, now: now)
        XCTAssertEqual(ledger.process([claude([session(60, resetsIn: 2.5 * 3600)])], preferences: preferences, now: now).map(\.kind), [.runsOut])
        let later = now.addingTimeInterval(600)
        let ninetyFive = ledger.process([claude([session(96, resetsIn: 2.5 * 3600)])], preferences: preferences, now: later)
        XCTAssertEqual(ninetyFive.map(\.level), [95])
        XCTAssertEqual(ledger.due(preferences: preferences, now: later).map(\.id), ninetyFive.map(\.id), "One notification: the 95% alert says it")
    }

    private func week(_ used: Double, runsOut: Date?, reset: Date) -> RelayProvider {
        claude([RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: reset,
                            periodSec: 7 * 86_400, pace: RelayPace(runsOutAt: runsOut))])
    }

    func testAHeldRunOutFollowsNewerReadingsAndGoesOutCurrent() throws {
        var quiet = preferences
        quiet.quietHours = true
        quiet.thresholds = [80]
        let late = now.addingTimeInterval(11 * 3600)
        let reset = late.addingTimeInterval(3 * 86_400)
        let overnight = late.addingTimeInterval(3.5 * 3600)
        let morning = late.addingTimeInterval(9 * 3600 + 300)
        func raise(_ ledger: inout AlertLedger) throws -> UsageAlert {
            ledger.process([week(68, runsOut: late.addingTimeInterval(3 * 3600), reset: reset)], preferences: quiet, now: late)
            let raised = try XCTUnwrap(ledger.process([week(70, runsOut: late.addingTimeInterval(3 * 3600), reset: reset)], preferences: quiet, now: late).first)
            XCTAssertEqual(raised.kind, .runsOut)
            XCTAssertFalse(raised.isUrgent)
            return raised
        }

        var ledger = AlertLedger()
        let raised = try raise(&ledger)
        let later = week(75, runsOut: late.addingTimeInterval(11 * 3600), reset: reset)
        XCTAssertTrue(ledger.process([later], preferences: quiet, now: overnight).isEmpty)
        let current = try XCTUnwrap(AlertRules.runsOut(later, window: later.windows[0], preferences: quiet, now: overnight))
        XCTAssertNotEqual(current.title, raised.title)
        let due = ledger.due(preferences: quiet, now: morning)
        XCTAssertEqual(due.map(\.id), [raised.id], "Still the one alert for the window")
        XCTAssertEqual(due.map(\.title), [current.title], "Saying when it runs out as of the last reading")
        XCTAssertTrue(due.first?.body.hasPrefix("75% used") == true, due.first?.body ?? "")

        var asleep = AlertLedger()
        let held = try raise(&asleep)
        asleep.process([], preferences: quiet, now: late.addingTimeInterval(2 * 3600))
        XCTAssertEqual(asleep.pending.map(\.alert.id), [held.id], "Still ahead of its run-out")
        asleep.process([], preferences: quiet, now: overnight)
        XCTAssertEqual(asleep.pending.map(\.alert.id), [held.id], "Within the hour after it")
        XCTAssertTrue(asleep.due(preferences: quiet, now: morning).isEmpty, "Its run-out came and went overnight")
        asleep.process([], preferences: quiet, now: morning)
        XCTAssertTrue(asleep.pending.isEmpty)

        var eased = AlertLedger()
        _ = try raise(&eased)
        eased.process([week(72, runsOut: nil, reset: reset)], preferences: quiet, now: overnight)
        XCTAssertTrue(eased.pending.isEmpty)
        XCTAssertTrue(eased.due(preferences: quiet, now: morning).isEmpty)
        let again = eased.process([week(78, runsOut: late.addingTimeInterval(14 * 3600), reset: reset)], preferences: quiet, now: late.addingTimeInterval(10 * 3600))
        XCTAssertEqual(again.map(\.kind), [.runsOut])

        var full = AlertLedger()
        _ = try raise(&full)
        full.process([week(100, runsOut: nil, reset: reset)], preferences: quiet, now: late.addingTimeInterval(3600))
        XCTAssertFalse(full.pending.contains { $0.alert.kind == .runsOut })
        XCTAssertFalse(full.due(preferences: quiet, now: morning).contains { $0.kind == .runsOut })
    }

    func testAnUrgentRunOutICloudDidNotTakeIsRetried() throws {
        var choices = preferences
        choices.thresholds = [95]
        let reset = now.addingTimeInterval(3 * 86_400)
        var ledger = AlertLedger()
        ledger.process([week(68, runsOut: now.addingTimeInterval(600), reset: reset)], preferences: choices, now: now)
        let raised = try XCTUnwrap(ledger.process([week(70, runsOut: now.addingTimeInterval(600), reset: reset)], preferences: choices, now: now).first)
        XCTAssertTrue(raised.isUrgent, "Out in ten minutes")
        XCTAssertEqual(ledger.due(preferences: choices, now: now.addingTimeInterval(1200)).map(\.id), [raised.id])
        ledger.process([week(93, runsOut: now.addingTimeInterval(600), reset: reset)], preferences: choices, now: now.addingTimeInterval(1500))
        let retried = ledger.due(preferences: choices, now: now.addingTimeInterval(1500))
        XCTAssertEqual(retried.map(\.id), [raised.id])
        XCTAssertEqual(retried.first?.isUrgent, true)
        XCTAssertTrue(retried.first?.body.hasPrefix("93% used") == true, retried.first?.body ?? "")
    }

    func testARunOutDroppedUnsentAtItsDeadlineLetsTheWindowWarnAgain() throws {
        var quiet = preferences
        quiet.quietHours = true
        quiet.thresholds = [80]
        let evening = now.addingTimeInterval(10.5 * 3600)
        let reset = evening.addingTimeInterval(3 * 86_400)
        let runsOut = evening.addingTimeInterval(3 * 3600)
        let wake = evening.addingTimeInterval(9 * 3600)
        let onCourse = week(78, runsOut: evening.addingTimeInterval(16.5 * 3600), reset: reset)

        var ledger = AlertLedger()
        ledger.process([week(68, runsOut: runsOut, reset: reset)], preferences: quiet, now: evening)
        let raised = try XCTUnwrap(ledger.process([week(70, runsOut: runsOut, reset: reset)], preferences: quiet, now: evening).first)
        XCTAssertEqual(raised.kind, .runsOut)
        XCTAssertFalse(raised.isUrgent)
        var stale = week(70, runsOut: runsOut, reset: reset)
        stale.state = "stale"
        XCTAssertTrue(ledger.process([stale], preferences: quiet, now: wake).isEmpty)
        XCTAssertTrue(ledger.pending.isEmpty)
        let again = ledger.process([onCourse], preferences: quiet, now: wake.addingTimeInterval(300))
        XCTAssertEqual(again.map(\.kind), [.runsOut], "A run-out that never went out doesn't hold the week")
        let due = ledger.due(preferences: quiet, now: wake.addingTimeInterval(35 * 60))
        XCTAssertEqual(due.map(\.id), again.map(\.id))
        XCTAssertTrue(due.first?.body.hasPrefix("78% used") == true, due.first?.body ?? "")

        var shown = AlertLedger()
        shown.process([week(68, runsOut: runsOut, reset: reset)], preferences: preferences, now: evening)
        let first = shown.process([week(70, runsOut: runsOut, reset: reset)], preferences: preferences, now: evening)
        let going = shown.due(preferences: preferences, now: evening)
        XCTAssertEqual(shown.settle(going, delivery: AlertLedger.Delivery(), showsHere: true, now: evening).map(\.id), first.map(\.id))
        XCTAssertEqual(shown.pending.map(\.alert.id), first.map(\.id), "Still to go to iCloud")
        shown.process([], preferences: preferences, now: wake)
        XCTAssertTrue(shown.pending.isEmpty)
        XCTAssertTrue(shown.process([onCourse], preferences: preferences, now: wake.addingTimeInterval(300)).isEmpty)
    }

    func testAWindowMissingFromSomeReadingsStillAlertsWhenItComesBack() {
        func opus(_ used: Double) -> RelayWindow {
            RelayWindow(id: "seven_day_opus", kind: "weekly", title: "Opus weekly", used: used, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400)
        }
        var ledger = AlertLedger()
        ledger.process([claude([session(20, resetsIn: 4 * 3600), opus(70)])], preferences: preferences, now: now)
        XCTAssertTrue(ledger.process([claude([session(22, resetsIn: 4 * 3600)])], preferences: preferences, now: now.addingTimeInterval(1800)).isEmpty)
        XCTAssertEqual(ledger.lastSeen["claude"]?.windows.map(\.id), ["session", "seven_day_opus"], "Kept while it's missing")

        let back = ledger.process([claude([session(24, resetsIn: 4 * 3600), opus(96)])], preferences: preferences, now: now.addingTimeInterval(3600))
        XCTAssertEqual(back.map(\.window), ["seven_day_opus"])
        XCTAssertEqual(back.map(\.level), [95], "Crossed while it was missing: not a first sight")

        ledger.process([claude([session(5, resetsIn: 3 * 86_400 + 4 * 3600)])], preferences: preferences, now: now.addingTimeInterval(3 * 86_400 + 60))
        XCTAssertEqual(ledger.lastSeen["claude"]?.windows.map(\.id), ["session"])
    }
}
