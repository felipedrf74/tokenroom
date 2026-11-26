import XCTest
@testable import Tokenroom

final class StaleBoundaryAgreementTests: XCTestCase {
    private let checked = Date(timeIntervalSince1970: 1_790_337_600)

    private var cache: ReadingCache {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 64, resetsAt: checked.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400)
        let provider = RelayProvider(id: "openai", name: "OpenAI", shortName: "OpenAI", monogram: "O", tint: "#000000", state: "live", checkedAt: checked, primaryWindowID: window.id, windows: [window])
        return ReadingCache(savedAt: checked, isSample: false, items: [.init(provider: provider, source: "Mac")])
    }

    private var activity: SessionActivityState {
        SessionActivityState(used: 64, resetsAt: checked.addingTimeInterval(4 * 3600), isStale: false, checkedAt: checked)
    }

    func testTheLiveActivityAndTheCacheGoStaleAtTheSameSecond() {
        for (age, stale) in [(3599.0, false), (3600, false), (3601, true)] {
            let now = checked.addingTimeInterval(age)
            XCTAssertEqual(cache.presented(at: now).items.first?.provider.isLive, !stale, "The cache at \(age) s")
            XCTAssertEqual(cache.staleCount(at: now), stale ? 1 : 0, "The cache at \(age) s")
            XCTAssertEqual(activity.shown(isStale: false, now: now).isStale, stale, "The Live Activity at \(age) s")
            XCTAssertEqual(activity.shown(isStale: false, now: now).isStaleBeforeReset, stale, "The Live Activity at \(age) s")
        }
    }

    func testTheSystemAndWidgetScheduleTheSameStaleTransition() {
        let next = checked.addingTimeInterval(3601)
        let staleDate = LiveActivityFreshness.staleDate(resetsAt: activity.resetsAt, checkedAt: checked)
        XCTAssertEqual(staleDate, next)
        XCTAssertEqual(cache.presentationDates(after: checked, until: activity.resetsAt).first, staleDate)
        for age in [3599.0, 3600, 3601] {
            let now = checked.addingTimeInterval(age)
            let shown = activity.shown(isStale: now >= staleDate, now: now)
            XCTAssertEqual(shown.isStale, cache.staleCount(at: now) == 1)
        }
    }
}
