import CloudKit
import XCTest
@testable import Tokenroom

final class WidgetFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cache(checked: Date, used: Double = 42) -> ReadingCache {
        let provider = RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: checked, primaryWindowID: "weekly",
            windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(7 * 86_400))])
        return ReadingCache(savedAt: checked, isSample: false, items: [.init(provider: provider, source: "Mac")])
    }

    func testReconfirmedChecksRenewTheTimelineAt45Minutes() {
        let initial = cache(checked: now)
        let baseline = WidgetReloadSchedule.Baseline(cache: initial, at: now)
        for minute in [44, 45] {
            let date = now.addingTimeInterval(Double(minute) * 60)
            XCTAssertEqual(WidgetReloadSchedule.needsReload(cache(checked: date), since: baseline, at: date,
                background: true, reloads: 0), minute == 45)
        }
        let date = now.addingTimeInterval(45 * 60)
        var current = cache(checked: date)
        var abandoned = initial.items[0]
        abandoned.provider.id = "openai"
        abandoned.provider.checkedAt = now.addingTimeInterval(-2 * 3600)
        abandoned.provider.state = "stale"
        var previous = initial
        previous.items.append(abandoned)
        current.items.append(abandoned)
        XCTAssertTrue(WidgetReloadSchedule.needsReload(current, since: .init(cache: previous, at: now), at: date,
            background: true, reloads: 0), "An abandoned provider cannot pin the freshness of every widget")
        XCTAssertFalse(WidgetReloadSchedule.needsReload(current, since: .init(cache: previous, at: now), at: date,
            background: true, reloads: 32), "Freshness-only requests respect the daily allowance")
    }

    func testFastCollectorClockAndRelaunchDoNotLoseTheReloadBaseline() throws {
        let suite = "tokenroom.tests.widget-freshness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        WidgetReloadSchedule.record(cache(checked: now.addingTimeInterval(360)), at: now, in: defaults)
        let reloadedDefaults = UserDefaults(suiteName: suite)!
        let baseline = try XCTUnwrap(WidgetReloadSchedule.load(from: reloadedDefaults))
        let date = now.addingTimeInterval(45 * 60)
        XCTAssertTrue(WidgetReloadSchedule.needsReload(cache(checked: date.addingTimeInterval(360)), since: baseline,
            at: date, background: true, reloads: 0))
        let changed = cache(checked: now.addingTimeInterval(60), used: 43)
        XCTAssertFalse(WidgetReloadSchedule.needsReload(changed, since: baseline, at: changed.savedAt, background: true, reloads: 0))
        XCTAssertTrue(WidgetReloadSchedule.needsReload(changed, since: baseline, at: changed.savedAt, background: false, reloads: 40))
        var otherAccount = changed
        otherAccount.accountGeneration = "new-generation"
        XCTAssertTrue(WidgetReloadSchedule.needsReload(otherAccount, since: baseline, at: changed.savedAt, background: true, reloads: 0))
    }

    func testADayOfHeartbeatsAndTimelinesStaysWithinTheReloadAllowance() {
        var latest = cache(checked: now)
        var baseline = WidgetReloadSchedule.Baseline(cache: latest, at: now)
        var reloads = 1
        var nextTimeline = latest.nextReload(after: now, reloads: reloads)
        for minute in 1..<1440 {
            let date = now.addingTimeInterval(Double(minute) * 60)
            var requested = false
            if minute.isMultiple(of: 9) {
                latest = cache(checked: date)
                requested = WidgetReloadSchedule.needsReload(latest, since: baseline, at: date, background: true, reloads: reloads)
                if requested { baseline = .init(cache: latest, at: date) }
            }
            if requested || date >= nextTimeline {
                reloads += 1
                nextTimeline = latest.nextReload(after: date, reloads: reloads)
            }
        }
        XCTAssertLessThanOrEqual(reloads, 40)
        XCTAssertGreaterThanOrEqual(reloads, 24)
    }

    func testAFailedWidgetReadRetriesSoonWithoutExhaustingTheBudgetOrIgnoringServerWaits() {
        let old = cache(checked: now.addingTimeInterval(-2 * 3600))
        let failure = WidgetRefreshResult(cache: old, retryAt: now)
        XCTAssertEqual(failure.nextReload(after: now, reloads: 1), now.addingTimeInterval(300))
        XCTAssertEqual(failure.nextReload(after: now, reloads: 16), now.addingTimeInterval(3600))
        XCTAssertEqual(failure.nextReload(after: now, reloads: 32), now.addingTimeInterval(3600))
        let serverWait = now.addingTimeInterval(7200)
        XCTAssertEqual(WidgetRefreshResult(cache: old, retryAt: serverWait).nextReload(after: now, reloads: 1), serverWait)
        XCTAssertEqual(WidgetRefreshResult(cache: old).nextReload(after: now, reloads: 1), now.addingTimeInterval(3600))
    }

    func testAContinuouslyOfflineDayReservesRoomForHourlyRecovery() {
        var date = now
        var reloads = 1
        let end = now.addingTimeInterval(24 * 3600)
        while true {
            date = WidgetRefreshResult(cache: nil, retryAt: date).nextReload(after: date, reloads: reloads)
            if date >= end { break }
            reloads += 1
        }
        XCTAssertLessThanOrEqual(reloads, 40, "Five-minute retries cannot use the thirty-two half-hour allowance")
        XCTAssertGreaterThanOrEqual(reloads, 24, "Recovery continues after the short retry allowance")
    }

    func testOnlyTransientKeyFailuresRequestAShortWidgetRetry() {
        XCTAssertNil(WidgetRefreshResult.retryDate(cloudRetryAt: nil,
            keyFailures: [.expired("Key refused"), .notEntitled("Not on this plan"), .rateLimited(until: now.addingTimeInterval(3600))], now: now))
        XCTAssertEqual(WidgetRefreshResult.retryDate(cloudRetryAt: nil,
            keyFailures: [.expired("Key refused"), .unreachable], now: now), now)
        let serverWait = now.addingTimeInterval(3600)
        XCTAssertEqual(WidgetRefreshResult.retryDate(cloudRetryAt: serverWait,
            keyFailures: [.unreachable], now: now), serverWait, "A connection failure cannot shorten a server wait")
    }

    func testPresentationSavesCannotDelayAWidgetsOwnCloudRead() throws {
        var saved = cache(checked: now)
        saved.cloudReadAt = now.addingTimeInterval(-20 * 60)
        XCTAssertTrue(saved.needsWidgetRefresh(at: now, maxAge: 15 * 60))
        saved.cloudReadAt = now
        XCTAssertFalse(saved.needsWidgetRefresh(at: now, maxAge: 15 * 60))
        saved.items[0].provider.checkedAt = now.addingTimeInterval(-56 * 60)
        XCTAssertTrue(saved.needsWidgetRefresh(at: now, maxAge: 15 * 60))
        let legacy = cache(checked: now)
        let decoded = try RelayEnvelope.decoder.decode(ReadingCache.self, from: RelayEnvelope.encoder.encode(legacy))
        XCTAssertNil(decoded.cloudReadAt)
        XCTAssertTrue(decoded.needsWidgetRefresh(at: now, maxAge: 15 * 60))
    }

    func testPhoneConnectionFailuresHaveAShortRetryAndServerWaitsStillWin() {
        for code in [CKError.Code.networkUnavailable, .networkFailure] {
            let error = CKError(code)
            guard case .retry(let delay, _) = RelayErrorPolicy.outcome(for: error, defaultRetry: 300, networkRetry: 15) else {
                return XCTFail("A connection failure retries")
            }
            XCTAssertEqual(delay, 15)
            XCTAssertTrue(RelayErrorPolicy.isConnectionFailure(error))
            let server = CKError(code, userInfo: [CKErrorRetryAfterKey: 90.0])
            XCTAssertFalse(RelayErrorPolicy.isConnectionFailure(server))
            guard case .retry(let asked, _) = RelayErrorPolicy.outcome(for: server, defaultRetry: 300, networkRetry: 15) else {
                return XCTFail("The server's explicit wait remains")
            }
            XCTAssertEqual(asked, 90)
        }
        guard case .retry(let delay, _) = RelayErrorPolicy.outcome(for: CKError(.requestRateLimited), defaultRetry: 300, networkRetry: 15) else {
            return XCTFail("Rate limits retain their wait")
        }
        XCTAssertEqual(delay, 300)
    }
}
