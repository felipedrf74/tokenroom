import XCTest
@testable import Tokenroom

/// The News, Skills and Following reliability decision of 7 November 2026
/// (`docs/news-reliability-council-20261107.md`): owner cancellation, waiting follow-ups, cadence
/// tiers, background ordering, the Mac's News loop, Skills persistence, and new sources.
final class NewsReliabilityTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_794_000_000) // 7 November 2026

    override func tearDown() {
        suites.forEach(TestDefaults.remove)
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let (name, defaults) = TestDefaults.make(owner: "NewsReliability", index: suites.count)
        suites.append(name)
        return defaults
    }

    private func folder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return folder
    }

    /// Until `condition` holds, or five seconds.
    @MainActor private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func useHangingNetwork() {
        HangingProtocol.started.value = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    private static let realFetch: @Sendable (NewsFetcher.Request) async -> NewsFetcher.Result = {
        await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now,
                                  forcedSources: $0.forcedSources, quietSources: $0.quietSources, isAllowed: $0.isAllowed, publish: $0.publish)
    }

    private func assertNoFailures(_ cache: NewsCache, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(cache.modelsFailedAt, file: file, line: line)
        XCTAssertNil(cache.modelsFailures, file: file, line: line)
        XCTAssertNil(cache.unreadable, file: file, line: line)
        XCTAssertTrue((cache.sourceChecks ?? [:]).values.allSatisfy { $0.failedAt == nil && $0.failures == nil }, file: file, line: line)
    }

    // MARK: 2. Owner-scoped, opt-in cancellation

    /// iPhone background expiry: the owner's cancellation takes its pass with it, and the requests
    /// it cut short count no failure.
    @MainActor func testACancellableOwnersPassEndsWithItAndRecordsNoFailure() async {
        useHangingNetwork()
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: Self.realFetch, notify: { _, _, _ in })
        news.followedSources = ["claude-code"]
        let owner = Task { await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, cancellable: true) }
        await eventually { HangingProtocol.started.value > 0 }
        XCTAssertGreaterThan(HangingProtocol.started.value, 0, "A request is out")
        owner.cancel()
        await owner.value
        await eventually { !news.isRefreshing }
        XCTAssertFalse(news.isRefreshing, "The pass ended with its owner")
        assertNoFailures(news.cache)
        XCTAssertNil(news.problem(for: .today))
    }

    /// The Mac going to sleep: the owner cancels whatever pass is under way, and what the owner
    /// queued behind it (its loop's check) goes with it. A manual request another caller queued
    /// (Check Now, a pull) still runs after it, and its caller waits until it has.
    @MainActor func testCancelPassStopsThePassAndWhatsQueued() async {
        let requests = LockedBox<[NewsFetcher.Request]>([]), sawCancel = LockedBox(false)
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
            requests.value.append(request)
            if requests.value.count == 1 {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                sawCancel.value = true
            }
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await eventually { requests.value.count == 1 }
        // The owner's loop comes due meanwhile, and the person presses Check Now.
        let loop = Task { await news.refresh(preferences: AlertPreferences(), notifies: false, forcedSources: ["devin"], waitsForFollowUp: true, cancellable: true) }
        for _ in 0..<20 { await Task.yield() }
        let manualDone = LockedBox(false)
        let manual = Task {
            await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, forcedSources: ["cursor"], waitsForFollowUp: true)
            manualDone.value = true
        }
        for _ in 0..<20 { await Task.yield() }
        loop.cancel()
        news.cancelPass()
        await first.value
        await loop.value
        await manual.value
        XCTAssertTrue(sawCancel.value)
        XCTAssertEqual(requests.value.count, 2, "The cancelled pass, then the manual request alone")
        XCTAssertEqual(requests.value.last?.forcedSources, ["cursor"], "The owner's queued check is dropped")
        XCTAssertEqual(requests.value.last?.maxAge, 0)
        XCTAssertTrue(manualDone.value, "Its caller waited for it")
        await eventually { !news.isRefreshing }
        XCTAssertFalse(news.isRefreshing)
    }

    /// A cancellable owner's own pass ending (the background refresh's time running out) leaves a
    /// follow-up a foreground pull asked for meanwhile.
    @MainActor func testACancelledOwnersPassLeavesAnotherCallersFollowUp() async {
        let requests = LockedBox<[NewsFetcher.Request]>([])
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
            requests.value.append(request)
            if requests.value.count == 1 { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) } }
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let owner = Task { await news.refresh(preferences: AlertPreferences(), notifies: false, cancellable: true) }
        await eventually { requests.value.count == 1 }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false) // A pull, not waiting.
        owner.cancel()
        await owner.value
        await eventually { requests.value.count == 2 && !news.isRefreshing }
        XCTAssertEqual(requests.value.map(\.maxAge), [nil, 0], "The pull's follow-up ran after the cancelled pass")
    }

    /// The Mac's sleep cancels its News loop and the pass that loop started.
    @MainActor func testSleepCancelsTheMacNewsLoopAndItsPass() async {
        let prefs = defaults()
        let calls = LockedBox(0), sawCancel = LockedBox(false)
        let news = NewsStore(defaults: prefs, directory: nil, fetch: { request in
            calls.value += 1
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            sawCancel.value = true
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let settings = AppSettings(defaults: prefs)
        settings.newsEnabled = true
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: folder()), news: news)
        store.waitForNextNewsCheck = { _ in try await Task.sleep(for: .seconds(3600)) }
        store.startNewsLoop()
        await eventually { calls.value == 1 }
        XCTAssertEqual(calls.value, 1, "The loop checks News by itself")
        store.willSleep()
        await eventually { sawCancel.value && !news.isRefreshing }
        XCTAssertTrue(sawCancel.value, "Sleep cancelled the pass")
        XCTAssertFalse(news.isRefreshing)
    }

    // MARK: 3 and 5. Requests during a pass wait for their follow-up

    /// A wake refresh (due checks only) during a pass used to be dropped by the coalescing rule.
    @MainActor func testAWakeRefreshDuringAPassWaitsForItAndIsntDropped() async {
        let gate = PassGate(), ages = LockedBox<[TimeInterval?]>([])
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
            ages.value.append(request.maxAge)
            if ages.value.count == 1 { await gate.hold() }
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        news.followedSources = [] // Nothing uncached, so only waiting queues it.
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await gate.waitUntilEntered()
        let returned = LockedBox(false)
        let wake = Task {
            await news.refresh(preferences: AlertPreferences(), notifies: false, waitsForFollowUp: true)
            returned.value = true
        }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(returned.value, "It waits for the pass under way")
        await gate.release()
        await wake.value
        await first.value
        XCTAssertEqual(ages.value.count, 2, "…and its own check follows, instead of being dropped")
        XCTAssertNil(ages.value.last!, "Due checks only")
    }

    /// Pull to refresh and Retry return once the pass they queued is done, so the spinner says so.
    @MainActor func testPullToRefreshAndRetryWaitForTheFollowUpTheyQueued() async {
        for retry in [false, true] {
            let gate = PassGate(), calls = LockedBox<[NewsFetcher.Request]>([])
            let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
                calls.value.append(request)
                if calls.value.count == 1 { await gate.hold() }
                return .init(cache: request.cache, newModels: [])
            }, notify: { _, _, _ in })
            let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
            await gate.waitUntilEntered()
            let returned = LockedBox(false)
            let pull = Task {
                if retry { await news.retrySources(["cursor"], waitsForFollowUp: true) }
                else { await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, waitsForFollowUp: true) }
                returned.value = true
            }
            for _ in 0..<100 { await Task.yield() }
            XCTAssertFalse(returned.value, retry ? "Retry" : "Pull to refresh")
            await gate.release()
            await pull.value
            XCTAssertEqual(calls.value.count, 2, "Returned after its follow-up ran")
            if retry { XCTAssertEqual(calls.value.last?.forcedSources, ["cursor"]) } else { XCTAssertEqual(calls.value.last?.maxAge, 0) }
            await first.value
        }
    }

    // MARK: 7. Cadence tiers

    func testEachKindHasItsOwnIntervals() {
        XCTAssertEqual(NewsCadence.intervals(for: .official), .init(background: 15 * 60, onScreen: 5 * 60))
        XCTAssertEqual(NewsCadence.intervals(for: .status), .init(background: 10 * 60, onScreen: 5 * 60))
        XCTAssertEqual(NewsCadence.intervals(for: .voices), .init(background: 3 * 3600, onScreen: 30 * 60))
        XCTAssertEqual(NewsCadence.intervals(for: .models), .init(background: 30 * 60, onScreen: 15 * 60))
        XCTAssertEqual(NewsCadence.activationMaxAge, 15 * 60, "Coming forward on any tab: 15 minutes, not 60")
        // On screen (every 5 minutes), coming forward (15), in the background (nil), now (0).
        let expected: [(NewsCadence.Tier, TimeInterval?, TimeInterval)] = [
            (.official, 300, 300), (.status, 300, 300), (.voices, 300, 1800), (.models, 300, 900),
            (.official, 900, 900), (.status, 900, 600), (.voices, 900, 1800), (.models, 900, 900),
            (.official, nil, 900), (.status, nil, 600), (.voices, nil, 10_800), (.models, nil, 1800),
            (.voices, 0, 0), (.models, 0, 0),
        ]
        for (tier, maxAge, interval) in expected {
            XCTAssertEqual(NewsCadence.interval(for: tier, maxAge: maxAge), interval, "\(tier) at \(String(describing: maxAge))")
        }
        let voice = NewsVoice.catalog.compactMap(\.feed).first!
        XCTAssertEqual(NewsCadence.tier(of: voice), .voices)
        XCTAssertEqual(NewsCadence.tier(of: NewsStatusSource.catalog[0]), .status)
        XCTAssertEqual(NewsCadence.tier(of: FeedSource.catalog[0]), .official)
    }

    /// A live check reads official and status feeds every five minutes and leaves a voice to its
    /// half hour; the background leaves all three to their own intervals.
    func testAPassChecksEachKindByItsOwnInterval() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (304, Data()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        let official = FeedSource(id: "o", name: "O", url: URL(string: "https://example.com/o.xml")!)
        let status = FeedSource(id: "s", name: "S", url: URL(string: "https://example.com/s.xml")!, kind: .officialStatus)
        let voice = FeedSource(id: "v", name: "V", url: URL(string: "https://example.com/v.xml")!, kind: .commentary)
        var cache = NewsCache()
        cache.modelsFetchedAt = now.addingTimeInterval(-6 * 60)
        cache.items = ["o": [], "s": [], "v": []]
        cache.sourceChecks = ["o": .init(succeededAt: now.addingTimeInterval(-6 * 60)), "s": .init(succeededAt: now.addingTimeInterval(-6 * 60)),
                              "v": .init(succeededAt: now.addingTimeInterval(-20 * 60))]
        _ = await NewsFetcher.refresh(cache, sources: [official, status, voice], following: [], maxAge: NewsFetcher.liveInterval, now: now)
        XCTAssertEqual(Set(StubURLProtocol.requests.compactMap(\.url?.lastPathComponent)), ["o.xml", "s.xml"], "Not the voice, nor the model list")
        StubURLProtocol.requests = []
        _ = await NewsFetcher.refresh(cache, sources: [official, status, voice], following: [], now: now.addingTimeInterval(5 * 60))
        XCTAssertEqual(Set(StubURLProtocol.requests.compactMap(\.url?.lastPathComponent)), ["s.xml"], "Status after 10 minutes; official after 15")
    }

    /// Freshness is measured against each kind's interval: a voice read two hours ago is current,
    /// a status feed read twenty minutes ago isn't.
    func testFreshnessIsMeasuredAgainstEachKindsInterval() {
        let official = FeedSource.catalog[0], status = NewsStatusSource.catalog[0], voice = NewsVoice.catalog.compactMap(\.feed).first!
        var cache = NewsCache()
        cache.sourceChecks = [official.id: .init(succeededAt: now.addingTimeInterval(-14 * 60)),
                              status.id: .init(succeededAt: now.addingTimeInterval(-20 * 60)),
                              voice.id: .init(succeededAt: now.addingTimeInterval(-2 * 3600))]
        let summary = NewsSourceFreshness(cache: cache, sources: [official, status, voice], now: now)
        XCTAssertEqual(summary.currentCount, 2)
        XCTAssertEqual(summary.delayedCount, 1, "The status feed")
        cache.sourceChecks?[official.id] = .init(succeededAt: now.addingTimeInterval(-17 * 60))
        XCTAssertEqual(NewsSourceFreshness(cache: cache, sources: [official], now: now).delayedCount, 1)
    }

    func testTheNextBackgroundPassIsWhenTheSoonestSourceComesDue() {
        let official = FeedSource.catalog[0], status = NewsStatusSource.catalog[0]
        var cache = NewsCache()
        cache.modelsFetchedAt = now.addingTimeInterval(-20 * 60)            // due in 10 minutes
        cache.sourceChecks = [official.id: .init(succeededAt: now.addingTimeInterval(-9 * 60)), // due in 6
                              status.id: .init(succeededAt: now.addingTimeInterval(-3 * 60))]  // due in 7
        XCTAssertEqual(NewsCadence.nextCheck(cache: cache, sources: [official, status], now: now), now.addingTimeInterval(6 * 60))
        cache.sourceChecks?[status.id] = .init(failedAt: now.addingTimeInterval(-60), failures: 1)
        XCTAssertEqual(NewsCadence.nextCheck(cache: cache, sources: [official, status], now: now), now.addingTimeInterval(4 * 60), "A failure's backoff")
        cache.sourceChecks?[status.id] = .init(succeededAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(NewsCadence.nextCheck(cache: cache, sources: [official, status], now: now), now.addingTimeInterval(NewsCadence.shortestWait), "Overdue (offline): not a busy loop")
        cache = NewsCache()
        cache.modelsFetchedAt = now
        XCTAssertEqual(NewsCadence.nextCheck(cache: cache, sources: [], now: now), now.addingTimeInterval(NewsCadence.longestWait))
    }

    // MARK: 8. iPhone background and coming forward

    @MainActor func testBackgroundRefreshRunsUsageAndNewsSideBySide() async {
        let newsStarted = LockedBox(false), usageSawNews = LockedBox(false)
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
            newsStarted.value = true
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        await NewsLifecycle.backgroundRefresh(news: news, preferences: AlertPreferences()) {
            for _ in 0..<400 where !newsStarted.value { try? await Task.sleep(for: .milliseconds(5)) }
            usageSawNews.value = newsStarted.value
        }
        XCTAssertTrue(usageSawNews.value, "News ran while usage was still under way")
        XCTAssertEqual(NewsLifecycle.backgroundBudget, 20)
    }

    /// Past its budget the background News pass is cancelled, and counts no failure.
    @MainActor func testBackgroundNewsGivesWayAtItsBudgetWithoutFailures() async {
        useHangingNetwork()
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: Self.realFetch, notify: { _, _, _ in })
        news.followedSources = ["cursor"]
        let started = Date()
        await NewsLifecycle.backgroundRefresh(news: news, preferences: AlertPreferences(), budget: 0.3) {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        await eventually { !news.isRefreshing }
        XCTAssertFalse(news.isRefreshing)
        XCTAssertGreaterThan(HangingProtocol.started.value, 0)
        assertNoFailures(news.cache)
    }

    @MainActor func testComingForwardChecksNewsBesideUsageAtFifteenMinutes() async {
        let ages = LockedBox<[TimeInterval?]>([]), usageSawNews = LockedBox(false)
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
            ages.value.append(request.maxAge)
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        await NewsLifecycle.cameForward(news: news, preferences: { AlertPreferences() }) {
            for _ in 0..<400 where ages.value.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            usageSawNews.value = !ages.value.isEmpty
        }
        XCTAssertTrue(usageSawNews.value, "News doesn't wait behind usage")
        XCTAssertEqual(ages.value, [NewsCadence.activationMaxAge])
    }

    // MARK: 9. The Mac's News loop

    @MainActor func testSharingNoLongerChecksNews() async throws {
        let prefs = defaults(), calls = LockedBox(0)
        let news = NewsStore(defaults: prefs, directory: nil, fetch: { request in
            calls.value += 1
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let settings = AppSettings(defaults: prefs)
        settings.newsEnabled = true
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: folder()), news: news)
        await store.share()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.value, 0, "iCloud sharing and News are apart")
    }

    @MainActor func testTheNewsLoopChecksThenWaitsForTheNextSourceDue() async {
        let prefs = defaults(), requests = LockedBox<[NewsFetcher.Request]>([]), waits = LockedBox<[TimeInterval]>([])
        let news = NewsStore(defaults: prefs, directory: nil, fetch: { request in
            requests.value.append(request)
            var cache = request.cache
            cache.modelsSucceeded(at: request.now)
            return .init(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        news.followedSources = []
        let settings = AppSettings(defaults: prefs)
        settings.newsEnabled = true
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: folder()), news: news)
        store.waitForNextNewsCheck = { wait in
            waits.value.append(wait)
            throw CancellationError()
        }
        store.startNewsLoop()
        await eventually { !waits.value.isEmpty }
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertNil(requests.value.first?.maxAge, "A background pass: what's due by each kind")
        XCTAssertEqual(waits.value.first ?? 0, min(NewsCadence.intervals(for: .models).background, NewsCadence.longestWait), accuracy: 2,
                       "Until the model list comes due, within the longest wait")
    }

    // MARK: 10. Skills

    private static let trendingBody = Data("""
    {"generatedAt":"2026-11-07T08:40:03.745Z","kind":"skills","windowHours":24,"items":[
      {"rank":1,"slug":"file-drop","displayName":"File drop","summary":"Moves files","source":"clawhub","publisher":{"handle":"ada-tools","kind":"user"},
       "metrics":{"lifetimeInstalls":120,"updatedAt":1794000000000},"trust":{"clawHubVerdict":"clean"}},
      {"rank":2,"slug":"image-maker","displayName":"Image maker","source":"skills-sh","publisher":null,
       "sourceIdentity":{"owner":"mirror-owner"},"metrics":{"lifetimeInstalls":900}},
      {"rank":3,"slug":"risky","displayName":"Risky","source":"clawhub","publisher":{"handle":"risky-owner"},"trust":{"clawHubVerdict":"suspicious"}},
      {"rank":4,"slug":"note-keeper","displayName":"Note keeper","source":"clawhub","sourceIdentity":{"owner":"bea-lab"},
       "metrics":{"lifetimeInstalls":340},"trust":{"clawHubVerdict":"clean"}}
    ],"nextCursor":"more"}
    """.utf8)

    func testTrendingReadsTheSuccessorEndpoint() throws {
        let trending = SkillFeed.request(sort: .trending).url!
        XCTAssertEqual(trending.path, "/api/v1/trending")
        XCTAssertEqual(URLComponents(url: trending, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value, "skills")
        XCTAssertEqual(SkillFeed.request(sort: .downloads).url?.path, "/api/v1/skills", "The other rankings stay where they are")
        let page = try SkillFeed.parse(Self.trendingBody)
        XCTAssertEqual(page.listings.map(\.id), ["ada-tools/file-drop", "bea-lab/note-keeper"], "ClawHub's own clean uploads only")
        XCTAssertEqual(page.listings.map(\.sourceRank), [1, 4], "Ranked as ClawHub ranked them")
        XCTAssertEqual(page.listings.map(\.installs), [120, 340])
        XCTAssertEqual(page.listings.first?.updatedAt, Date(timeIntervalSince1970: 1_794_000_000))
        XCTAssertEqual(page.listings.first?.canonicalURL.absoluteString, "https://clawhub.ai/ada-tools/skills/file-drop")
        XCTAssertNil(page.listings.first?.downloads)
        XCTAssertFalse(SkillSort.trending.label.contains("7 days"), "The successor's window isn't seven days")
        // An entry that doesn't say it's ClawHub's, or carries no verdict, is left out.
        let unlabelled = Data("""
        {"items":[
          {"rank":1,"slug":"no-source","displayName":"No source","publisher":{"handle":"cara-dev"},"trust":{"clawHubVerdict":"clean"}},
          {"rank":2,"slug":"no-verdict","displayName":"No verdict","source":"clawhub","publisher":{"handle":"cara-dev"}},
          {"rank":3,"slug":"no-trust","displayName":"No trust","source":"clawhub","publisher":{"handle":"cara-dev"},"trust":{}},
          {"rank":4,"slug":"kept","displayName":"Kept","source":"clawhub","publisher":{"handle":"cara-dev"},"trust":{"clawHubVerdict":"clean"}}
        ]}
        """.utf8)
        XCTAssertEqual(try SkillFeed.parse(unlabelled).listings.map(\.slug), ["kept"])
        XCTAssertTrue(SkillFeed.communityNote.contains("doesn't review"))
    }

    /// A launch shows each ranking's last good list, with when it was checked, before asking again.
    @MainActor func testTheLastGoodListIsSavedForEachRanking() async {
        let directory = folder(), calls = LockedBox(0)
        let first = SkillsStore(directory: directory, fetch: { request in
            calls.value += 1
            return request.url?.path == "/api/v1/trending" ? .body(Self.trendingBody) : .body(SkillFeedTests.body)
        }, clock: { [now = self.now] in now })
        await first.refresh(sort: .trending)
        await first.refresh(sort: .downloads)
        XCTAssertEqual(calls.value, 2)
        let relaunched = SkillsStore(directory: directory, fetch: { _ in
            calls.value += 1
            return .unreachable
        }, clock: { [now = self.now] in now.addingTimeInterval(60) })
        XCTAssertEqual(relaunched.listings.map(\.id), ["ada-tools/file-drop", "bea-lab/note-keeper"], "Shown at once")
        XCTAssertEqual(relaunched.checkedAt, now, "\"Checked …\"")
        await relaunched.refresh(sort: .downloads)
        XCTAssertEqual(relaunched.listings.first?.owner, "alice")
        XCTAssertEqual(calls.value, 2, "Fresh lists aren't asked for again")
        // A failure keeps the saved list.
        let later = SkillsStore(directory: directory, fetch: { _ in .status(503, retryAfter: nil) }, clock: { [now = self.now] in now.addingTimeInterval(3600) })
        await later.refresh(sort: .trending)
        XCTAssertEqual(later.listings.count, 2)
        XCTAssertNotNil(later.problem)
    }

    @MainActor func testServerErrorsBackOffAndRetryStillAsks() async {
        let calls = LockedBox(0), clock = LockedBox(now)
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            return .status(503, retryAfter: nil)
        }, clock: { clock.value })
        await store.refresh(sort: .trending)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(store.problem, "ClawHub is unavailable. Try again later.")
        clock.value = now.addingTimeInterval(4 * 60)
        await store.refresh(sort: .trending)
        XCTAssertEqual(calls.value, 1, "Not again within 5 minutes")
        clock.value = now.addingTimeInterval(5 * 60)
        await store.refresh(sort: .trending)
        XCTAssertEqual(calls.value, 2)
        clock.value = now.addingTimeInterval(19 * 60)
        await store.refresh(sort: .trending)
        XCTAssertEqual(calls.value, 2, "15 minutes after a second")
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 3, "Retry always asks")
    }

    @MainActor func testAnOversizedOrOfflineAnswerSaysWhatHappened() async {
        let tooLarge = SkillsStore(fetch: { _ in .tooLarge }, clock: { [now = self.now] in now })
        await tooLarge.refresh(sort: .trending)
        XCTAssertEqual(tooLarge.problem, "Couldn't read ClawHub's ranking: it was larger than Tokenroom reads (2 MB).")
        let answers = LockedBox<[SkillsStore.Answer]>([.body(SkillFeedTests.body), .offline])
        let offline = SkillsStore(fetch: { _ in answers.value.removeFirst() }, clock: { [now = self.now] in now })
        await offline.refresh(sort: .trending)
        await offline.refresh(sort: .trending, force: true)
        XCTAssertNil(offline.problem, "Offline isn't ClawHub's failure: the list stays, without \"Couldn't\"")
        XCTAssertEqual(offline.listings.first?.owner, "alice")
        let empty = SkillsStore(fetch: { _ in .offline }, clock: { [now = self.now] in now })
        await empty.refresh(sort: .trending)
        XCTAssertFalse(empty.problem?.hasPrefix("Couldn't") ?? true)
        XCTAssertEqual(SkillsStore.budget, 20)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotConnectedProtocol.self]
        let answer = await SkillsStore.download(SkillFeed.request(sort: .newest), session: URLSession(configuration: configuration))
        guard case .offline = answer else { return XCTFail("Not connected is offline, got \(answer)") }
    }

    // MARK: 11. Sources, and what an update follows

    func testTheNewSourcesAreInTheCatalogAndTheProfileOnlyVoiceIsGone() throws {
        let voices = Set(NewsVoice.catalog.map(\.id))
        XCTAssertTrue(voices.isSuperset(of: ["voice-importai", "voice-interconnects", "voice-latentspace", "voice-mitsuhiko", "voice-mitchellh"]))
        XCTAssertEqual(Set(NewsVoice.catalog.filter { $0.role == .discussion }.map(\.id)), ["discussion-techmeme", "discussion-huggingface"])
        XCTAssertFalse(voices.contains("voice-embirico"))
        XCTAssertTrue(NewsVoice.catalog.allSatisfy { $0.feed != nil }, "Every voice has a feed")
        XCTAssertTrue(NewsVoice.catalog.allSatisfy { $0.feed?.kind == .commentary && $0.feed?.id == $0.id })
        XCTAssertEqual(Set(NewsStatusSource.catalog.map(\.id)), ["status-openai", "status-claude", "status-github", "status-openrouter", "status-spacexai"])
        let xai = try XCTUnwrap(NewsStatusSource.catalog.first { $0.id == "status-spacexai" })
        XCTAssertTrue(xai.name.contains("Cursor"), "Cursor's status page redirects here, and the name says so")
        let mistral = try XCTUnwrap(FeedSource.catalog.first { $0.id == "mistral-news" })
        XCTAssertFalse(mistral.startsOnForUpgraders)
        XCTAssertEqual(mistral.kind, .officialAnnouncement)
        // Discussion and voices live outside the catalog, so they're never swept into the rule
        // that turns new catalog feeds on for upgraders.
        let catalogIDs = Set(FeedSource.catalog.map(\.id))
        XCTAssertTrue(catalogIDs.isDisjoint(with: voices))
        XCTAssertTrue(FeedSource.catalog.allSatisfy { $0.kind == .officialAnnouncement })
        let all = FeedSource.catalog + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "IDs are unique")
        XCTAssertTrue(all.allSatisfy { $0.url.scheme == "https" })
        XCTAssertTrue(NewsVoice.catalog.allSatisfy { $0.profileURL.host == "x.com" && $0.evidenceURL.scheme == "https" })
    }

    /// PRIVACY.md lists every host News and Skills read.
    func testPrivacyListsEveryNewsHost() throws {
        let privacy = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        let sources = FeedSource.catalog + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
        let hosts = Set(sources.compactMap(\.url.host) + [ModelFeed.url.host!, SkillFeed.request(sort: .trending).url!.host!])
        for host in hosts {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            XCTAssertTrue(privacy.contains("`\(bare)`") || privacy.contains("`\(host)`"), "PRIVACY.md names \(host)")
        }
    }

    @MainActor func testANewInstallFollowsTheFourDefaultVoices() throws {
        let prefs = defaults()
        let news = NewsRuntime.liveNewsStore(defaults: prefs, directory: nil)
        XCTAssertEqual(news.followedVoices, ["voice-simonw", "voice-interconnects", "voice-importai", "voice-latentspace"])
        XCTAssertTrue(news.followedSources.contains("mistral-news"), "A new install follows every official feed")
        XCTAssertTrue(news.newSources.isEmpty, "Nothing to suggest")
        let relaunched = NewsRuntime.liveNewsStore(defaults: prefs, directory: nil)
        XCTAssertEqual(relaunched.followedVoices, news.followedVoices, "Kept, though nothing was changed")
        XCTAssertTrue(relaunched.newSources.isEmpty)
    }

    /// An update follows nothing new: it suggests the new sources until dismissed.
    @MainActor func testAnUpdateFollowsNothingNewAndSuggestsTheNewSources() throws {
        for savedSources in [nil, ["claude-code", "cursor"]] as [[String]?] {
            let prefs = defaults()
            prefs.set(1_790_000_000.0, forKey: NewsStore.Keys.seenAt) // Any earlier release saved this.
            if let savedSources {
                prefs.set(savedSources, forKey: NewsStore.Keys.sources)
                prefs.set(FeedSource.catalog.map(\.id).filter { $0 != "mistral-news" }, forKey: NewsStore.Keys.knownSources)
            }
            prefs.set(["status-openai"], forKey: NewsStore.Keys.status)
            let news = NewsRuntime.liveNewsStore(defaults: prefs, directory: nil)
            news.allowsRefresh = { false } // A follow reads at once; not from a test.
            XCTAssertTrue(news.followedVoices.isEmpty, "No voice turned on silently")
            XCTAssertEqual(news.followedStatusSources, ["status-openai"])
            XCTAssertFalse(news.followedSources.contains("mistral-news"), "No feed turned on silently")
            if savedSources == nil {
                XCTAssertEqual(news.followedSources, Set(FeedSource.catalog.map(\.id)).subtracting(["mistral-news"]))
            }
            XCTAssertEqual(Set(news.newSources.map(\.id)), [
                "mistral-news", "voice-importai", "voice-interconnects", "voice-latentspace", "voice-mitsuhiko", "voice-mitchellh",
                "discussion-techmeme", "discussion-huggingface", "status-github", "status-openrouter", "status-spacexai",
            ])
            news.setFollowing(try XCTUnwrap(news.newSources.first { $0.id == "voice-importai" }), true)
            XCTAssertEqual(news.followedVoices, ["voice-importai"])
            XCTAssertEqual(news.newSources.count, 11, "Shown until dismissed")
            news.dismissNewSources()
            XCTAssertTrue(news.newSources.isEmpty)
            let relaunched = NewsRuntime.liveNewsStore(defaults: prefs, directory: nil)
            XCTAssertTrue(relaunched.newSources.isEmpty, "Dismissed stays dismissed")
            XCTAssertEqual(relaunched.followedVoices, ["voice-importai"])
        }
    }

    @MainActor func testAnInstallThatChoseVoicesKeepsItsChoice() {
        let prefs = defaults()
        prefs.set(["voice-karpathy"], forKey: NewsStore.Keys.voices)
        let news = NewsRuntime.liveNewsStore(defaults: prefs, directory: nil)
        XCTAssertEqual(news.followedVoices, ["voice-karpathy"])
        XCTAssertFalse(news.newSources.isEmpty, "An earlier install, offered what's new")
    }

    @MainActor func testFollowingGoesThroughEachKindsChoice() throws {
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let status = NewsStatusSource.catalog[2], discussion = try XCTUnwrap(NewsVoice.catalog.first { $0.role == .discussion }?.feed)
        let releases = try XCTUnwrap(FeedSource.catalog.first { $0.partOf == "claude-code" })
        news.setFollowing(status, true)
        news.setFollowing(discussion, true)
        news.setFollowing(releases, false)
        XCTAssertTrue(news.followedStatusSources.contains(status.id))
        XCTAssertTrue(news.followedVoices.contains(discussion.id))
        XCTAssertFalse(news.followedSources.contains("claude-code"), "Through the feed it's part of")
        XCTAssertTrue(news.isFollowing(status) && news.isFollowing(discussion) && !news.isFollowing(releases))
    }
}

/// Answers nothing until the request is cancelled.
private final class HangingProtocol: URLProtocol, @unchecked Sendable {
    static let started = LockedBox(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.value += 1 }
    override func stopLoading() {}
}

private final class NotConnectedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// Holds a pass's fetch until released, and says when one has reached it.
private actor PassGate {
    private var entered = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered += 1
        waiting.forEach { $0.resume() }
        waiting = []
        await withCheckedContinuation { held.append($0) }
    }
    func waitUntilEntered() async {
        if entered > 0 { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        held.forEach { $0.resume() }
        held = []
    }
}
