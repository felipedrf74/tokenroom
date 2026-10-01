import XCTest
@testable import Tokenroom

final class ReadingReliabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)
    private func item(_ id: String, age: TimeInterval, used: Double = 40) -> ReadingCache.Item {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400)
        let provider = RelayProvider(id: id, name: id, shortName: id, monogram: "X", tint: "#000000", state: "live", checkedAt: now.addingTimeInterval(-age), primaryWindowID: window.id, windows: [window])
        return .init(provider: provider, source: "Mac")
    }

    func testIndividualReadingAgeOverridesFreshEnvelopeAndCacheTimes() {
        let items = [item("fresh", age: 60), item("stale", age: 3601), item("expired", age: 7 * 86_400 + 1)]
        let source = RelayMerge.Source(id: "mac", label: "Mac", envelope: .init(producer: "mac", appVersion: "1", checkedAt: now, providers: items.map(\.provider)))
        let output = ReadingAssembler.assemble(sources: [source], histories: [:], now: now)
        XCTAssertEqual(Set(output.connected.map(\.id)), ["fresh", "stale"])
        XCTAssertEqual(output.connected.first { $0.id == "stale" }?.provider.state, "stale")
        let cache = ReadingCache(savedAt: now, isSample: false, items: items).presented(at: now)
        XCTAssertEqual(cache.staleCount(at: now), 1)
        XCTAssertEqual(cache.checkedAt, now.addingTimeInterval(-3601))
    }

    func testPartialUpdateKeepsEachNewestReadingAndHonorsRemoval() {
        let previous = ReadingCache(savedAt: now, isSample: false, items: [item("olderIncoming", age: 0), item("newerIncoming", age: 60), item("removed", age: 0)])
        let incoming = ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: [item("olderIncoming", age: 120), item("newerIncoming", age: 0)])
        let merged = previous.mergingUpdate(incoming)
        XCTAssertEqual(merged.items.map(\.id), ["olderIncoming", "newerIncoming"])
        XCTAssertTrue(merged.items.allSatisfy { $0.provider.checkedAt == now })
        XCTAssertEqual(merged.mergingUpdate(previous), merged, "A delayed whole cache cannot undo removals")
    }

    func testDelayedPhoneEnvelopeAdvancesChecksWithoutUndoingMembership() {
        let cloud = ReadingCache(savedAt: now, isSample: false, items: [item("retained", age: 120), item("added", age: 0)])
        let phone = ReadingCache(savedAt: now.addingTimeInterval(-30), isSample: false,
            items: [item("retained", age: 10, used: 70), item("removed", age: 0)])
        let merged = cloud.mergingUpdate(phone)
        XCTAssertEqual(merged.items.map(\.id), ["retained", "added"])
        XCTAssertEqual(merged.items.first?.provider.checkedAt, now.addingTimeInterval(-10))
        XCTAssertEqual(merged.items.first?.provider.primaryWindow?.used, 70)
        XCTAssertEqual(merged.savedAt, cloud.savedAt)
        let removed = ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: [])
        XCTAssertTrue(merged.mergingUpdate(removed).mergingUpdate(phone).items.isEmpty)
    }

    func testWatchDiskGateSurvivesFailedWritesAndReopensOnlyAfterValidatedSave() throws {
        let suite = "tokenroom.tests.watch.disk." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent(ReadingCache.fileName)
        let old = ReadingCache(savedAt: now, isSample: false, items: [item("one", age: 0)])
        try old.save(to: url)
        let cutoff = now.addingTimeInterval(10)
        WatchCacheAccess.invalidate(in: defaults, at: cutoff)
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults), "Relaunch/snapshot cannot show the unchanged disk file")
        var fresh = old
        fresh.savedAt = now.addingTimeInterval(20)
        let impossibleURL = directory.appendingPathComponent("missing/readings.json")
        // Use a regular file as a parent: no writer can create a cache below it.
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data().write(to: blockedParent)
        XCTAssertThrowsError(try WatchCacheAccess.saveValidated(fresh, at: blockedParent.appendingPathComponent("readings.json"), defaults: defaults, cutoff: cutoff))
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults))
        try WatchCacheAccess.saveValidated(fresh, at: url, defaults: defaults, cutoff: cutoff)
        XCTAssertEqual(WatchCacheAccess.load(at: url, defaults: defaults), fresh)
        let switched = now.addingTimeInterval(30)
        WatchCacheAccess.invalidate(in: defaults, at: switched)
        fresh.savedAt = now.addingTimeInterval(40)
        try WatchCacheAccess.saveValidated(fresh, at: impossibleURL, defaults: defaults, cutoff: cutoff)
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults), "A result from the previous account cannot reopen the gate")
    }

    func testComplicationCannotReuseDiskCacheUntilAccountIsValidated() async throws {
        let suite = "tokenroom.tests.watch.complication." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent(ReadingCache.fileName)
        let old = ReadingCache(savedAt: now, isSample: false, items: [item("one", age: 0)])
        try old.save(to: url)
        let cutoff = now.addingTimeInterval(10)
        WatchCacheAccess.invalidate(in: defaults, at: cutoff)
        let offline = await RelayReadings.cache(at: url, maxAge: 900, budget: 1, now: cutoff.addingTimeInterval(1), defaults: defaults, readOutcome: { .failed })
        XCTAssertNil(offline, "Even a recent cache stays hidden across restart while validation fails")
        var fresh = old
        fresh.savedAt = now.addingTimeInterval(20)
        let validated = fresh
        let recovered = await RelayReadings.cache(at: url, maxAge: 900, budget: 1, now: validated.savedAt, defaults: defaults, readOutcome: { .readings(validated) })
        XCTAssertEqual(recovered?.items.first?.id, "one")
        XCTAssertEqual(WatchCacheAccess.load(at: url, defaults: defaults), fresh)
        let signedOut = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: now.addingTimeInterval(30), defaults: defaults, readOutcome: { .noAccount })
        XCTAssertTrue(signedOut?.items.isEmpty == true)
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults))
    }

    func testLivingWatchAdoptsComplicationValidatedCacheAfterItsOwnReadFails() throws {
        let suite = "tokenroom.tests.watch.resume." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent(ReadingCache.fileName)
        let cutoff = now.addingTimeInterval(10)
        WatchCacheAccess.invalidate(in: defaults, at: cutoff)
        XCTAssertNil(WatchCacheRecovery.recover(nil, at: url, defaults: defaults))
        let saved = ReadingCache(savedAt: cutoff.addingTimeInterval(20), isSample: false,
                                 items: [item("complication", age: 0)])
        try WatchCacheAccess.saveValidated(saved, at: url, defaults: defaults, cutoff: cutoff)
        // The app process stays alive with nil memory after accountChanged. Its iCloud request
        // can fail, but the complication's validated file remains a usable reading.
        let recovered = WatchCacheRecovery.recover(nil, at: url, defaults: defaults)
        XCTAssertEqual(recovered, saved)
        var older = saved
        older.savedAt = cutoff.addingTimeInterval(15)
        older.items[0].provider.windows[0].used = 5
        XCTAssertEqual(WatchCacheRecovery.recover(older, at: url, defaults: defaults)?.items.first?.provider.primaryWindow?.used, 40)
        WatchCacheAccess.invalidate(in: defaults, at: cutoff.addingTimeInterval(30))
        XCTAssertNil(WatchCacheRecovery.recover(nil, at: url, defaults: defaults),
                     "A later account change cannot adopt the previous account's file")
    }

    func testWatchSignOutRejectsOldHandoverEvenAfterRevalidation() {
        var gate = WatchAccountGate()
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("one", age: 0)])
        XCTAssertFalse(gate.accepts(cache), "Startup must validate iCloud first")
        gate.confirmAvailable()
        XCTAssertTrue(gate.accepts(cache))
        gate.signOut(at: now.addingTimeInterval(10))
        XCTAssertFalse(gate.accepts(cache))
        gate.confirmAvailable()
        XCTAssertFalse(gate.accepts(cache))
        var fresh = cache
        fresh.savedAt = now.addingTimeInterval(20)
        XCTAssertTrue(gate.accepts(fresh))
    }

    func testExhaustedSecondarySessionRanksAheadOfHealthyHeadline() {
        var urgent = item("urgent", age: 0, used: 10)
        urgent.provider.windows.append(.init(id: "session", kind: "session", title: "5-hour", used: 100, resetsAt: now.addingTimeInterval(3600), periodSec: 5 * 3600))
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("ordinary", age: 0, used: 70), urgent]).presented(at: now)
        XCTAssertEqual(cache.items.first?.id, "urgent")
        XCTAssertEqual(cache.items.first?.provider.primaryWindow?.used, 10)
        XCTAssertEqual(UsageRanking.limitWarning(for: urgent.provider, now: now), "5-hour limit reached")
        XCTAssertNil(UsageRanking.limitWarning(for: urgent.provider, now: now.addingTimeInterval(3600)))
    }

    func testElapsedWindowCannotForecastAlertOrRankAsReached() {
        var previous = item("one", age: 0, used: 60).provider
        previous.windows[0].resetsAt = now
        var current = previous
        current.windows[0].used = 100
        XCTAssertTrue(AlertRules.alerts(previous: previous, current: current, preferences: AlertPreferences(), now: now).isEmpty)
        XCTAssertNil(UsageRanking.pace(for: current.windows[0], isStale: false, history: nil, now: now))
        XCTAssertEqual(ReadingText.reset(current.windows[0], now: now), "Reset · awaiting reading")
    }

    func testRankingTieUsesTheUrgentSessionInsteadOfACalmWeeklyPercentage() {
        var lower = item("lower", age: 0, used: 90)
        var higher = item("higher", age: 0, used: 10)
        for index in lower.provider.windows.indices { lower.provider.windows[index].resetsAt = now.addingTimeInterval(3600) }
        for index in higher.provider.windows.indices { higher.provider.windows[index].resetsAt = now.addingTimeInterval(3600) }
        let session = RelayWindow(id: "session", kind: "session", title: "5-hour", used: 60, resetsAt: now.addingTimeInterval(3 * 3600), periodSec: 5 * 3600)
        lower.provider.windows.append(session)
        var higherSession = session
        higherSession.used = 65
        higher.provider.windows.append(higherSession)
        XCTAssertEqual(UsageRanking.pace(for: session, isStale: false, history: nil, now: now)?.severity, .tight)
        XCTAssertEqual(UsageRanking.pace(for: higherSession, isStale: false, history: nil, now: now)?.severity, .tight)
        let presented = ReadingCache(savedAt: now, isSample: false, items: [lower, higher]).presented(at: now)
        XCTAssertEqual(presented.items.map(\.id), ["higher", "lower"])
        XCTAssertEqual(presented.items.map { $0.provider.primaryWindow?.used }, [10, 90], "Ranking cannot change the primary headline")
    }

    func testAttentionExplainsElapsedPrimaryAndSecondaryWithoutInventingZero() {
        var reading = item("one", age: 0, used: 60).provider
        reading.windows[0].resetsAt = now
        XCTAssertEqual(ReadingText.headline(reading.primaryWindow, now: now), "—")
        XCTAssertEqual(ReadingText.attention(reading, now: now), "Reset · awaiting reading")
        XCTAssertEqual(reading.primaryWindow?.used, 60)
        reading.windows[0].resetsAt = now.addingTimeInterval(3600)
        reading.windows.append(.init(id: "session", kind: "session", title: "5-hour", used: 100, resetsAt: now, periodSec: 5 * 3600))
        XCTAssertEqual(ReadingText.attention(reading, now: now), "5-hour: Reset · awaiting reading")
    }

    func testAnExhaustedSecondaryWarningSurvivesAPendingPrimaryReset() {
        var reading = item("one", age: 0).provider
        reading.windows[0].resetsAt = now
        reading.windows.append(.init(id: "session", kind: "session", title: "5-hour", used: 100, resetsAt: now.addingTimeInterval(3600), periodSec: 5 * 3600))
        XCTAssertEqual(ReadingText.attention(reading, now: now), "5-hour limit reached")
        reading.state = "stale"
        XCTAssertEqual(ReadingText.attention(reading, now: now), "Reset · awaiting reading", "A stale exhausted session is not a current warning")
    }

    func testWidgetTimelinesIncludeFreshnessAndExpiryBoundaries() {
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item("old", age: 3500)])
        let dates = cache.presentationDates(after: now, until: now.addingTimeInterval(8 * 3600))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(101)))
        let expiring = ReadingCache(savedAt: now, isSample: false, items: [item("old", age: 7 * 86_400 - 60)])
        XCTAssertTrue(expiring.presentationDates(after: now, until: now.addingTimeInterval(3600)).contains(now.addingTimeInterval(61)))
        XCTAssertTrue(expiring.presented(at: now.addingTimeInterval(61)).items.isEmpty)
    }

    func testWatchResetScheduleIncludesExactBoundaryWithoutRepeatingIt() {
        var reading = item("one", age: 0)
        reading.provider.windows[0].resetsAt = now.addingTimeInterval(600)
        reading.provider.windows.append(reading.provider.windows[0])
        let cache = ReadingCache(savedAt: now, isSample: false, items: [reading])
        XCTAssertEqual(cache.resetDates(after: now, through: now.addingTimeInterval(600)), [now.addingTimeInterval(600)])
        XCTAssertTrue(cache.resetDates(after: now.addingTimeInterval(600), through: now.addingTimeInterval(1200)).isEmpty)
    }

    /// A Watch launched with sample readings keeps them: a simulator with no iCloud account
    /// answered "no account", which replaced them with an empty cache and left the opened
    /// provider's page blank.
    func testSampleReadingsOnTheWatchAreNotReplacedForTheLaunch() {
        let sample = SampleData.cache()
        XCTAssertFalse(WatchCacheAccess.mayReplace(sample, showsSample: true))
        XCTAssertTrue(WatchCacheAccess.mayReplace(sample, showsSample: false))
        XCTAssertTrue(WatchCacheAccess.mayReplace(nil, showsSample: true))
        XCTAssertTrue(WatchCacheAccess.mayReplace(ReadingCache(savedAt: .now, isSample: false, items: []), showsSample: true))
        XCTAssertNotNil(sample.items.first { $0.id == "openai" }, "The provider the screenshot opens is in the sample")
    }

    func testTheWatchNamesWhereAReadingCameFrom() throws {
        let item = try XCTUnwrap(SampleData.cache().items.first)
        XCTAssertEqual(item.watchOriginLine, "Sample data")
        var phone = item, mac = item
        phone.source = "This iPhone"
        mac.source = "Studio"
        mac.origin = .mac
        XCTAssertEqual(phone.watchOriginLine, "From your iPhone")
        XCTAssertEqual(mac.watchOriginLine, "From your Mac")
        for line in [item, phone, mac].map(\.watchOriginLine) {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("this iPhone"), line)
        }
    }
}
