import CloudKit
import XCTest
@testable import Tokenroom

/// The shared logic the iPhone app, widgets, and Watch run, tested on the Mac.
final class MobileLogicTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
    private var suites: [String] = []

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    /// A throwaway stand-in for the App Group's defaults.
    private func makeDefaults() -> UserDefaults {
        // Named by the class and a count: macOS keeps an empty preferences file for every name.
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshot(_ provider: Provider = .claude, used: Double = 40, fetchedAt: Date? = nil) -> QuotaSnapshot {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 7 * 86_400)
        return try! QuotaSnapshot.headlined(by: [window], provider: provider, fetchedAt: fetchedAt ?? now)
    }

    // MARK: Status rules

    func testFailuresKeepTheLastReadingWhereItHelps() {
        let cached = snapshot(fetchedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(ProviderStatus.failure(.unreachable, cached: cached, lastChecked: nil, now: now), .stale(cached))
        XCTAssertEqual(ProviderStatus.failure(.unreachable, cached: nil, lastChecked: nil, now: now), .unreachable(cached: nil))
        XCTAssertEqual(ProviderStatus.failure(.expired("x"), cached: cached, lastChecked: now.addingTimeInterval(-3600), now: now), .expired("x", cached: cached))
        XCTAssertEqual(ProviderStatus.failure(.expired("x"), cached: cached, lastChecked: now.addingTimeInterval(-25 * 3600), now: now), .expired("x", cached: nil), "A day after expiry the reading is gone")
        XCTAssertEqual(ProviderStatus.failure(.rateLimited(until: now.addingTimeInterval(5)), cached: cached, lastChecked: nil, now: now), .rateLimited(until: now.addingTimeInterval(60), cached: cached))
        XCTAssertEqual(ProviderStatus.failure(.signedOut("hint"), cached: cached, lastChecked: nil, now: now), .signedOut("hint"))
        XCTAssertTrue(ProviderStatus.signedOut("hint").isDisconnected)
        XCTAssertFalse(ProviderStatus.stale(cached).isDisconnected)
    }

    func testRelayProviderCarriesReadingsAndStates() {
        let live = RelayProvider(provider: .claude, status: .live(snapshot()), checkedAt: now)
        XCTAssertEqual(live.state, "live")
        XCTAssertEqual(live.monogram, Provider.claude.monogram)
        XCTAssertEqual(live.primaryWindow?.used, 40)
        XCTAssertEqual(live.primaryWindow?.windowKind, .weekly)
        XCTAssertNil(live.message)
        XCTAssertFalse(live.isDisconnected)

        let signedOut = RelayProvider(provider: .claude, status: .signedOut(Provider.claude.signInHint), checkedAt: nil)
        XCTAssertEqual(signedOut.message, Provider.claude.signInHint)
        XCTAssertTrue(signedOut.isDisconnected)
        XCTAssertFalse(RelayProvider(provider: .claude, status: .expired("x", cached: snapshot()), checkedAt: nil).isDisconnected, "An expired session with a recent reading still shows it")
    }

    // MARK: Publishing

    func testPublishPolicy() {
        var policy = RelayPublishPolicy()
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter)), checkedAt: now)])
        XCTAssertTrue(policy.isDue(envelope, now: now), "The first reading always goes out")
        policy.didSend(envelope, at: now)
        XCTAssertFalse(policy.isDue(envelope, now: now.addingTimeInterval(8 * 60)), "Unchanged usage waits for the heartbeat")
        XCTAssertTrue(policy.isDue(envelope, now: now.addingTimeInterval(9 * 60)), "The heartbeat goes out with the Mac's next 10-minute check")

        let changed = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 60)), checkedAt: now)])
        XCTAssertFalse(policy.isDue(changed, now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(policy.isDue(changed, now: now.addingTimeInterval(5 * 60)))

        let crossed = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 82)), checkedAt: now)])
        XCTAssertFalse(policy.isDue(crossed, now: now.addingTimeInterval(59)))
        XCTAssertTrue(policy.isDue(crossed, now: now.addingTimeInterval(61)), "Crossing 80% goes out after a minute, like a status change")
        var almost = RelayPublishPolicy()
        let below = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 79.6)), checkedAt: now)])
        let above = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 80.3)), checkedAt: now)])
        almost.didSend(below, at: now)
        XCTAssertTrue(almost.isDue(above, now: now.addingTimeInterval(61)), "Even when both round to 80%")

        let expired = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .expired("x", cached: nil), checkedAt: now)])
        XCTAssertTrue(policy.isDue(expired, now: now.addingTimeInterval(61)), "A status change goes out after a minute")
        policy.reset()
        XCTAssertTrue(policy.isDue(envelope, now: now.addingTimeInterval(1)))
    }

    func testPublishingGoesOnWhenTheClockIsSetBack() {
        var policy = RelayPublishPolicy()
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter)), checkedAt: now)])
        policy.didSend(envelope, at: now)
        let dayEarlier = now.addingTimeInterval(-86_400)
        XCTAssertTrue(policy.isDue(envelope, now: dayEarlier), "Set back a day, sending doesn't wait a day")
        policy.didSend(envelope, at: dayEarlier)
        XCTAssertFalse(policy.isDue(envelope, now: dayEarlier.addingTimeInterval(8 * 60)), "Then it counts from that send")
        XCTAssertTrue(policy.isDue(envelope, now: dayEarlier.addingTimeInterval(9 * 60)))
    }

    private func envelope(_ windows: [RelayWindow], extra: ExtraUsage? = nil) -> RelayEnvelope {
        let provider = RelayProvider(id: "x", name: "X", shortName: "X", monogram: "X", tint: "#000000", state: "live", checkedAt: now, fetchedAt: now,
                                     primaryWindowID: windows.first?.id, windows: windows, extra: extra)
        return RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [provider])
    }

    private func balance(_ remaining: Double) -> RelayWindow {
        RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 0, amount: QuotaAmount(remaining: remaining, unit: "usd"), metered: false)
    }

    func testAmountsCountAsTheyreShown() {
        let base = envelope([balance(12.40)]).materialHash
        XCTAssertNotEqual(envelope([balance(12.39)]).materialHash, base, "A balance a cent lower reaches the other devices")
        XCTAssertEqual(envelope([balance(12.401)]).materialHash, base, "Less than a cent isn't shown, so it isn't a change")

        let spend = RelayWindow(id: "spend-month", kind: "monthly", title: "This month", used: 0, resetsAt: now.addingTimeInterval(5 * 86_400), amount: QuotaAmount(used: 312.5, unit: "usd"), metered: false)
        var more = spend
        more.amount?.used = 312.75
        XCTAssertNotEqual(envelope([more]).materialHash, envelope([spend]).materialHash, "Nor does a month's spend")

        let requests = RelayWindow(id: "premium", kind: "monthly", title: "Premium requests", used: 83, resetsAt: now.addingTimeInterval(5 * 86_400), amount: QuotaAmount(used: 249, limit: 300, remaining: 51, unit: "requests"))
        var another = requests
        another.amount = QuotaAmount(used: 250, limit: 300, remaining: 50, unit: "requests")
        XCTAssertNotEqual(envelope([another]).materialHash, envelope([requests]).materialHash, "\"250 of 300\" shows though the percent rounds the same")

        let extra = ExtraUsage(title: "Extra usage", amount: QuotaAmount(used: 5, limit: 10, remaining: 5, unit: "usd"))
        var lower = extra
        lower.amount.remaining = 4.99
        XCTAssertNotEqual(envelope([balance(12.4)], extra: lower).materialHash, envelope([balance(12.4)], extra: extra).materialHash, "Extra usage counts to the cent too")
        var off = extra
        off.isEnabled = false
        XCTAssertNotEqual(envelope([balance(12.4)], extra: off).materialHash, envelope([balance(12.4)], extra: extra).materialHash)

        // Still at most every five minutes, like any other change.
        var policy = RelayPublishPolicy()
        policy.didSend(envelope([balance(12.4)]), at: now)
        XCTAssertFalse(policy.isDue(envelope([balance(12.39)]), now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(policy.isDue(envelope([balance(12.39)]), now: now.addingTimeInterval(5 * 60)))
    }

    func testAMeasuredRunOutGoesOutOnceItMovesAnHour() {
        func weekly(_ pace: RelayPace?, resetsIn reset: TimeInterval = 3 * 86_400) -> RelayWindow {
            RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 70, resetsAt: now.addingTimeInterval(reset), periodSec: 7 * 86_400, pace: pace)
        }
        func runsOut(in minutes: Double, resetsIn reset: TimeInterval = 3 * 86_400) -> RelayEnvelope {
            envelope([weekly(RelayPace(runsOutAt: now.addingTimeInterval(minutes * 60)), resetsIn: reset)])
        }
        XCTAssertEqual(runsOut(in: 125).materialHash, runsOut(in: 185).materialHash, "Widgets don't draw it; the publish policy follows it")

        var policy = RelayPublishPolicy()
        policy.didSend(runsOut(in: 125), at: now)
        XCTAssertFalse(policy.isDue(runsOut(in: 170), now: now.addingTimeInterval(8 * 60)), "Drifting under an hour isn't a change")
        XCTAssertFalse(policy.isDue(runsOut(in: 185), now: now.addingTimeInterval(4 * 60)))
        XCTAssertTrue(policy.isDue(runsOut(in: 185), now: now.addingTimeInterval(5 * 60)), "A run-out an hour later goes out without waiting for the heartbeat")
        XCTAssertTrue(policy.isDue(envelope([weekly(RelayPace(runsOutAt: nil))]), now: now.addingTimeInterval(5 * 60)), "Running out, or not")
        XCTAssertTrue(policy.isDue(envelope([weekly(nil)]), now: now.addingTimeInterval(5 * 60)), "No longer measured")

        // Wobbling across an hour boundary, or around the reset, doesn't go out every 5 minutes.
        policy.didSend(runsOut(in: 175), at: now)
        XCTAssertFalse(policy.isDue(runsOut(in: 185), now: now.addingTimeInterval(8 * 60)))
        XCTAssertFalse(policy.isDue(runsOut(in: 165), now: now.addingTimeInterval(8 * 60)))
        policy.didSend(envelope([weekly(RelayPace(runsOutAt: nil), resetsIn: 3 * 3600)]), at: now)
        XCTAssertFalse(policy.isDue(runsOut(in: 140, resetsIn: 3 * 3600), now: now.addingTimeInterval(8 * 60)), "Forty minutes before the reset is as good as lasting")
        XCTAssertTrue(policy.isDue(runsOut(in: 100, resetsIn: 3 * 3600), now: now.addingTimeInterval(8 * 60)))
    }

    // MARK: Ranking

    func testRankingPutsUrgentMeteredReadingsFirst() {
        func provider(_ name: String, used: Double, metered: Bool = true) -> RelayProvider {
            RelayProvider(id: name, name: name, shortName: name, monogram: "X", tint: "#000000", state: "live", checkedAt: now, fetchedAt: now,
                          primaryWindowID: "w", windows: [RelayWindow(id: "w", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(86_400), periodSec: 7 * 86_400, metered: metered)])
        }
        let calm = provider("Calm", used: 90)
        let urgent = provider("Urgent", used: 50)
        let balance = provider("Balance", used: 0, metered: false)
        let tie = provider("Also calm", used: 90)
        let paces: [String: Pace] = ["Urgent": Pace(verdict: .ahead, delta: 20, elapsedFraction: 0.3, resetsAt: now, runsOutAt: now, severity: .tight)]
        let sorted = UsageRanking.sorted([balance, calm, urgent, tie], provider: { $0 }, now: now, pace: { paces[$0.name] })
        XCTAssertEqual(sorted.map(\.name), ["Urgent", "Also calm", "Calm", "Balance"])
    }

    func testALimitReachedWithoutAResetRanksFirst() {
        func provider(_ name: String, _ window: RelayWindow, state: String = "live") -> RelayProvider {
            RelayProvider(id: name, name: name, shortName: name, monogram: "X", tint: "#000000", state: state, checkedAt: now, fetchedAt: now,
                          primaryWindowID: window.id, windows: [window])
        }
        let keyLimit = RelayWindow(id: "key", kind: "pool", title: "Key limit", used: 100)
        let spent = provider("Spent", keyLimit)
        // Halfway through its week at 55%: runs out in the last quarter.
        let weekly = provider("Weekly", RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 55, resetsAt: now.addingTimeInterval(3.5 * 86_400), periodSec: 7 * 86_400))
        let pace = { (reading: RelayProvider) in UsageRanking.pace(for: reading, history: nil, now: self.now) }
        XCTAssertEqual(pace(weekly)?.severity, .watch)
        XCTAssertNil(pace(spent), "No reset time, no pace")
        XCTAssertEqual(UsageRanking.sorted([weekly, spent], provider: { $0 }, now: now, pace: pace).map(\.name), ["Spent", "Weekly"])
        let stale = provider("Spent", keyLimit, state: "stale")
        XCTAssertEqual(UsageRanking.sorted([stale, weekly], provider: { $0 }, now: now, pace: pace).map(\.name), ["Weekly", "Spent"], "Like any stale reading, it has no urgency")
    }

    // MARK: Sample data

    func testSampleDataIsCompleteAndRanked() throws {
        let cache = SampleData.cache(now: now)
        XCTAssertTrue(cache.isSample)
        XCTAssertGreaterThanOrEqual(cache.items.count, 10)
        XCTAssertTrue(cache.items.allSatisfy { $0.provider.isLive && $0.source == SampleData.sourceLabel })
        XCTAssertEqual(Set(cache.items.map(\.id)).count, cache.items.count)
        XCTAssertEqual(cache.items.first?.id, Provider.openai.rawValue, "The sample that's ahead of pace leads")
        XCTAssertEqual(cache.items.last?.id, Provider.deepseek.rawValue, "A balance without a limit comes last")
        let claude = try XCTUnwrap(cache.items.first { $0.id == "claude" })
        let week = try XCTUnwrap(claude.history["weekly"])
        XCTAssertEqual(Double(week.used.last.flatMap { $0 } ?? 0), 64, accuracy: 1, "History ends at the current reading")
        XCTAssertNil(claude.history["session"], "Sessions are too short for a week's chart")
        XCTAssertEqual(SampleData.cache(now: now), cache, "The same moment gives the same samples")
    }

    // MARK: Widget cache

    func testReadingCacheRoundTripsAndIgnoresCheckTimes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        let cache = SampleData.cache(now: now)
        try cache.save(to: url)
        XCTAssertEqual(ReadingCache.load(from: url), cache)

        var rechecked = cache
        rechecked.savedAt = now.addingTimeInterval(600)
        rechecked.items[0].provider.checkedAt = now.addingTimeInterval(600)
        XCTAssertEqual(rechecked.materialHash, cache.materialHash, "Widgets only reload when a reading changes")
        rechecked.items[0].provider.windows[0].used += 5
        XCTAssertNotEqual(rechecked.materialHash, cache.materialHash)
        var spent = cache
        let deepseek = try XCTUnwrap(spent.items.firstIndex { $0.id == Provider.deepseek.rawValue })
        spent.items[deepseek].provider.windows[0].amount?.remaining? -= 0.01
        XCTAssertNotEqual(spent.materialHash, cache.materialHash, "A balance a cent lower reloads widgets and reaches the Watch")

        var newer = cache
        newer.v = ReadingCache.version + 1
        try newer.save(to: url)
        XCTAssertNil(ReadingCache.load(from: url), "A cache from a newer version isn't misread")
    }

    // MARK: Assembling readings for the app and widgets

    func testAssemblerMergesSourcesWithTheirOwnHistory() {
        let macProvider = RelayProvider(provider: .claude, status: .live(snapshot(.claude, used: 70)), checkedAt: now)
        let phoneProvider = RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 20)), checkedAt: now)
        let signedOut = RelayProvider(provider: .cursor, status: .signedOut("Sign in"), checkedAt: now)
        var week = UsageHistory(endingAt: now)
        week.record(70, at: now)
        let output = ReadingAssembler.assemble(
            sources: [
                RelayMerge.Source(id: "mac", label: "Mac", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [macProvider, signedOut])),
                RelayMerge.Source(id: "phone", label: "This iPhone", envelope: RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [phoneProvider])),
            ],
            histories: ["mac": RelayHistory(series: ["claude/weekly": week, "cursor/weekly": week])],
            now: now
        )
        XCTAssertEqual(output.connected.map(\.id), ["claude", "openrouter"])
        XCTAssertEqual(output.connected.map(\.source), ["Mac", "This iPhone"])
        XCTAssertEqual(output.connected[0].history["weekly"], week, "Each reading keeps its own collector's history")
        XCTAssertTrue(output.connected[1].history.isEmpty)
        XCTAssertEqual(output.disconnected.map(\.id), ["cursor"])
    }

    /// Mac A is signed in to Claude and asleep for two hours; Mac B isn't, and says so now. Claude
    /// stays, faded, on the iPhone, its widgets, and the Watch, rather than moving to Not connected.
    func testACollectorThatIsntSignedInDoesntHideAnotherCollectorsReading() {
        let asleep = now.addingTimeInterval(-2 * 3600)
        let reading = RelayProvider(provider: .claude, status: .live(snapshot(.claude, used: 70, fetchedAt: asleep)), checkedAt: asleep)
        let macA = RelayMerge.Source(id: "mac-a", label: "Studio", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: asleep, providers: [reading]))
        for status in [ProviderStatus.signedOut("Sign in with claude login."), .notEntitled("Not on a plan."), .unreachable(cached: nil)] {
            let missing = RelayProvider(provider: .claude, status: status, checkedAt: nil)
            let macB = RelayMerge.Source(id: "mac-b", label: "Laptop", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [missing]))
            let output = ReadingAssembler.assemble(sources: [macA, macB], histories: [:], now: now)
            XCTAssertEqual(output.connected.map(\.id), ["claude"], "\(status.relayState) from Mac B")
            XCTAssertEqual(output.connected.first?.source, "Studio")
            XCTAssertEqual(output.connected.first?.provider.state, "stale")
            XCTAssertTrue(output.disconnected.isEmpty)
            let watch = RelayReadings.cache(from: CloudRelay.Contents(sources: [
                CloudRelay.Source(id: "mac-a", kind: "mac", label: "Studio", modifiedAt: asleep, envelope: macA.envelope, needsNewerApp: false),
                CloudRelay.Source(id: "mac-b", kind: "mac", label: "Laptop", modifiedAt: now, envelope: macB.envelope, needsNewerApp: false),
            ], histories: [:]), now: now)
            XCTAssertEqual(watch.items.map(\.id), ["claude"], "The Watch keeps it too")
        }

        // A live reading still beats it, and among readings with nothing to show the newest wins.
        let fresh = RelayProvider(provider: .claude, status: .live(snapshot(.claude, used: 75)), checkedAt: now.addingTimeInterval(-60))
        let live = RelayMerge.Source(id: "mac-b", label: "Laptop", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [fresh]))
        XCTAssertEqual(ReadingAssembler.assemble(sources: [macA, live], histories: [:], now: now).connected.first?.source, "Laptop")
        let older = RelayMerge.Source(id: "mac-a", label: "Studio", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: asleep, providers: [
            RelayProvider(provider: .claude, status: .signedOut("Older"), checkedAt: nil),
        ]))
        let newer = RelayMerge.Source(id: "mac-b", label: "Laptop", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [
            RelayProvider(provider: .claude, status: .expired("Newer", cached: nil), checkedAt: nil),
        ]))
        XCTAssertEqual(ReadingAssembler.assemble(sources: [older, newer], histories: [:], now: now).disconnected.map(\.provider.message), ["Newer"])

        // One dated ahead of the clock (a collector's clock running fast) is as new as anything.
        let ahead = RelayProvider(provider: .claude, status: .stale(snapshot(.claude, used: 10, fetchedAt: now.addingTimeInterval(360))), checkedAt: now.addingTimeInterval(360))
        let real = RelayProvider(provider: .claude, status: .stale(snapshot(.claude, used: 55, fetchedAt: asleep)), checkedAt: asleep)
        let entries = RelayMerge.entries(from: [
            RelayMerge.Source(id: "a", label: "A", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [ahead])),
            RelayMerge.Source(id: "b", label: "B", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [real])),
        ], now: now)
        XCTAssertEqual(entries.first?.sourceLabel, "A")
    }

    /// Mac A's reading is two hours old; Mac B has just found Claude signed out. The faded reading
    /// stays, and says what Mac B found, so "sign in" isn't lost for a week. Mac B's status from
    /// before Mac A's reading says nothing new.
    func testANewerSignInStatusShowsOnAnotherCollectorsFadedReading() {
        let asleep = now.addingTimeInterval(-2 * 3600)
        let reading = RelayProvider(provider: .claude, status: .live(snapshot(.claude, used: 70, fetchedAt: asleep)), checkedAt: asleep)
        let macA = RelayMerge.Source(id: "mac-a", label: "Studio", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: asleep, providers: [reading]))
        for status in [ProviderStatus.signedOut("Sign in with claude login."), .expired("Session expired. Sign in with claude login again.", cached: nil), .notEntitled("Not on a plan.")] {
            let missing = RelayProvider(provider: .claude, status: status, checkedAt: nil)
            let newer = RelayMerge.Source(id: "mac-b", label: "Laptop", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [missing]))
            let shown = ReadingAssembler.assemble(sources: [macA, newer], histories: [:], now: now).connected.first
            XCTAssertEqual(shown?.source, "Studio", "The reading stays")
            XCTAssertEqual(shown?.provider.primaryWindow?.used, 70)
            XCTAssertFalse(shown?.provider.isLive ?? true, "Faded")
            XCTAssertEqual(shown?.provider.message, missing.message, "\(status.relayState): what the newer check found")
        }
        let earlier = RelayMerge.Source(id: "mac-b", label: "Laptop", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now.addingTimeInterval(-3 * 3600), providers: [
            RelayProvider(provider: .claude, status: .signedOut("Sign in with claude login."), checkedAt: nil),
        ]))
        XCTAssertEqual(ReadingAssembler.assemble(sources: [macA, earlier], histories: [:], now: now).connected.first?.provider.message,
                       "Last successful check 2h ago.", "Signed out before Mac A's reading: nothing new")
    }

    /// A key provider this launch hasn't checked, with nothing saved for it, isn't listed as not
    /// connected without a reason, and doesn't hide another collector's reason.
    func testAProviderWaitingForItsFirstCheckIsNeitherConnectedNorNot() {
        let waiting = RelayProvider(provider: .openrouter, status: .loading, checkedAt: nil)
        XCTAssertTrue(waiting.isAwaitingFirstReading)
        let phone = RelayMerge.Source(id: "phone", label: "This iPhone", envelope: RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [waiting]))
        let alone = ReadingAssembler.assemble(sources: [phone], histories: [:], now: now)
        XCTAssertTrue(alone.connected.isEmpty)
        XCTAssertTrue(alone.disconnected.isEmpty, "Not under Not connected, with nothing to say why")

        let refused = RelayProvider(provider: .openrouter, status: .expired("Key refused.", cached: nil), checkedAt: nil)
        let mac = RelayMerge.Source(id: "mac", label: "Mac", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now.addingTimeInterval(-600), providers: [refused]))
        XCTAssertEqual(ReadingAssembler.assemble(sources: [mac, phone], histories: [:], now: now).disconnected.map(\.provider.message), ["Key refused."])
        XCTAssertFalse(refused.isAwaitingFirstReading)
        XCTAssertFalse(RelayProvider(provider: .claude, status: .live(snapshot()), checkedAt: now).isAwaitingFirstReading)
    }

    func testTheWatchReadsEveryCollectorFromICloud() {
        let mac = RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .claude, status: .live(snapshot(.claude, used: 70)), checkedAt: now)])
        let phone = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [RelayProvider(provider: .openrouter, status: .live(snapshot(.openrouter, used: 20)), checkedAt: now)])
        let contents = CloudRelay.Contents(
            sources: [
                CloudRelay.Source(id: "src-mac", kind: "mac", label: "Mac", modifiedAt: now, envelope: mac, needsNewerApp: false),
                CloudRelay.Source(id: "src-phone", kind: "iphone", label: "iPhone", modifiedAt: now, envelope: phone, needsNewerApp: false),
                CloudRelay.Source(id: "src-future", kind: "mac", label: "Mac", modifiedAt: now, envelope: nil, needsNewerApp: true),
            ],
            histories: [:]
        )
        let cache = RelayReadings.cache(from: contents, now: now)
        XCTAssertEqual(cache.items.map(\.id), ["claude", "openrouter"], "The iPhone's own readings reach the Watch too")
        XCTAssertEqual(cache.items.map(\.source), ["Mac", "iPhone"])
        XCTAssertFalse(cache.isSample)
    }

    func testReadingsRollOverAtReset() throws {
        let item = try XCTUnwrap(SampleData.cache(now: now).items.first { $0.id == "claude" })
        let session = try XCTUnwrap(item.provider.windows.first { $0.id == "session" }?.resetsAt)
        let rolled = item.rolledOver(at: session.addingTimeInterval(1))
        let rolledSession = try XCTUnwrap(rolled.provider.windows.first { $0.id == "session" })
        XCTAssertEqual(rolledSession.used, item.provider.windows.first { $0.id == "session" }?.used, "Keep the measured value until a new reading confirms it")
        XCTAssertEqual(rolledSession.resetsAt, session)
        XCTAssertEqual(ReadingText.reset(rolledSession, now: session), "Reset · awaiting reading")
        XCTAssertEqual(ReadingText.headline(rolledSession, now: session), "—")
        XCTAssertNil(UsageRanking.pace(for: rolledSession, isStale: false, history: nil, now: session))
        XCTAssertEqual(rolled.provider.windows.first { $0.id == "weekly" }?.used, 64, "Windows that haven't reset keep their reading")
        XCTAssertEqual(item.rolledOver(at: now), item)
    }

    func testWhichWindowALiveActivityFollows() throws {
        let cache = SampleData.cache(now: now)
        let claude = try XCTUnwrap(cache.items.first { $0.id == "claude" }).provider
        XCTAssertEqual(claude.windowToFollow(now: now)?.id, "session", "A session resetting soon")
        let grok = try XCTUnwrap(cache.items.first { $0.id == "grok" }).provider
        XCTAssertNil(grok.windowToFollow(now: now), "A weekly window days from its reset isn't worth one")

        let nearlySpent = RelayProvider(id: "x", name: "X", shortName: "X", monogram: "X", tint: "#000000", state: "live", primaryWindowID: "weekly", windows: [
            RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 91, resetsAt: now.addingTimeInterval(5 * 3600)),
            RelayWindow(id: "light", kind: "weekly", title: "Other", used: 20, resetsAt: now.addingTimeInterval(3600)),
        ])
        XCTAssertEqual(nearlySpent.windowToFollow(now: now)?.id, "weekly", "The last hours of a nearly spent week")
    }

    // MARK: Deep links and text

    func testDeepLinksRoundTrip() {
        for link in [DeepLink.provider("claude"), .provider("kimiCode"), .news, .settings, .keys, .alerts] {
            XCTAssertEqual(DeepLink(link.url), link)
        }
        XCTAssertNil(DeepLink(URL(string: "https://example.com/provider/claude")!))
        XCTAssertNil(DeepLink(URL(string: "tokenroom://provider/")!))
    }

    func testReadingText() {
        let balance = RelayWindow(id: "b", kind: "pool", title: "Balance", used: 0, amount: QuotaAmount(remaining: 12.4, unit: "usd"), metered: false)
        XCTAssertEqual(ReadingText.headline(balance), "\(12.4.formatted(.currency(code: "USD"))) left")
        let meter = RelayWindow(id: "w", kind: "weekly", title: "Weekly", used: 63.6, resetsAt: now.addingTimeInterval(2 * 86_400 + 3600))
        XCTAssertEqual(ReadingText.headline(meter, now: now), "64%")
        XCTAssertEqual(ReadingText.caption(meter, now: now), "Weekly · resets in 2d 1h")
        XCTAssertEqual(ReadingText.amountDetail(QuotaAmount(used: 249, limit: 300, remaining: 51, unit: "requests")), "249 of 300 requests")
        XCTAssertEqual(ReadingText.amountDetail(QuotaAmount(used: 312.5, unit: "usd")), "\(312.5.formatted(.currency(code: "USD"))) spent")
    }

    // MARK: State shared with the widgets

    func testKeyFetchGateSpacesCallsFromTheLastAttempt() {
        let defaults = makeDefaults()
        let app = KeyFetchGate(defaults: defaults)
        XCTAssertFalse(app.isResting(.anthropicOrg, now: now))
        app.recordAttempt(.anthropicOrg, at: now)
        let widget = KeyFetchGate(defaults: defaults)
        XCTAssertTrue(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(14 * 60)), "A widget sees the app's call: Anthropic allows one every 15 minutes")
        XCTAssertFalse(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(15 * 60)))

        app.recordAttempt(.openrouter, at: now)
        XCTAssertFalse(app.isResting(.openrouter, now: now), "No spacing without a minimum interval")
    }

    func testKeyFetchGateHoldsOffAfterA429UntilCleared() {
        let gate = KeyFetchGate(defaults: makeDefaults())
        gate.block(.openrouter, until: now.addingTimeInterval(600))
        XCTAssertTrue(gate.isResting(.openrouter, now: now.addingTimeInterval(599)))
        XCTAssertFalse(gate.isResting(.openrouter, now: now.addingTimeInterval(600)))
        XCTAssertFalse(gate.isResting(.deepseek, now: now), "Only the provider that asked")

        gate.block(.openrouter, until: now.addingTimeInterval(600))
        gate.recordAttempt(.openrouter, at: now)
        gate.block(.openrouter, until: nil)
        XCTAssertFalse(gate.isResting(.openrouter, now: now.addingTimeInterval(1)), "A good answer clears the wait")
    }

    func testWidgetReloadLogCountsTheLastDayAndForgetsAfterTwo() {
        let defaults = makeDefaults()
        XCTAssertEqual(WidgetReloadLog.count(lastDayBefore: now, defaults: defaults), 0)
        for hoursAgo in [50.0, 30, 23, 1, 0] {
            WidgetReloadLog.record(at: now.addingTimeInterval(-hoursAgo * 3600), defaults: defaults)
        }
        XCTAssertEqual(WidgetReloadLog.count(lastDayBefore: now, defaults: defaults), 3)
        let kept = defaults.dictionary(forKey: WidgetReloadLog.defaultsKey) as? [String: [Double]]
        XCTAssertEqual(kept?.values.map(\.count).reduce(0, +), 4, "Older than two days is dropped")
    }

    func testWidgetsReloadHalfHourlyOnlyWhileAWindowIsBusy() {
        func item(used: Double, resetsIn hours: Double, live: Bool = true) -> ReadingCache.Item {
            let window = QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: used, resetsAt: now.addingTimeInterval(hours * 3600), windowSeconds: 5 * 3600)
            let snapshot = try! QuotaSnapshot.headlined(by: [window], provider: .claude, fetchedAt: now)
            return ReadingCache.Item(provider: RelayProvider(provider: .claude, status: live ? .live(snapshot) : .stale(snapshot), checkedAt: now), source: "Mac")
        }
        let hourly = now.addingTimeInterval(3600)
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item(used: 40, resetsIn: 3)]), hourly, "Calm readings reload hourly")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item(used: 85, resetsIn: 3)]), now.addingTimeInterval(1800), "At 80% or more and resetting within 12 hours, every half hour")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item(used: 85, resetsIn: 20 * 24)]), hourly, "A month-long budget at 85% doesn't hurry")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item(used: 85, resetsIn: -1)]), hourly, "Nor a window that has already reset")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: [item(used: 85, resetsIn: 3, live: false)]), hourly, "Nor a reading that isn't live")
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: []), hourly)
        XCTAssertLessThan(24 * 3600 / WidgetSchedule.calmInterval, 40, "A calm day stays under WidgetKit's budget")
    }

    /// A reading saved live, from a Mac that stopped checking three hours ago: stale as shown, so
    /// widgets don't reload half-hourly for it, on the iPhone as on the Watch.
    func testWidgetsJudgeTheReloadByTheReadingAsShownNow() throws {
        let checked = now.addingTimeInterval(-3 * 3600)
        let window = QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 85, resetsAt: now.addingTimeInterval(2 * 3600), windowSeconds: 5 * 3600)
        let snapshot = try QuotaSnapshot.headlined(by: [window], provider: .claude, fetchedAt: checked)
        let item = ReadingCache.Item(provider: RelayProvider(provider: .claude, status: .live(snapshot), checkedAt: checked), source: "Mac")
        let cache = ReadingCache(savedAt: now.addingTimeInterval(-60), isSample: false, items: [item])
        XCTAssertEqual(WidgetSchedule.nextReload(after: now, items: cache.items), now.addingTimeInterval(1800), "Saved live, it still says live")
        XCTAssertGreaterThan(cache.nextReload(after: now, reloads: 0), now.addingTimeInterval(1800))
    }

    /// The note under a widget's rows names the window its row doesn't lead with: picked with
    /// the reading's history, as the row picks it.
    func testAWidgetsNoteDoesntRepeatItsRow() throws {
        let weeklyWindow = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(36 * 3600), windowSeconds: 7 * 86_400)
        let session = QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: 55, resetsAt: now.addingTimeInterval(2 * 3600), windowSeconds: 5 * 3600)
        let snapshot = try QuotaSnapshot.headlined(by: [weeklyWindow, session], provider: .claude, fetchedAt: now)
        let provider = RelayProvider(provider: .claude, status: .live(snapshot), checkedAt: now)
        var weekly = UsageHistory(endingAt: now)
        for (index, used) in [38, 40, 42, 44, 46, 48, 50].enumerated() { weekly.used[UsageHistory.capacity - 7 + index] = UInt8(used) }
        let item = ReadingCache.Item(provider: provider, source: "This iPhone", history: ["weekly": weekly])
        XCTAssertEqual(provider.primaryWindow?.id, "weekly")
        XCTAssertEqual(provider.leadWindow(now: now, history: item.history)?.id, "weekly", "Rising two points an hour, the week runs out first")
        XCTAssertEqual(ReadingText.attention(provider, now: now), "Weekly 50%", "Without the history, it would repeat the row")
        XCTAssertNil(item.attention(now: now))
    }

    // MARK: iCloud failures

    func testRelayErrorPolicy() {
        func outcome(_ error: Error) -> RelayErrorPolicy.Outcome {
            RelayErrorPolicy.outcome(for: error, defaultRetry: 300)
        }
        XCTAssertEqual(outcome(CKError(.notAuthenticated)), .noAccount)
        XCTAssertEqual(outcome(CancellationError()), .cancelled, "A refresh that gave way to a newer one isn't a failure")
        XCTAssertEqual(outcome(CKError(.operationCancelled)), .cancelled)
        XCTAssertEqual(outcome(CKError(.missingEntitlement)), .unavailable)
        XCTAssertEqual(outcome(CKError(.permissionFailure)), .unavailable)
        guard case .paused = outcome(CKError(.quotaExceeded)) else { return XCTFail("A full iCloud needs the user") }
        guard case .paused = outcome(CKError(.userDeletedZone)) else { return XCTFail("Deleted data needs the user") }
        guard case .retry(let asked, _) = outcome(CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 42.0])) else { return XCTFail("Rate limits retry") }
        XCTAssertEqual(asked, 42, "iCloud's own wait wins")
        guard case .retry(let busy, _) = outcome(CKError(.zoneBusy)) else { return XCTFail("A busy zone retries") }
        XCTAssertEqual(busy, 300)
        guard case .retry(let offline, _) = outcome(CKError(.networkUnavailable)) else { return XCTFail("Offline retries") }
        XCTAssertEqual(offline, 300)
        guard case .retry(let container, _) = outcome(CKError(.badContainer, userInfo: [CKErrorRetryAfterKey: 30.0])) else { return XCTFail("A new container retries") }
        XCTAssertEqual(container, 300, "A new container gets at least the usual wait")
        XCTAssertEqual(outcome(CKError(.unknownItem)), .failed("Couldn't reach iCloud."))
        XCTAssertEqual(outcome(URLError(.notConnectedToInternet)), .failed("Couldn't reach iCloud."))

        XCTAssertFalse(RelayErrorPolicy.Outcome.failed("x").stopsBatch, "One bad record doesn't stop the rest")
        XCTAssertTrue(outcome(CKError(.zoneBusy)).stopsBatch)
        XCTAssertTrue(RelayErrorPolicy.Outcome.noAccount.stopsBatch)
    }

    /// Signed in, but iCloud can't be used now: that's said as it is, and only a missing account
    /// asks the user to sign in.
    func testAnICloudAccountThatCantBeUsedNowIsntSignedOut() {
        XCTAssertNil(RelayErrorPolicy.unusableAccount(.available))
        XCTAssertNil(RelayErrorPolicy.unusableAccount(.noAccount), "Signed out starts afresh")
        XCTAssertEqual(RelayErrorPolicy.unusableAccount(.couldNotDetermine), "Couldn't reach iCloud.")
        for status in [CKAccountStatus.couldNotDetermine, .temporarilyUnavailable, .restricted] {
            let message = RelayErrorPolicy.unusableAccount(status)
            XCTAssertEqual(message?.hasPrefix("Couldn't"), true, "\(status.rawValue)")
            XCTAssertFalse(message?.localizedCaseInsensitiveContains("sign in") ?? true, "\(status.rawValue)")
        }
        XCTAssertNotEqual(RelayErrorPolicy.unusableAccount(.temporarilyUnavailable), RelayErrorPolicy.unusableAccount(.restricted))
    }

    // MARK: Nothing secret leaves the device

    func testNoKeyMaterialReachesAnyRecord() async throws {
        let secret = "tr-test-QXJ7ZKP9WM"
        let body = Data(#"{"data":{"label":"sk-or-v1-abc...xyz","limit":50,"limit_remaining":12.8,"limit_reset":"monthly","usage":37.2,"is_free_tier":false}}"#.utf8)
        StubURLProtocol.handler = { _ in (200, body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))

        let keys = APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).", keychain: FakeKeychain().operations, usesDataProtection: false)
        defer { try? keys.remove(for: .openrouter) }
        try keys.save(secret, for: .openrouter, region: nil)
        let snapshot = try await APIKeyClient(provider: .openrouter, keys: keys).fetch().get()
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)", "The key is used for the request")

        let history = await MainActor.run { () -> RelayHistory in
            let store = HistoryStore(directory: nil)
            store.record(snapshot)
            return store.relayHistory(for: [.openrouter])
        }
        let provider = RelayProvider(provider: .openrouter, status: .live(snapshot), checkedAt: now)
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [provider])
        let cache = ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: provider, source: "This iPhone", history: history.series)])
        // An alert from the same reading, as its Event record carries it, and the shared choices.
        var calm = provider, busy = provider
        calm.windows[0].used = 10
        busy.windows[0].used = 85
        let alerts = AlertRules.alerts(previous: calm, current: busy, preferences: AlertPreferences(), now: now)
        XCTAssertFalse(alerts.isEmpty)
        let events = alerts.map { [$0.id, $0.provider, $0.title, $0.body, $0.key, $0.shownKey].joined(separator: "|") }
        let payloads = [try envelope.encoded(), try history.encoded(), try RelayEnvelope.encoder.encode(cache), try RelayEnvelope.encoder.encode(AlertPreferences())]
            .map { String(decoding: $0, as: UTF8.self) } + events
        for payload in payloads {
            XCTAssertFalse(payload.contains("QXJ7"), "No part of the key")
            XCTAssertFalse(payload.contains("ZKP9"), "Not even its last four characters")
            XCTAssertFalse(payload.contains("sk-or"), "Nor the key's label from the response")
            XCTAssertFalse(payload.localizedCaseInsensitiveContains("bearer"))
        }
        XCTAssertTrue(payloads[0].contains("openrouter"), "The reading itself is there")
    }
}
