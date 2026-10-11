import XCTest
@testable import Tokenroom

/// Compact surfaces lead with the window that needs attention. A measured run-out survives
/// the hour after which a reading is stale, and a key check is claimed once across callers.
final class CompactSurfaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testStaleReadingKeepsAMeasuredRunOutAndDoesNotInventOne() throws {
        let resets = now.addingTimeInterval(3 * 3600)
        let measured = RelayPace(runsOutAt: now.addingTimeInterval(25 * 60))
        let projected = try XCTUnwrap(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            measured: measured, isStale: true, now: now
        ))
        XCTAssertTrue(projected.isProjected)
        XCTAssertEqual(projected.runsOutAt, measured.runsOutAt)
        XCTAssertEqual(projected.verdict, .ahead)
        XCTAssertTrue(projected.caption(now: now, timeZone: TimeZone(identifier: "UTC")!).hasPrefix("Projected · runs out"))

        XCTAssertNil(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            samples: [(now.addingTimeInterval(-600), 40), (now, 70)],
            isStale: true, now: now
        ), "A frozen percentage does not grow a new rate")
        XCTAssertNil(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            measured: RelayPace(runsOutAt: resets.addingTimeInterval(60)),
            isStale: true, now: now
        ), "A run-out past the reset is not kept")
        let passed = try XCTUnwrap(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            measured: RelayPace(runsOutAt: now.addingTimeInterval(-60)),
            isStale: true, now: now
        ))
        XCTAssertEqual(passed.caption(now: now), "Projected to have run out")
    }

    func testLeadWindowIsTheSessionThatRunsOutBeforeACalmerWeek() {
        let week = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 88, resetsAt: now.addingTimeInterval(20 * 3600), periodSec: 7 * 86_400)
        let session = RelayWindow(
            id: "session", kind: "session", title: "Session", used: 55,
            resetsAt: now.addingTimeInterval(4 * 3600), periodSec: 5 * 3600,
            pace: RelayPace(runsOutAt: now.addingTimeInterval(20 * 60))
        )
        let provider = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: "weekly", windows: [week, session]
        )
        let lead = provider.leadWindow(now: now)
        XCTAssertEqual(lead?.id, "session")
        XCTAssertEqual(provider.primaryWindow?.used, 88, "The card headline stays the primary window")
        XCTAssertEqual(ReadingText.attention(provider, now: now, lead: lead), "Weekly 88%")
    }

    func testAnElapsedWeekGivesTheMenuBarToTheOpenSession() throws {
        let week = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 100, resetsAt: now.addingTimeInterval(-60), periodSec: 7 * 86_400)
        let session = RelayWindow(id: "session", kind: "session", title: "Session", used: 40, resetsAt: now.addingTimeInterval(2 * 3600), periodSec: 5 * 3600)
        let provider = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: "weekly", windows: [week, session]
        )
        XCTAssertEqual(provider.leadWindow(now: now)?.id, "session")
        XCTAssertEqual(ReadingText.attention(provider, now: now), "Reset · awaiting reading")
    }

    func testCloseListKeepsAStaleMeasuredRunOutAndAStaleHighPercentage() {
        let calm = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 30, resetsAt: now.addingTimeInterval(4 * 86_400), periodSec: 7 * 86_400)
        var burning = calm
        burning.pace = RelayPace(runsOutAt: now.addingTimeInterval(30 * 60))
        burning.used = 40
        let high = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 91, resetsAt: now.addingTimeInterval(2 * 86_400), periodSec: 7 * 86_400)
        func reading(_ id: String, _ window: RelayWindow) -> (provider: RelayProvider, history: [String: UsageHistory]) {
            (RelayProvider(
                id: id, name: id, shortName: id, monogram: "C", tint: "#D97757", state: "stale",
                checkedAt: now.addingTimeInterval(-2 * 3600), fetchedAt: now.addingTimeInterval(-2 * 3600),
                primaryWindowID: window.id, windows: [window]
            ), [:])
        }
        let close = UsageTiles.closeWindows([reading("burning", burning), reading("high", high), reading("calm", calm)], now: now)
        XCTAssertEqual(close.map(\.provider.id), ["burning", "high"])
        XCTAssertEqual(close.first?.pace?.isProjected, true)
    }

    func testStaleReadingRaisesTheMeasuredRunOutOnceAndNoThreshold() {
        var ledger = AlertLedger()
        var seen = provider(used: 40, state: "live", runsOutIn: nil)
        XCTAssertTrue(ledger.process([seen], preferences: AlertPreferences(), now: now).isEmpty, "First live reading below the run-out rule")

        var stale = provider(used: 96, state: "stale", runsOutIn: nil)
        XCTAssertTrue(ledger.process([stale], preferences: AlertPreferences(), now: now).isEmpty, "A stale percentage does not cross a threshold")
        XCTAssertEqual(ledger.lastSeen[seen.id]?.windows.first?.used, 40)

        stale = provider(used: 60, state: "stale", runsOutIn: 20 * 60)
        let raised = ledger.process([stale], preferences: AlertPreferences(), now: now)
        XCTAssertEqual(raised.map(\.kind), [.runsOut])
        XCTAssertTrue(raised[0].body.contains("at last check"))
        XCTAssertTrue(ledger.process([stale], preferences: AlertPreferences(), now: now.addingTimeInterval(60)).isEmpty)

        var unseen = AlertLedger()
        XCTAssertTrue(unseen.process([stale], preferences: AlertPreferences(), now: now).isEmpty, "A provider never seen live does not alert from a stale projection")
    }

    @MainActor
    func testMenuBarShowsTheUrgentWindowAndHighestFollowsIt() throws {
        let defaults = UserDefaults(suiteName: "tokenroom.tests.compact.\(UUID().uuidString)")!
        defaults.set(["claude", "cursor"], forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: folder))
        let moment = Date.now
        store.statuses[.claude] = .live(snapshot(.claude, windows: [
            QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 10, resetsAt: moment.addingTimeInterval(6 * 86_400), windowSeconds: 7 * 86_400),
            QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 55, resetsAt: moment.addingTimeInterval(4 * 3600), windowSeconds: 5 * 3600),
        ], fetchedAt: moment))
        store.statuses[.cursor] = .live(snapshot(.cursor, windows: [
            QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 88, resetsAt: moment.addingTimeInterval(20 * 3600), windowSeconds: 7 * 86_400),
        ], fetchedAt: moment))
        let claude = try XCTUnwrap(store.menuMeters.first { $0.provider == .claude })
        XCTAssertEqual(claude.valueText, "55")
        XCTAssertEqual(claude.windowLabel, "5-hour")
        XCTAssertEqual(store.statuses[.claude]?.snapshot?.usedPercent, 10, "The popover headline stays the primary window")
        XCTAssertTrue(claude.accessibilityText.contains("5-hour"))
        XCTAssertTrue(MenuBarLayout.tooltip(for: [claude]).contains("Weekly"))
        XCTAssertEqual(MenuBarLayout.displayed(store.menuMeters, style: .highest).map(\.provider), [.claude])
    }

    func testStaleSamplesKeepTheRunOutFromTheLastSample() throws {
        let resets = now.addingTimeInterval(4 * 3600)
        let samples = [
            (now.addingTimeInterval(-20 * 60), 40.0),
            (now.addingTimeInterval(-10 * 60), 55.0),
            (now, 70.0),
        ]
        let fresh = try XCTUnwrap(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600, samples: samples, now: now
        ))
        let stale = try XCTUnwrap(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            samples: samples, isStale: true, now: now.addingTimeInterval(2 * 3600)
        ))
        XCTAssertTrue(stale.isProjected)
        XCTAssertEqual(stale.runsOutAt, fresh.runsOutAt, "Aging the same samples must not move the run-out")
    }

    func testStaleReadingHonorsAMeasuredNoRunOut() {
        let resets = now.addingTimeInterval(4 * 3600)
        let lastCheck = now.addingTimeInterval(59 * 60)
        let fresh = Pace.evaluate(
            used: 30, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600, now: lastCheck
        )
        XCTAssertNil(fresh?.runsOutAt)
        XCTAssertNil(Pace.evaluate(
            used: 30, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            samples: [(now, 30)], measured: RelayPace(runsOutAt: nil),
            isStale: true, now: now.addingTimeInterval(2 * 3600)
        ), "The collector's no-run-out measurement takes precedence over hourly history")
    }

    func testStaleFallbackUsesTheLastSamplesOwnPercentage() throws {
        let resets = now.addingTimeInterval(3 * 3600)
        let samples = [
            (now.addingTimeInterval(-20 * 60), 10.0),
            (now.addingTimeInterval(-10 * 60), 25.0),
            (now, 40.0),
        ]
        let stale = try XCTUnwrap(Pace.evaluate(
            used: 70, kind: .session, resetsAt: resets, windowSeconds: 5 * 3600,
            samples: samples, isStale: true, now: now.addingTimeInterval(3600)
        ))
        XCTAssertEqual(stale.runsOutAt, now.addingTimeInterval(40 * 60), "The last sample's 40% leaves 60% at 1.5 points per minute")
        XCTAssertTrue(stale.isProjected)
    }

    func testSoonerRunOutLeadsAHigherPercentage() {
        let week = RelayWindow(
            id: "weekly", kind: "weekly", title: "Weekly", used: 90,
            resetsAt: now.addingTimeInterval(3 * 3600), periodSec: 7 * 86_400,
            pace: RelayPace(runsOutAt: now.addingTimeInterval(50 * 60))
        )
        let session = RelayWindow(
            id: "session", kind: "session", title: "Session", used: 55,
            resetsAt: now.addingTimeInterval(3 * 3600), periodSec: 5 * 3600,
            pace: RelayPace(runsOutAt: now.addingTimeInterval(10 * 60))
        )
        let provider = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: "weekly", windows: [week, session]
        )
        XCTAssertEqual(provider.leadWindow(now: now)?.id, "session")
    }

    func testSoonerRunOutLeadsAcrossDifferentSeverityBands() {
        let week = RelayWindow(
            id: "weekly", kind: "weekly", title: "Weekly", used: 60,
            resetsAt: now.addingTimeInterval(4 * 86_400), periodSec: 7 * 86_400,
            pace: RelayPace(runsOutAt: now.addingTimeInterval(2 * 86_400))
        )
        let session = RelayWindow(
            id: "session", kind: "session", title: "Session", used: 55,
            resetsAt: now.addingTimeInterval(2 * 3600), periodSec: 5 * 3600,
            pace: RelayPace(runsOutAt: now.addingTimeInterval(90 * 60))
        )
        let provider = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: "weekly", windows: [week, session]
        )
        XCTAssertEqual(UsageRanking.pace(for: week, isStale: false, history: nil, now: now)?.severity, .tight)
        XCTAssertEqual(UsageRanking.pace(for: session, isStale: false, history: nil, now: now)?.severity, .watch)
        XCTAssertEqual(provider.leadWindow(now: now)?.id, "session", "The soonest run-out leads, even in a lower severity band")
    }

    @MainActor
    func testMenuKeepsAMeasuredSessionAfterTheReadingGoesStale() throws {
        let defaults = UserDefaults(suiteName: "tokenroom.tests.compact.stale.\(UUID().uuidString)")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: folder))
        let checked = Date.now.addingTimeInterval(-2 * 3600)
        store.settings.setEnabled(.claude, true)
        let points: [(TimeInterval, Double)] = [(-20 * 60, 40), (-10 * 60, 55), (0, 70)]
        for (offset, used) in points {
            store.history.record(snapshot(.claude, windows: [
                QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 12, resetsAt: checked.addingTimeInterval(5 * 86_400), windowSeconds: 7 * 86_400),
                QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: used, resetsAt: checked.addingTimeInterval(3 * 3600), windowSeconds: 5 * 3600),
            ], fetchedAt: checked.addingTimeInterval(offset)), now: checked)
        }
        store.statuses[.claude] = .live(snapshot(.claude, windows: [
            QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 12, resetsAt: checked.addingTimeInterval(5 * 86_400), windowSeconds: 7 * 86_400),
            QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 70, resetsAt: checked.addingTimeInterval(3 * 3600), windowSeconds: 5 * 3600),
        ], fetchedAt: checked))
        store.checkedAt[.claude] = checked
        let shownAt = checked.addingTimeInterval(2 * 3600)
        store.ageReadings(at: shownAt)
        let meter = try XCTUnwrap(store.menuMeters.first { $0.provider == .claude })
        XCTAssertEqual(meter.valueText, "70")
        XCTAssertTrue(meter.isStale)
        let session = try XCTUnwrap(store.relayEnvelope(at: shownAt).providers.first { $0.id == "claude" }?.windows.first { $0.id == "session" })
        XCTAssertNotNil(session.pace?.runsOutAt)
        let again = try XCTUnwrap(store.relayEnvelope(at: shownAt.addingTimeInterval(30 * 60)).providers.first { $0.id == "claude" }?.windows.first { $0.id == "session" })
        XCTAssertEqual(again.pace?.runsOutAt, session.pace?.runsOutAt)
    }

    func testAKeyCheckIsClaimedOnceAndACancelledCallDoesNotEraseANewerOne() throws {
        let name = "tokenroom.tests.compact.gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let other = KeyFetchGate(defaults: defaults)
        let first = try XCTUnwrap(gate.claim(.anthropicOrg, at: now))
        XCTAssertNil(other.claim(.anthropicOrg, at: now.addingTimeInterval(1)), "The second caller sees the attempt")
        first.finish()
        let newer = now.addingTimeInterval(20 * 60)
        let latest = try XCTUnwrap(gate.claim(.anthropicOrg, at: newer))
        defer { latest.finish() }
        gate.restoreAttempt(first)
        XCTAssertEqual(gate.lastAttempt(.anthropicOrg), newer, "A newer claim survives the older call being cancelled")
        gate.restoreAttempt(latest)
        XCTAssertEqual(gate.lastAttempt(.anthropicOrg), now, "The latest claim restores the attempt it captured")
        latest.finish()
        let next = try XCTUnwrap(other.claim(.anthropicOrg, at: newer.addingTimeInterval(1)))
        next.finish()
    }

    private func provider(used: Double, state: String, runsOutIn: TimeInterval?) -> RelayProvider {
        var window = RelayWindow(
            id: "session", kind: "session", title: "Session", used: used,
            resetsAt: now.addingTimeInterval(4 * 3600), periodSec: 5 * 3600
        )
        if let runsOutIn {
            window.pace = RelayPace(runsOutAt: now.addingTimeInterval(runsOutIn))
        }
        return RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: state, checkedAt: now, fetchedAt: now, primaryWindowID: window.id, windows: [window]
        )
    }

    private func snapshot(_ provider: Provider, windows: [QuotaWindow], fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            usedPercent: windows[0].usedPercent,
            resetsAt: windows[0].resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: windows[0].title,
            windows: windows
        )
    }
}
