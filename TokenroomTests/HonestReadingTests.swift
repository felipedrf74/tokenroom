import XCTest
@testable import Tokenroom

final class HonestReadingTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private let week: TimeInterval = 7 * 86_400

    private func provider(id: String = "openai", state: String = "live", checkedAt: Date? = nil, _ windows: [RelayWindow]) -> RelayProvider {
        RelayProvider(
            id: id, name: id, shortName: id, monogram: "O", tint: "#000000", state: state,
            checkedAt: checkedAt ?? now, fetchedAt: checkedAt ?? now, primaryWindowID: windows.first?.id, windows: windows
        )
    }

    private func weekly(_ used: Double, resetsIn: TimeInterval, runsOutIn: TimeInterval? = nil) -> RelayWindow {
        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: week,
                    pace: runsOutIn.map { RelayPace(runsOutAt: now.addingTimeInterval($0)) })
    }

    private func session(_ used: Double, resetsIn: TimeInterval) -> RelayWindow {
        RelayWindow(id: "session", kind: "session", title: "Session", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 5 * 3600)
    }

    @MainActor
    private func makeStore(_ statuses: [Provider: ProviderStatus], checkedAt: Date) -> QuotaStore {
        let suite = "tokenroom.tests.honest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(statuses.keys.map(\.rawValue), forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = QuotaStore(settings: AppSettings(defaults: defaults), clients: [], cache: SnapshotCache(directory: folder))
        for (provider, status) in statuses {
            store.statuses[provider] = status
            store.checkedAt[provider] = checkedAt
        }
        return store
    }

    func testAnElapsedWindowDrawsAnEmptyMeterWithoutPace() {
        let elapsed = weekly(78, resetsIn: -60)
        XCTAssertEqual(elapsed.meterUsed(at: now), 0, "The previous period's fill is gone")
        XCTAssertEqual(elapsed.used, 78, "The last measurement is kept")
        XCTAssertEqual(weekly(78, resetsIn: 3600).meterUsed(at: now), 78, "A window whose reset is still ahead keeps its value, stale or not")
        XCTAssertNil(MeterLayout.shownPace(0.5, isStale: false, isAwaitingReading: true))
        XCTAssertNil(MeterLayout.shownPace(0.5, isStale: true, isAwaitingReading: false))
        XCTAssertEqual(MeterLayout.shownPace(1.4, isStale: false, isAwaitingReading: false), 1)
    }

    func testAnElapsedMeterSaysItIsAwaitingAReading() {
        XCTAssertEqual(ReadingText.meterAccessibility(used: 78, paceMark: 0.5, isStale: false, isAwaitingReading: true), "Reset, awaiting reading")
        XCTAssertEqual(ReadingText.meterAccessibility(used: 78, paceMark: 0.5, isStale: false, isAwaitingReading: false),
                       "78 percent used, 50 percent of the window has passed")
        XCTAssertEqual(ReadingText.meterAccessibility(used: 78, paceMark: 0.5, isStale: true, isAwaitingReading: false), "78 percent used")
    }

    @MainActor
    func testTheMacPopoverDoesNotSpeakAnElapsedPercentage() throws {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 78, resetsAt: now.addingTimeInterval(-60))
        let snapshot = try QuotaSnapshot.headlined(by: [window], provider: .openai, fetchedAt: now)
        let card = ProviderCard(provider: .openai, status: .live(snapshot), date: now)
        let spoken = PopoverProviderView(card: card, style: .orbit).summaryAccessibility(RelayWindow(window))
        XCTAssertFalse(spoken.contains("78"), spoken)
        XCTAssertFalse(spoken.contains("used"), spoken)
        XCTAssertTrue(spoken.contains("awaiting reading"), spoken)
    }

    @MainActor
    func testTheMenuBarMeterEmptiesAfterAReset() throws {
        let moment = Date.now
        var reading = try QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 78,
            resetsAt: moment.addingTimeInterval(-60), windowSeconds: week)], provider: .openai, fetchedAt: moment)
        reading.resetsAt = moment.addingTimeInterval(-60)
        let store = makeStore([.openai: .live(reading)], checkedAt: moment)
        store.ageReadings(at: moment)
        let meter = try XCTUnwrap(store.menuMeters.first)
        XCTAssertEqual(meter.drawnUsedPercent, 0)
        XCTAssertEqual(meter.usedPercent, 78)
        XCTAssertFalse(meter.accessibilityText.contains("78"), meter.accessibilityText)
    }

    func testResetsSoonShowsTheConfiguredWindowOrNothing() {
        let reading = provider([weekly(64, resetsIn: 2 * 86_400), session(40, resetsIn: 3600)])
        XCTAssertEqual(reading.window(configured: "session")?.id, "session")
        XCTAssertNil(reading.window(configured: "gone"), "A window that disappeared is never replaced by the weekly")
        XCTAssertEqual(reading.window(configured: nil)?.id, "weekly", "With nothing configured, the primary window")
        let checked = now.addingTimeInterval(-2 * 3600)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ReadingText.asOf(checked, now: now, timeZone: utc), "As of \(Pace.shortMoment(checked, now: now, timeZone: utc))")
    }

    func testALockScreenBalanceRowHasNoPercentageMeter() {
        let balance = RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 0, resetsAt: nil,
                                  amount: QuotaAmount(remaining: 12.4, unit: "usd"), metered: false)
        let lead = provider(id: "deepseek", [balance]).leadWindow(now: now)
        XCTAssertEqual(lead?.isMetered, false, "The rectangular row branches on this and shows the amount alone")
        XCTAssertEqual(ReadingText.headline(lead, now: now), "\(AmountFormat.text(12.4, unit: "usd")) left")
    }

    func testTheWatchRowNamesTheWindowItCountsDownFor() {
        XCTAssertEqual(ReadingText.windowCountdown(weekly(78, resetsIn: 3 * 86_400 + 3600), now: now), "Weekly · 3d 1h")
        XCTAssertEqual(ReadingText.windowCountdown(session(55, resetsIn: 2 * 3600 + 9 * 60), now: now), "5-hour · 2h 9m")
        XCTAssertEqual(ReadingText.windowCountdown(weekly(78, resetsIn: -60), now: now), "Reset · awaiting reading")
        let cycle = RelayWindow(id: "cycle", kind: "billingCycle", title: "This cycle", used: 40, resetsAt: now.addingTimeInterval(10 * 86_400))
        let day = now.addingTimeInterval(10 * 86_400).formatted(.dateTime.month(.abbreviated).day())
        XCTAssertEqual(ReadingText.windowCountdown(cycle, now: now), "This cycle · \(day)")
        let premium = RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 83, resetsAt: now.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(ReadingText.windowCountdown(premium, now: now), "Premium requests · \(day)")
        let open = RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 40, resetsAt: nil)
        XCTAssertEqual(ReadingText.windowCountdown(open, now: now), "Premium requests")
    }

    func testAStaleCloseRowLeadsWithItsAge() {
        let stale = provider(state: "stale", checkedAt: now.addingTimeInterval(-2 * 3600), [weekly(83, resetsIn: 2 * 86_400)])
        let close = UsageTiles.closeWindows([(stale, [:])], now: now)
        XCTAssertEqual(close.map(\.window.id), ["weekly"])
        XCTAssertFalse(close[0].provider.isLive)
        XCTAssertEqual(ReadingText.lastChecked(close[0].provider.checkedAt, now: now), "Last checked 2h ago")
    }

    func testABurstThatRunsOutBeforeTheResetLeadsOverAnEvenPace() throws {
        let window = weekly(45, resetsIn: 0.3 * week, runsOutIn: 1800)
        let pace = try XCTUnwrap(UsageRanking.pace(for: window, isStale: false, history: nil, now: now))
        XCTAssertEqual(pace.verdict, .plentyLeft, "Cumulatively it's well under an even pace")
        XCTAssertEqual(pace.runsOutAt, now.addingTimeInterval(1800))
        XCTAssertTrue(pace.needsAttention)
        XCTAssertEqual(pace.currentRunOut, pace.runsOutAt)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(pace.caption(now: now, timeZone: utc), "Runs out \(Pace.shortMoment(now.addingTimeInterval(1800), now: now, timeZone: utc)) · below pace so far")
        XCTAssertTrue(UsageTiles.isClose(window, pace: pace), "Below 80%, a run-out before the reset is still close to a limit")
        XCTAssertEqual(UsageTiles.closeWindows([(provider([window]), [:])], now: now).map(\.window.id), ["weekly"])
        let fact = UsageFacts.paceFact(pace, now: now, timeZone: utc)
        XCTAssertEqual(fact.value, "Runs out \(Pace.shortMoment(now.addingTimeInterval(1800), now: now, timeZone: utc))")
        XCTAssertEqual(fact.detail, "Even pace 70%")
        XCTAssertEqual(fact.severity, .critical)

        let calm = try XCTUnwrap(UsageRanking.pace(for: weekly(45, resetsIn: 0.3 * week, runsOutIn: nil), isStale: false, history: nil, now: now))
        XCTAssertFalse(calm.needsAttention)
        XCTAssertEqual(calm.caption(now: now), "Plenty left")
        XCTAssertFalse(UsageTiles.isClose(weekly(45, resetsIn: 0.3 * week), pace: calm))
    }

    func testARunOutOnlyInTheLastQuarterIsShownButNotRaised() throws {
        let window = weekly(45, resetsIn: 0.3 * week, runsOutIn: 0.2 * week)
        let pace = try XCTUnwrap(UsageRanking.pace(for: window, isStale: false, history: nil, now: now))
        XCTAssertEqual(pace.verdict, .plentyLeft)
        XCTAssertEqual(pace.severity, .watch)
        XCTAssertEqual(pace.currentRunOut, now.addingTimeInterval(0.2 * week))
        XCTAssertFalse(pace.runOutNeedsAttention)
        XCTAssertFalse(pace.needsAttention)
        XCTAssertFalse(UsageTiles.isClose(window, pace: pace))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertTrue(pace.caption(now: now, timeZone: utc).hasPrefix("Runs out "))
    }

    func testTheWatchNamesAMildRunOutBesideItsReset() throws {
        let utc = TimeZone(identifier: "UTC")!
        let mild = try XCTUnwrap(UsageRanking.pace(for: weekly(45, resetsIn: 0.3 * week, runsOutIn: 0.2 * week), isStale: false, history: nil, now: now))
        XCTAssertFalse(mild.needsAttention)
        XCTAssertEqual(ReadingText.watchPaceNote(mild, now: now, timeZone: utc),
                       "Runs out \(Pace.shortMoment(now.addingTimeInterval(0.2 * week), now: now, timeZone: utc))")
        let burst = try XCTUnwrap(UsageRanking.pace(for: weekly(45, resetsIn: 0.3 * week, runsOutIn: 1800), isStale: false, history: nil, now: now))
        XCTAssertEqual(ReadingText.watchPaceNote(burst, now: now, timeZone: utc), burst.caption(now: now, timeZone: utc))
        let calm = try XCTUnwrap(UsageRanking.pace(for: weekly(45, resetsIn: 0.3 * week, runsOutIn: nil), isStale: false, history: nil, now: now))
        XCTAssertNil(ReadingText.watchPaceNote(calm, now: now, timeZone: utc))
        XCTAssertNil(ReadingText.watchPaceNote(nil, now: now))
    }

    func testLimitReachedAndProjectedRunOutsKeepTheirWords() {
        let limit = Pace(verdict: .limitReached, delta: 30, elapsedFraction: 0.7, resetsAt: now.addingTimeInterval(3600), runsOutAt: nil, severity: .critical)
        XCTAssertNil(limit.currentRunOut)
        XCTAssertTrue(limit.caption(now: now).hasPrefix("Limit reached · "))
        let projected = Pace(verdict: .ahead, delta: 0, elapsedFraction: 0.7, resetsAt: now.addingTimeInterval(3600),
                             runsOutAt: now.addingTimeInterval(600), severity: .critical, isProjected: true)
        XCTAssertNil(projected.currentRunOut)
        XCTAssertTrue(projected.caption(now: now).hasPrefix("Projected · runs out "))
    }

    @MainActor
    func testTheMacSummarySaysWhenItMayRunOut() throws {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 45, resetsAt: now.addingTimeInterval(86_400))
        let snapshot = try QuotaSnapshot.headlined(by: [window], provider: .openai, fetchedAt: now)
        let runsOut = now.addingTimeInterval(1800)
        for verdict in [Pace.Verdict.plentyLeft, .ahead] {
            let pace = Pace(verdict: verdict, delta: -25, elapsedFraction: 0.7, resetsAt: window.resetsAt!, runsOutAt: runsOut, severity: .critical)
            let card = ProviderCard(provider: .openai, status: .live(snapshot), pace: pace, date: now)
            let spoken = PopoverProviderView(card: card, style: .orbit).summaryAccessibility(RelayWindow(window))
            XCTAssertTrue(spoken.contains("May run out at \(Pace.shortMoment(runsOut, now: now, timeZone: .current))"), spoken)
            XCTAssertFalse(spoken.contains("Ahead of pace"), spoken)
        }
    }

    func testTheEvenDailyPaceIsNamedForWhatItIs() {
        let opus = RelayWindow(id: "opus", kind: "weekly", title: "Opus weekly", used: 40, resetsAt: now.addingTimeInterval(3 * 86_400))
        let opusFacts = PopoverInsights.facts(window: opus, isStale: false, now: now)
        XCTAssertEqual(opusFacts.last?.label, "Even daily pace")
        XCTAssertEqual(opusFacts.last?.detail, "of the Opus weekly quota per day until reset")
        let cycle = RelayWindow(id: "cycle", kind: "billingCycle", title: "This cycle", used: 40, resetsAt: now.addingTimeInterval(10 * 86_400))
        XCTAssertEqual(PopoverInsights.facts(window: cycle, isStale: false, now: now).last?.detail, "of this quota per day until reset")
    }

    func testClassicKeepsOneActionableWarningCollapsed() {
        let resets = now.addingTimeInterval(86_400)
        let onPace = Pace(verdict: .onPace, delta: 0, elapsedFraction: 0.5, resetsAt: resets, runsOutAt: nil, severity: .none)
        let plenty = Pace(verdict: .plentyLeft, delta: -20, elapsedFraction: 0.5, resetsAt: resets, runsOutAt: nil, severity: .none)
        let burst = Pace(verdict: .plentyLeft, delta: -20, elapsedFraction: 0.5, resetsAt: resets, runsOutAt: now.addingTimeInterval(1800), severity: .critical)
        XCTAssertFalse(ProviderCard.classicShowsPace(onPace, limitWarning: nil), "Routine pace moves to the expansion")
        XCTAssertFalse(ProviderCard.classicShowsPace(plenty, limitWarning: nil))
        XCTAssertTrue(ProviderCard.classicShowsPace(burst, limitWarning: nil))
        XCTAssertFalse(ProviderCard.classicShowsPace(burst, limitWarning: "5-hour limit reached"), "One warning: the reached limit")
    }

    @MainActor
    func testTheMenuBarSaysHowOldACachedReadingIs() throws {
        let moment = Date.now
        let reading = try QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 78,
            resetsAt: moment.addingTimeInterval(3 * 86_400), windowSeconds: week)], provider: .openai, fetchedAt: moment.addingTimeInterval(-2 * 3600))
        let store = makeStore([.openai: .expired("Session expired.", cached: reading)], checkedAt: moment.addingTimeInterval(-2 * 3600))
        store.ageReadings(at: moment)
        let meter = try XCTUnwrap(store.menuMeters.first)
        XCTAssertEqual(meter.accessibilityText, "OpenAI 78% used, last reading 2h ago")
        XCTAssertEqual(MenuBarLayout.tooltip(for: [meter]), meter.accessibilityText, "One description for hover and VoiceOver")

        store.statuses[.openai] = .live(reading)
        store.checkedAt[.openai] = moment
        let live = try XCTUnwrap(store.menuMeters.first)
        XCTAssertEqual(live.accessibilityText, "OpenAI 78% used")
    }

    func testMostUrgentOnlyKeepsItsSavedValue() {
        XCTAssertEqual(MenuBarStyle.highest.title, "Most urgent only")
        XCTAssertEqual(MenuBarStyle.highest.rawValue, "highest")
    }

    func testTheIPhoneDetailSaysAStaleFigureIsFromTheLastCheck() {
        XCTAssertEqual(ReadingText.remainingLabel(isLive: true), "left")
        XCTAssertEqual(ReadingText.remainingLabel(isLive: false), "left at last check")
        XCTAssertEqual(ReadingText.historyTitle(weekly(40, resetsIn: 86_400), isLead: true), "Weekly usage · last 7 days")
        XCTAssertEqual(ReadingText.historyTitle(session(40, resetsIn: 3600), isLead: false), "Last 7 days")
    }
}
