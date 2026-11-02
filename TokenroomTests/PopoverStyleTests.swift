import XCTest
@testable import Tokenroom

final class PopoverStyleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testOrbitIsDefaultAndEverySelectionSurvivesRelaunch() {
        let suite = "TokenroomTests.PopoverStyle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("highest", forKey: AppSettings.Keys.menuStyle)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.popoverStyle, .orbit)
        for style in PopoverStyle.allCases {
            settings.popoverStyle = style
            let reloaded = AppSettings(defaults: defaults)
            XCTAssertEqual(reloaded.popoverStyle, style)
            XCTAssertEqual(reloaded.menuStyle, .highest, "Popover choice must not change the status item")
        }
        defaults.set("future-style", forKey: AppSettings.Keys.popoverStyle)
        XCTAssertEqual(AppSettings(defaults: defaults).popoverStyle, .orbit)
    }

    func testAllowanceUsesRemainingQuotaAndTimeUntilReset() {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 78, resetsAt: now.addingTimeInterval(2 * 86_400))
        let facts = PopoverInsights.facts(window: window, isStale: false, now: now)
        XCTAssertEqual(facts.map(\.label), ["Remaining", "Daily allowance"])
        XCTAssertEqual(facts[0].value, "22%")
        XCTAssertEqual(facts[1].value, "\(11.0.formatted(.number.precision(.fractionLength(1))))%")
        XCTAssertEqual(facts[1].detail, "of this quota / day until reset")
    }

    func testStaleReadingsKeepLabeledRemainderButDoNotInventAnAllowance() {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 78, resetsAt: now.addingTimeInterval(2 * 86_400))
        let facts = PopoverInsights.facts(window: window, isStale: true, now: now)
        XCTAssertEqual(facts.map(\.label), ["Last remaining"])
        XCTAssertEqual(facts.first?.value, "22%")
    }

    func testElapsedUnknownAndShortWindowsCannotProduceDailyAdvice() {
        for reset in [now, now.addingTimeInterval(-1)] {
            let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 78, resetsAt: reset)
            XCTAssertTrue(PopoverInsights.facts(window: window, isStale: false, now: now).isEmpty)
        }
        for reset in [nil, now.addingTimeInterval(3_600)] {
            let window = RelayWindow(id: "session", kind: "session", title: "Session", used: 20, resetsAt: reset)
            XCTAssertEqual(PopoverInsights.facts(window: window, isStale: false, now: now).map(\.label), ["Remaining"])
        }
    }

    func testUnmeteredBalancesAndInvalidPercentagesHaveNoQuotaFacts() {
        let balance = RelayWindow(id: "balance", kind: "pool", title: "Balance", used: 0, resetsAt: nil,
                                  amount: QuotaAmount(remaining: 12, unit: "usd"), metered: false)
        XCTAssertTrue(PopoverInsights.facts(window: balance, isStale: false, now: now).isEmpty)
        let invalid = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: .nan, resetsAt: now.addingTimeInterval(86_400))
        XCTAssertTrue(PopoverInsights.facts(window: invalid, isStale: false, now: now).isEmpty)
    }

    func testExhaustionNeverBecomesNegativeRemainingQuota() {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 120, resetsAt: now.addingTimeInterval(2 * 86_400))
        let facts = PopoverInsights.facts(window: window, isStale: false, now: now)
        XCTAssertEqual(facts.first?.value, "0%")
        XCTAssertEqual(facts.last?.value, "\(0.0.formatted(.number.precision(.fractionLength(1))))%")
    }

    @MainActor
    func testExpiredCachedSessionsKeepTheRecoveryCardInEveryStyle() throws {
        let snapshot = try QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 78,
            resetsAt: now.addingTimeInterval(86_400))], provider: .openai, fetchedAt: now)
        let expired = ProviderStatus.expired("Session expired", cached: snapshot)
        XCTAssertFalse(expired.isDisconnected, "A retained reading stays in the connected list")
        XCTAssertFalse(PopoverProviderView.usesStyledReading(expired), "It still needs ProviderCard's Sign In/Cancel/Try Again controls")
        XCTAssertFalse(PopoverProviderView.usesStyledReading(.expired("Session expired", cached: nil)))
        XCTAssertTrue(PopoverProviderView.usesStyledReading(.stale(snapshot)))
        XCTAssertTrue(PopoverProviderView.usesStyledReading(.rateLimited(until: now.addingTimeInterval(60), cached: snapshot)))
    }

    @MainActor
    func testVoiceOverIncludesTheVisiblePrimaryPaceWarning() throws {
        for (used, verdict, warning) in [(78.0, Pace.Verdict.ahead, "Ahead of pace"), (100, .limitReached, "Limit reached")] {
            let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(86_400))
            let snapshot = try QuotaSnapshot.headlined(by: [window], provider: .openai, fetchedAt: now)
            let pace = Pace(verdict: verdict, delta: 20, elapsedFraction: 0.5, resetsAt: window.resetsAt!, runsOutAt: nil, severity: .tight)
            var card = ProviderCard(provider: .openai, status: .live(snapshot), pace: pace, date: now)
            let live = PopoverProviderView(card: card, style: .orbit).summaryAccessibility(RelayWindow(window))
            XCTAssertTrue(live.contains(warning), live)
            card.status = .stale(snapshot)
            let stale = PopoverProviderView(card: card, style: .orbit).summaryAccessibility(RelayWindow(window))
            XCTAssertFalse(stale.contains(warning), "Frozen readings must not gain live pace advice")
        }
    }
}
