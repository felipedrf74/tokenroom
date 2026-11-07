import XCTest
@testable import Tokenroom

/// The Watch, widget, and iPhone sign-in sync decision of 7 November 2026
/// (`docs/watch-sync-council-20261107.md`): the rules as pure functions, since the Watch app's
/// store isn't in a test target.
final class WatchSyncDecisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "tokenroom.tests.watchsync." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func provider(_ id: String, checked: Date, used: Double = 40, state: String = "live") -> RelayProvider {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400)
        return RelayProvider(id: id, name: id, shortName: id, monogram: "X", tint: "#000000", state: state, checkedAt: checked,
                             primaryWindowID: window.id, windows: [window])
    }

    private func cache(savedAt: Date, _ providers: [RelayProvider]) -> ReadingCache {
        ReadingCache(savedAt: savedAt, isSample: false, items: providers.map { ReadingCache.Item(provider: $0, source: "Mac") })
    }

    // MARK: 1. Handover acceptance

    func testAColdWatchHoldsAHandoverUntilItKnowsItsAccount() {
        let handover = cache(savedAt: now, [provider("claude", checked: now)])
        XCTAssertEqual(WatchHandoffAcceptance.decide(handover, validated: false, account: .unknown, signedOutAt: nil), .hold,
                       "A cold background launch hasn't read iCloud or asked for the account")
        XCTAssertEqual(WatchHandoffAcceptance.decide(handover, validated: false, account: .available, signedOutAt: nil), .apply,
                       "accountStatus() said available")
        XCTAssertEqual(WatchHandoffAcceptance.decide(handover, validated: true, account: .unknown, signedOutAt: nil), .apply)
    }

    func testWithoutAnAccountOrAfterAFailedReadOnlyHandoversSinceTheSignOutApply() {
        let cutoff = now
        let before = cache(savedAt: cutoff.addingTimeInterval(-1), [provider("claude", checked: now)])
        let atCutoff = cache(savedAt: cutoff, [provider("claude", checked: now)])
        let after = cache(savedAt: cutoff.addingTimeInterval(1), [provider("claude", checked: now)])
        for account in [WatchAccountKnowledge.noAccount, .readFailed, .available, .unknown] {
            XCTAssertEqual(WatchHandoffAcceptance.decide(before, validated: false, account: account, signedOutAt: cutoff), .drop, "\(account)")
            XCTAssertEqual(WatchHandoffAcceptance.decide(atCutoff, validated: true, account: account, signedOutAt: cutoff), .drop, "\(account): never one from before the sign-out")
        }
        XCTAssertEqual(WatchHandoffAcceptance.decide(after, validated: false, account: .noAccount, signedOutAt: cutoff), .apply, "iCloud off: the iPhone's readings since the cutoff")
        XCTAssertEqual(WatchHandoffAcceptance.decide(after, validated: false, account: .readFailed, signedOutAt: cutoff), .apply, "iCloud out of reach")
        var sample = after
        sample.isSample = true
        XCTAssertEqual(WatchHandoffAcceptance.decide(sample, validated: true, account: .available, signedOutAt: nil), .drop)
    }

    func testTheGateKeepsWhatItKnowsAndForgetsItAtASignOut() {
        var gate = WatchAccountGate(signedOutAt: now)
        let fresh = cache(savedAt: now.addingTimeInterval(10), [provider("claude", checked: now)])
        XCTAssertEqual(gate.decision(for: fresh), .hold)
        gate.note(.readFailed)
        XCTAssertTrue(gate.accepts(fresh))
        gate.signOut(at: now.addingTimeInterval(20))
        XCTAssertEqual(gate.account, .unknown, "An account change starts over")
        XCTAssertEqual(gate.decision(for: fresh), .drop)
        gate.confirmAvailable()
        gate.note(.readFailed)
        XCTAssertEqual(gate.account, .available, "A later failed check doesn't undo a read that went through")
        XCTAssertEqual(WatchAccountKnowledge(.available), .available)
        XCTAssertEqual(WatchAccountKnowledge(.noAccount), .noAccount)
        XCTAssertEqual(WatchAccountKnowledge(.failed), .readFailed)
        XCTAssertEqual(WatchAccountKnowledge(.unavailable), .unknown, "No iCloud in this build unlocks nothing")
    }

    func testAHeldHandoverIsSavedAndOutlivesTheProcessButNotASignOut() throws {
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(WatchPendingHandoff.fileName)
        let held = cache(savedAt: now, [provider("claude", checked: now)])
        WatchPendingHandoff.save(held, at: url)
        XCTAssertEqual(WatchPendingHandoff.load(at: url, signedOutAt: now.addingTimeInterval(-60)), held)
        XCTAssertNil(WatchPendingHandoff.load(at: url, signedOutAt: now), "Saved before the sign-out: dropped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "And deleted")
        var sample = held
        sample.isSample = true
        WatchPendingHandoff.save(sample, at: url)
        XCTAssertNil(WatchPendingHandoff.load(at: url, signedOutAt: nil))
    }

    func testComplicationsKeepTheIPhonesReadingsWhileTheWatchStaysSignedOut() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        // Signed in before: the first no-account read is a sign-out and empties everything.
        try cache(savedAt: now, [provider("claude", checked: now)]).save(to: url)
        let signedOut = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: now.addingTimeInterval(10), defaults: defaults, readOutcome: { .noAccount })
        XCTAssertEqual(signedOut?.items.isEmpty, true)
        let cutoff = try XCTUnwrap(defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date)
        XCTAssertTrue(WatchCacheAccess.isStillSignedOut(in: defaults))
        // The Watch app takes the iPhone's handover since then and saves it for complications.
        let fromPhone = cache(savedAt: cutoff.addingTimeInterval(30), [provider("codex", checked: cutoff.addingTimeInterval(30))])
        try WatchCacheAccess.saveValidated(fromPhone, at: url, defaults: defaults, cutoff: cutoff)
        // Still no account later: not another sign-out, so the handover stays.
        let later = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: cutoff.addingTimeInterval(60), defaults: defaults, readOutcome: { .noAccount })
        XCTAssertEqual(later?.items.map(\.id), ["codex"])
        XCTAssertEqual(defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date, cutoff, "The cutoff doesn't move")
        // An account answered in between: the next no-account is a sign-out again.
        let signedIn = cache(savedAt: cutoff.addingTimeInterval(90), [provider("claude", checked: cutoff.addingTimeInterval(90))])
        _ = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: cutoff.addingTimeInterval(90), defaults: defaults, readOutcome: { .readings(signedIn) })
        XCTAssertFalse(WatchCacheAccess.isStillSignedOut(in: defaults))
        let again = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: cutoff.addingTimeInterval(120), defaults: defaults, readOutcome: { .noAccount })
        XCTAssertEqual(again?.items.isEmpty, true)
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults))
        // An account change clears the marker too.
        WatchCacheAccess.confirmNoAccount(in: defaults, at: cutoff.addingTimeInterval(150))
        WatchCacheAccess.invalidate(in: defaults, at: cutoff.addingTimeInterval(160))
        XCTAssertFalse(WatchCacheAccess.isStillSignedOut(in: defaults))
    }

    /// Review fix: an account that only `accountStatus()` saw (a cold launch taking a handover)
    /// ends "still signed out", so the next no-account is a sign-out that hides the handover.
    func testAnAccountOnlyTheAccountCheckSawEndsStillSignedOut() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        let t1 = now
        WatchCacheAccess.confirmNoAccount(in: defaults, at: t1)
        XCTAssertTrue(WatchCacheAccess.isStillSignedOut(in: defaults))
        // Signed in again; a cold background launch checks the account and takes a handover.
        WatchCacheAccess.note(.available, in: defaults)
        let t2 = t1.addingTimeInterval(600)
        let handover = cache(savedAt: t2, [provider("claude", checked: t2)])
        try WatchCacheAccess.saveValidated(handover, at: url, defaults: defaults, cutoff: t1)
        XCTAssertEqual(WatchCacheAccess.load(at: url, defaults: defaults), handover)
        // Complications skip iCloud while the cache is recent. Signed out at T3, once it isn't:
        // a complication's read is a sign-out, not the same one as at T1.
        let t3 = t2.addingTimeInterval(20 * 60)
        let shown = await RelayReadings.cache(at: url, maxAge: 15 * 60, budget: 1, now: t3, defaults: defaults, readOutcome: { .noAccount })
        XCTAssertEqual(shown?.items.isEmpty, true, "The handover from while signed in isn't shown")
        XCTAssertEqual(defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date, t3, "A new cutoff")
        XCTAssertNil(WatchCacheAccess.load(at: url, defaults: defaults))
        // Checks that found nothing, or no account, leave the marker as it was.
        WatchCacheAccess.note(.failed, in: defaults)
        WatchCacheAccess.note(.noAccount, in: defaults)
        XCTAssertTrue(WatchCacheAccess.isStillSignedOut(in: defaults))
    }

    // MARK: 2. iCloud first

    @MainActor
    func testTheWatchAppliesICloudBeforeTheIPhonesReplyComes() async {
        let events = LockedBox<[String]>([])
        await WatchRefreshOrder.run(
            cloud: { "cloud" },
            phone: {
                try? await Task.sleep(for: .milliseconds(300))
                events.value.append("phone answered")
                return "phone"
            },
            applyCloud: { (outcome: String) in
                events.value.append("applied \(outcome)")
                return true
            },
            applyPhone: { (reply: String) in events.value.append("applied \(reply)") }
        )
        XCTAssertEqual(events.value, ["applied cloud", "phone answered", "applied phone"])
    }

    @MainActor
    func testAnAccountChangeDuringTheReadSkipsTheReplyWithoutWaitingForIt() async {
        let events = LockedBox<[String]>([])
        let started = Date()
        await WatchRefreshOrder.run(
            cloud: { "cloud" },
            phone: { () async -> String in
                do {
                    try await Task.sleep(for: .seconds(5))
                    return "phone"
                } catch {
                    events.value.append("phone cancelled")
                    return "cancelled"
                }
            },
            applyCloud: { (_: String) in false },
            applyPhone: { (_: String) in events.value.append("applied phone") }
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Not held by the reply")
        XCTAssertFalse(events.value.contains("applied phone"))
    }

    func testTheIPhonesReadingsClearCouldntReachICloudButNotSignedOut() {
        XCTAssertNil(WatchProblem.unreachable.afterPhoneData())
        XCTAssertEqual(WatchProblem.noAccount.afterPhoneData(), .noAccount)
    }

    // MARK: 3. Re-confirmed readings reach the Watch

    func testAReadingCheckedAgainHalfAnHourLaterIsHandedOverWithTheSameNumbers() {
        let handedOver = WatchHandoffSchedule.checks(in: cache(savedAt: now, [provider("claude", checked: now), provider("codex", checked: now)]))
        let fiveLater = cache(savedAt: now.addingTimeInterval(300), [provider("claude", checked: now.addingTimeInterval(300)), provider("codex", checked: now)])
        let later = cache(savedAt: now.addingTimeInterval(31 * 60), [provider("claude", checked: now.addingTimeInterval(31 * 60)), provider("codex", checked: now)])
        XCTAssertEqual(fiveLater.materialHash(at: fiveLater.savedAt), later.materialHash(at: fiveLater.savedAt), "The numbers are the same")
        XCTAssertFalse(WatchHandoffSchedule.checksMoved(WatchHandoffSchedule.checks(in: fiveLater), since: handedOver), "+5 minutes: not yet")
        XCTAssertTrue(WatchHandoffSchedule.checksMoved(WatchHandoffSchedule.checks(in: later), since: handedOver), "+31 minutes: handed over")
    }

    func testAStaleProviderDoesntHoldBackTheOthersHandover() {
        let old = now.addingTimeInterval(-3 * 86_400)
        let handedOver = WatchHandoffSchedule.checks(in: cache(savedAt: now, [provider("stale", checked: old, state: "stale"), provider("claude", checked: now)]))
        let later = cache(savedAt: now.addingTimeInterval(40 * 60), [provider("stale", checked: old, state: "stale"), provider("claude", checked: now.addingTimeInterval(40 * 60))])
        XCTAssertTrue(WatchHandoffSchedule.checksMoved(WatchHandoffSchedule.checks(in: later), since: handedOver),
                      "The oldest check overall is pinned by the stale one; Claude's moved")
        let added = cache(savedAt: now.addingTimeInterval(40 * 60), [provider("new", checked: now.addingTimeInterval(40 * 60))])
        XCTAssertFalse(WatchHandoffSchedule.checksMoved(WatchHandoffSchedule.checks(in: added), since: handedOver),
                       "A provider new to the Watch is a change of what's drawn, handed over for that")
    }

    // MARK: 4. Reloads before the stale boundary

    func testWidgetsAndComplicationsReloadFiveMinutesBeforeAReadingGoesStale() {
        let checked = now.addingTimeInterval(-50 * 60)
        let item = ReadingCache.Item(provider: provider("claude", checked: checked), source: "Mac")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item]), checked.addingTimeInterval(55 * 60),
                       "Five minutes before the hour, not a second after it")
        let fresh = ReadingCache(savedAt: now.addingTimeInterval(-60), isSample: false, items: [item])
        XCTAssertFalse(fresh.nearsStale(at: now))
        XCTAssertTrue(RelayReadings.isRecent(fresh, maxAge: 15 * 60, now: now, keepsSamples: false))
        let reload = checked.addingTimeInterval(55 * 60)
        XCTAssertTrue(fresh.nearsStale(at: reload))
        XCTAssertFalse(RelayReadings.isRecent(fresh, maxAge: 15 * 60, now: reload, keepsSamples: false),
                       "Saved minutes ago, but its reading is about to fade: read iCloud again")
        XCTAssertFalse(fresh.nearsStale(at: checked.addingTimeInterval(61 * 60)), "Already stale: not read on every reload")
    }

    // MARK: 5. Live Activity

    func testALiveActivityStateSavedByAnEarlierVersionStillDecodes() throws {
        struct Earlier: Codable {
            var used: Double
            var resetsAt: Date
            var isStale: Bool
            var warnedRunsOut: Bool?
            var awaitingReading: Bool?
        }
        let resets = now.addingTimeInterval(3600)
        for encoder in [JSONEncoder(), RelayEnvelope.encoder] {
            let data = try encoder.encode(Earlier(used: 42, resetsAt: resets, isStale: false, warnedRunsOut: true, awaitingReading: nil))
            let decoder = encoder === RelayEnvelope.encoder ? RelayEnvelope.decoder : JSONDecoder()
            let state = try decoder.decode(SessionActivityState.self, from: data)
            XCTAssertEqual(state, SessionActivityState(used: 42, resetsAt: resets, isStale: false, warnedRunsOut: true, awaitingReading: nil, checkedAt: nil))
            XCTAssertEqual(LiveActivityFreshness.staleDate(resetsAt: resets, checkedAt: state.checkedAt), resets, "Stale at its reset, as before")
        }
        let current = SessionActivityState(used: 42, resetsAt: resets, isStale: false, checkedAt: now)
        XCTAssertEqual(try JSONDecoder().decode(SessionActivityState.self, from: JSONEncoder().encode(current)), current)
    }

    func testALiveActivityGoesStaleAnHourAfterItsCheckWhenThatComesBeforeTheReset() {
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(LiveActivityFreshness.staleDate(resetsAt: reset, checkedAt: now), now.addingTimeInterval(3600))
        XCTAssertEqual(LiveActivityFreshness.staleDate(resetsAt: now.addingTimeInterval(1800), checkedAt: now), now.addingTimeInterval(1800))
    }

    func testStaleBeforeTheResetIsShownApartFromResetAwaitingAReading() {
        let reset = now.addingTimeInterval(4 * 3600)
        let state = SessionActivityState(used: 64, resetsAt: reset, isStale: false, checkedAt: now)
        let live = state.shown(isStale: false, now: now.addingTimeInterval(600))
        XCTAssertFalse(live.isStale)
        let aged = state.shown(isStale: true, now: now.addingTimeInterval(3600))
        XCTAssertTrue(aged.isStale)
        XCTAssertNotEqual(aged.awaitingReading, true, "Not reset: the last percentage, faded")
        XCTAssertTrue(aged.isStaleBeforeReset)
        XCTAssertEqual(aged.used, 64)
        let agedUnmarked = state.shown(isStale: false, now: now.addingTimeInterval(3700))
        XCTAssertTrue(agedUnmarked.isStaleBeforeReset, "Over an hour old even before ActivityKit marks it")
        let reset1 = state.shown(isStale: true, now: reset)
        XCTAssertEqual(reset1.awaitingReading, true)
        XCTAssertFalse(reset1.isStaleBeforeReset)
        let earlier = SessionActivityState(used: 64, resetsAt: reset, isStale: false)
        XCTAssertEqual(earlier.shown(isStale: true, now: now).awaitingReading, true,
                       "An earlier activity went stale only at its reset, so stale still means reset there")
    }

    func testALiveActivityIsUpdatedForANewerCheckOnceItHasMovedAFewMinutes() {
        let old = SessionActivityState(used: 50, resetsAt: now.addingTimeInterval(3600), isStale: false, checkedAt: now)
        var same = old
        same.checkedAt = now.addingTimeInterval(60)
        XCTAssertFalse(LiveActivityFreshness.needsUpdate(from: old, to: same))
        same.checkedAt = now.addingTimeInterval(5 * 60)
        XCTAssertTrue(LiveActivityFreshness.needsUpdate(from: old, to: same), "Moves the stale date")
        var moved = old
        moved.used = 51
        XCTAssertTrue(LiveActivityFreshness.needsUpdate(from: old, to: moved))
        var earlier = old
        earlier.checkedAt = nil
        XCTAssertTrue(LiveActivityFreshness.needsUpdate(from: earlier, to: old), "An earlier activity gets its check")
    }

    // MARK: 6. Watch payload

    /// Every provider Tokenroom reads, each with a session, a week, and a model's week, a
    /// week of hourly history for each, as a Mac would send them, plus the paired phone's own.
    private func nineteenProviders() -> ReadingCache {
        let hourStart = UsageHistory.hourStart(now)
        let items = Provider.allCases.map { key -> ReadingCache.Item in
            let windows = [
                RelayWindow(id: "session", kind: "session", title: "5-hour", used: 37.5, resetsAt: now.addingTimeInterval(2 * 3600), periodSec: 5 * 3600,
                            startsAt: now.addingTimeInterval(-3 * 3600), pace: RelayPace(runsOutAt: now.addingTimeInterval(4 * 3600))),
                RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 61.25, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400,
                            startsAt: now.addingTimeInterval(-4 * 86_400), amount: QuotaAmount(used: 61.25, limit: 100, remaining: 38.75, unit: "usd")),
                RelayWindow(id: "weekly-model", kind: "weekly", title: "Weekly · model", used: 12, resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400),
            ]
            let provider = RelayProvider(id: key.rawValue, name: key.displayName, shortName: key.shortName, monogram: "XY", tint: "#123456", state: "live",
                                         message: nil, checkedAt: now, fetchedAt: now, plan: "Max 20x", primaryWindowID: "weekly", windows: windows)
            var history: [String: UsageHistory] = [:]
            for window in windows {
                var week = UsageHistory(endingAt: now)
                for hour in 0..<UsageHistory.capacity {
                    let date = week.start.addingTimeInterval(Double(hour) * UsageHistory.step)
                    week.record(Double((hour * 7 + window.id.count) % 100), at: date)
                    // Balances keep the amount left each hour too.
                    if key.category == .apiBalance, window.id == "weekly" {
                        week.recordAmount(Double(10_000 - hour * 13) / 100, unit: "usd", at: date)
                    }
                }
                _ = week.recordResetTime(now.addingTimeInterval(-86_400), at: hourStart)
                history[window.id] = week
            }
            return ReadingCache.Item(provider: provider, source: "Mac", history: history, origin: .mac, sourceID: "mac-source")
        }
        let mac = RelayMerge.Source(id: "mac-source", label: "Mac", envelope: RelayEnvelope(producer: "mac", appVersion: "2.6.0", checkedAt: now, providers: items.map(\.provider)), kind: .mac)
        let phone = RelayMerge.Source(id: "phone-source", label: "This iPhone", envelope: RelayEnvelope(producer: "iphone", appVersion: "1.3.0", checkedAt: now, providers: Array(items.prefix(5).map(\.provider))), kind: .thisPhone)
        var cache = ReadingCache(savedAt: now, isSample: false, items: items)
        cache.relaySnapshot = .init(checkedAt: now, sources: [ReadingCache.SourceSnapshot(mac)])
        cache.localSource = ReadingCache.SourceSnapshot(phone)
        return cache
    }

    func testTheWatchPayloadFitsIn48KBWithEveryProviderAndItsMembership() throws {
        let cache = nineteenProviders()
        XCTAssertEqual(cache.items.count, 19)
        let whole = try RelayEnvelope.encoder.encode(cache)
        XCTAssertGreaterThan(whole.count, WatchHandoff.payloadLimit, "The fixture is over the limit with a whole week")
        let encoded = try XCTUnwrap(WatchHandoff.encodedReadings(cache))
        XCTAssertLessThanOrEqual(encoded.data.count, WatchHandoff.payloadLimit)
        XCTAssertFalse(encoded.isOverLimit)
        let hours = try XCTUnwrap(encoded.historyHours, "History was cut")
        XCTAssertEqual(hours, 48, "To two days of hourly buckets, for this fixture")
        let sent = try RelayEnvelope.decoder.decode(ReadingCache.self, from: encoded.data)
        XCTAssertEqual(sent.items.map(\.id), cache.items.map(\.id), "Every provider")
        XCTAssertEqual(sent.items.map(\.provider), cache.items.map(\.provider), "Readings as they were")
        XCTAssertEqual(sent.localSource, cache.localSource, "The phone's own membership")
        XCTAssertEqual(sent.relaySnapshot, cache.relaySnapshot, "iCloud's membership")
        let original = try XCTUnwrap(cache.items.first?.history["weekly"])
        let trimmed = try XCTUnwrap(sent.items.first?.history["weekly"])
        if hours > 0 {
            XCTAssertEqual(trimmed.used, Array(original.used.suffix(hours)), "The latest hours")
            XCTAssertEqual(trimmed.end, original.end)
            XCTAssertEqual(trimmed.amounts, original.amounts.map { Array($0.suffix(hours)) })
        }
        let context = WatchHandoff.context(readings: encoded.data, connectAvailable: true)
        XCTAssertEqual(WatchHandoff.payload(in: context)?.cache.items.count, 19, "The Watch reads it")
        // A small cache goes whole.
        let small = cache.trimmingHistory(toLast: 0)
        XCTAssertNil(WatchHandoff.encodedReadings(small)?.historyHours)
    }

    func testAShortenedHistoryCanStillBeRecordedInto() {
        var week = UsageHistory(endingAt: now)
        week.record(30, at: now)
        var short = try? XCTUnwrap(week.trimmed(toLast: 48))
        XCTAssertEqual(short?.used.count, 48)
        XCTAssertEqual(short?.end, week.end)
        short?.record(45, at: now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(short?.used.count, UsageHistory.capacity, "Filled out to the week first")
        XCTAssertEqual(short?.points.last?.used, 45)
        XCTAssertEqual(short?.points.first?.used, 30)
        XCTAssertNil(week.trimmed(toLast: 0))
    }

    // MARK: 10. Sync health

    func testSyncHealthHoldsOnlyDatesAndCodes() throws {
        let defaults = makeDefaults()
        SyncHealthLog.record(.cloudRead, .ok, in: defaults, at: now)
        SyncHealthLog.record(.cloudRead, .timedOut, in: defaults, at: now.addingTimeInterval(60))
        SyncHealthLog.record(.handoffSend, .trimmed, in: defaults, at: now.addingTimeInterval(120))
        SyncHealthLog.record(.handoffReceive, .held, in: defaults, at: now.addingTimeInterval(180))
        let health = SyncHealth.load(from: defaults)
        XCTAssertEqual(health.entry(.cloudRead), SyncHealth.Entry(at: now.addingTimeInterval(60), code: .timedOut, lastOK: now))
        XCTAssertEqual(health.entry(.handoffSend)?.lastOK, now.addingTimeInterval(120), "Sent, trimmed, counts as sent")
        XCTAssertNil(health.entry(.handoffReceive)?.lastOK)
        XCTAssertNil(health.entry(.phoneReply))

        let data = try XCTUnwrap(defaults.data(forKey: SyncHealth.defaultsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["entries"])
        let entries = try XCTUnwrap(object["entries"] as? [String: [String: Any]])
        let channels = Set(SyncHealth.Channel.allCases.map(\.rawValue))
        let codes = Set(SyncHealth.Code.allCases.map(\.rawValue))
        for (channel, entry) in entries {
            XCTAssertTrue(channels.contains(channel), channel)
            XCTAssertTrue(Set(entry.keys).isSubset(of: ["at", "code", "lastOK"]), "\(entry.keys)")
            for (key, value) in entry {
                if key == "code" {
                    XCTAssertTrue(codes.contains(value as? String ?? ""), "An enum code, not free text: \(value)")
                } else {
                    XCTAssertTrue(value is NSNumber, "A date: \(value)")
                }
            }
        }
    }
}
