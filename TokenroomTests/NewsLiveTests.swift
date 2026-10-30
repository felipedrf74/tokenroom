import Foundation
import XCTest
@testable import Tokenroom

/// News keeps itself current while it's on screen, and what arrives then isn't news again later.
final class NewsLiveTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private static func release(_ id: String, created: Date) -> ModelRelease {
        ModelRelease(id: id, name: id, vendor: "anthropic", created: created, contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
    }

    @MainActor
    func testNewsOnScreenChecksAgainByItselfUntilItsClosed() async throws {
        let requests = LockedBox<[NewsFetcher.Request]>([])
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), fetch: { request in
            requests.value.append(request)
            return NewsFetcher.Result(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in XCTFail("News on screen doesn't notify") })
        let sleeps = LockedBox<[TimeInterval]>([])
        await news.keepCurrent(preferences: { AlertPreferences() }, sleep: { interval in
            sleeps.value.append(interval)
            // The screen goes away after the third check.
            if sleeps.value.count == 3 { throw CancellationError() }
        })
        XCTAssertEqual(requests.value.count, 3, "On open, then every interval, without a pull or Check Now")
        XCTAssertTrue(requests.value.allSatisfy { $0.maxAge == NewsFetcher.liveInterval }, "Only feeds older than the interval go out")
        XCTAssertEqual(sleeps.value, Array(repeating: NewsFetcher.liveInterval, count: 3))
        XCTAssertEqual(NewsFetcher.liveInterval, 5 * 60, "On screen, News checks every five minutes")
        XCTAssertEqual(NewsFetcher.openInterval, 5 * 60, "Opening News shows feeds no older than five minutes")
        XCTAssertEqual(NewsFetcher.modelInterval, 3600, "In the background, the model list every hour")
        XCTAssertEqual(NewsFetcher.announcementInterval, 3600, "…and each feed")
    }

    @MainActor
    func testNewsTurnedOffMeanwhileIsntChecked() async throws {
        let requests = LockedBox(0)
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), fetch: { request in
            requests.value += 1
            return NewsFetcher.Result(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let sleeps = LockedBox(0)
        await news.keepCurrent(preferences: { AlertPreferences() }, isAllowed: { false }, sleep: { _ in
            sleeps.value += 1
            if sleeps.value == 2 { throw CancellationError() }
        })
        XCTAssertEqual(requests.value, 0)
    }

    @MainActor
    func testWhatArrivesWhileNewsIsOpenIsMarkedNewButNotBadgedLater() async throws {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let arrived = opened.addingTimeInterval(NewsFetcher.liveInterval)
        let defaults = makeDefaults()
        defaults.set(opened.addingTimeInterval(-86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = opened.addingTimeInterval(-3600)
        checked.save(to: folder)
        let news = NewsStore(defaults: defaults, directory: folder, now: opened, fetch: { request in
            var cache = request.cache
            cache.models = [Self.release("anthropic/claude-arrived", created: request.now)]
            cache.modelsFetchedAt = request.now
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })

        news.beginVisit(now: opened)
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: AlertPreferences(), notifies: false, now: arrived)
        XCTAssertTrue(news.isNew(arrived), "Marked New for the rest of the visit")
        news.endVisit()
        XCTAssertEqual(news.unseenModelCount(now: arrived), 0, "Seen as it arrived, so no badge after closing News")

        // Outside a visit, a check's finds still count.
        let later = arrived.addingTimeInterval(86_400)
        let closed = NewsStore(defaults: defaults, directory: folder, now: later, fetch: { request in
            var cache = request.cache
            cache.models.append(Self.release("anthropic/claude-later", created: request.now))
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        await closed.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: later)
        XCTAssertEqual(closed.unseenModelCount(now: later), 1)
    }

    // MARK: QA regressions

    /// A visit check that didn't bring an item doesn't mark it seen: one created during the
    /// visit that only arrives afterwards still counts.
    @MainActor
    func testAVisitCheckThatBroughtNothingDoesNotMarkLaterArrivalsSeen() async throws {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeDefaults()
        defaults.set(opened.addingTimeInterval(-86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = opened.addingTimeInterval(-3600)
        checked.save(to: folder)
        let news = NewsStore(defaults: defaults, directory: folder, now: opened, fetch: { request in
            NewsFetcher.Result(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        news.beginVisit(now: opened)
        let liveCheck = opened.addingTimeInterval(NewsFetcher.liveInterval)
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: AlertPreferences(), notifies: false, now: liveCheck)
        news.endVisit()

        let later = NewsStore(defaults: defaults, directory: folder, now: liveCheck.addingTimeInterval(60), fetch: { request in
            var cache = request.cache
            cache.models.append(Self.release("anthropic/claude-missed", created: opened.addingTimeInterval(60)))
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        await later.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: liveCheck.addingTimeInterval(60))
        XCTAssertEqual(later.unseenModelCount(now: liveCheck.addingTimeInterval(60)), 1, "Created during the visit, but never on screen")
    }

    /// The Mac's News window counts as on screen (a visit, 5-minute checks) only while someone can
    /// see it.
    func testTheMacNewsWindowIsOnScreenOnlyWhenItCanBeSeen() {
        XCTAssertTrue(AppDelegate.newsIsOnScreen(isVisible: true, isMiniaturized: false, isOccluded: false, appIsHidden: false))
        XCTAssertFalse(AppDelegate.newsIsOnScreen(isVisible: true, isMiniaturized: true, isOccluded: false, appIsHidden: false), "In the Dock")
        XCTAssertFalse(AppDelegate.newsIsOnScreen(isVisible: true, isMiniaturized: false, isOccluded: true, appIsHidden: false), "Wholly covered, or on another Space")
        XCTAssertFalse(AppDelegate.newsIsOnScreen(isVisible: true, isMiniaturized: false, isOccluded: false, appIsHidden: true), "Hidden with the app")
        XCTAssertFalse(AppDelegate.newsIsOnScreen(isVisible: false, isMiniaturized: false, isOccluded: false, appIsHidden: false), "Closed")
    }

    /// What a pass has taken in shows while it's still waiting on a slow feed, and a quiet read's
    /// back catalog isn't new even then.
    @MainActor
    func testWhatArrivesShowsBeforeTheWholePassIsDone() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeDefaults()
        defaults.set(now.addingTimeInterval(-3600).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = now.addingTimeInterval(-60)
        checked.sourceChecks = Dictionary(uniqueKeysWithValues: FeedSource.catalog.filter { $0.id != "cursor" }.map { ($0.id, NewsCache.SourceCheck(succeededAt: now.addingTimeInterval(-60))) })
        checked.save(to: folder)
        let held = LockedBox(true)
        let published = LockedBox(false)
        let news = NewsStore(defaults: defaults, directory: folder, now: now, fetch: { request in
            var partial = request.cache
            // Cursor is read for the first time: its recent post is back catalog.
            partial.items["cursor"] = [FeedItem(id: "c", title: "Cursor post", link: URL(string: "https://example.com/c"), published: now.addingTimeInterval(-600), source: "Cursor", firstSeenAt: now.addingTimeInterval(-600))]
            await request.publish(partial)
            published.value = true
            for _ in 0..<1000 where held.value { try? await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(held.value, "Still held after five seconds: a refresh waited on this pass")
            return NewsFetcher.Result(cache: partial, newModels: [])
        }, notify: { _, _, _ in })
        let pass = Task { await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now) }
        for _ in 0..<1000 where !published.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(published.value, "The pass published what it had")
        XCTAssertTrue(news.isRefreshing, "The pass is still waiting")
        XCTAssertEqual(news.allAnnouncements.first { $0.sourceID == "cursor" }?.title, "Cursor post", "…but what came in shows")
        XCTAssertEqual(news.unseenAnnouncementCount, 0, "…and a first read's back catalog isn't new meanwhile either")
        held.value = false
        await pass.value
        XCTAssertEqual(news.unseenAnnouncementCount, 0)
    }

    /// Every catalog feed with 30 cached entries, and a pass that has brought 30 newer ones to
    /// each, so folding goes over 1,320 entries: the most the catalog's feeds can give it. Claude
    /// Code's changelog and its GitHub releases share versions, Google's two blogs share titles,
    /// and every entry has a link and an excerpt.
    private static func fullCatalog(now: Date) -> (cached: NewsCache, arrived: NewsCache, entries: Int) {
        func items(for source: FeedSource, _ numbers: Range<Int>) -> [FeedItem] {
            numbers.map { n in
                let date = now.addingTimeInterval(-Double(60 - n) * 3600)
                let host = source.url.host ?? "example.com"
                let title: String
                let link: String
                if source.id == "claude-code" {
                    (title, link) = ("2.1.\(n)", "https://\(host)/docs/en/changelog#2-1-\(n)")
                } else if source.url.path.hasSuffix("/releases.atom") {
                    (title, link) = ("v2.1.\(n)", "https://\(host)\(source.url.deletingPathExtension().path)/tag/v2.1.\(n)")
                } else if source.isCommitLog {
                    (title, link) = ("Update skill-\(n % 7) skill (#\(1500 + n))", "https://\(host)/anthropics/skills/commit/c\(n)")
                } else if source.titleFoldGroup != nil {
                    (title, link) = ("What's new in Gemini, part \(n)", "https://\(host)/blog/whats-new-\(n)-\(source.id)")
                } else {
                    (title, link) = ("\(source.name) post \(n): a new feature for developers", "https://\(host)/news/post-\(n)")
                }
                return FeedItem(id: link, title: title, link: URL(string: link), published: date, source: source.itemSource,
                                sourceID: source.id, kind: source.kind, publisherPublishedAt: date, firstSeenAt: date,
                                excerpt: String(repeating: "What changed, and why it matters to people building with it. ", count: 5),
                                excerptIsPlainText: true)
            }
        }
        var cached = NewsCache()
        cached.modelsFetchedAt = now.addingTimeInterval(-60)
        cached.announcementsFetchedAt = now.addingTimeInterval(-60)
        cached.sourceChecks = Dictionary(uniqueKeysWithValues: FeedSource.catalog.map { ($0.id, NewsCache.SourceCheck(succeededAt: now.addingTimeInterval(-60))) })
        var arrived = cached
        for source in FeedSource.catalog {
            cached.items[source.id] = items(for: source, 0..<30)
            arrived.items[source.id] = items(for: source, 30..<60)
        }
        return (cached, arrived, FeedSource.catalog.count * 60)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Showing what a pass has taken in folds the whole store, about 1,300 entries at most. That
    /// runs off the main actor, both while the pass is under way and for its own result. How long
    /// a publish takes is printed, not asserted: a shared machine's timers can stall.
    @MainActor
    func testShowingAFullCatalogFoldsOffTheMainActor() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let catalog = Self.fullCatalog(now: now)
        let folder = try makeFolder()
        catalog.cached.save(to: folder)
        let folds = LockedBox<[Bool]>([])
        NewsStore.foldRan = { onMainThread in folds.value.append(onMainThread) }
        defer { NewsStore.foldRan = nil }
        let timing = LockedBox<(publish: Duration, held: Duration)?>(nil)
        let news = NewsStore(defaults: makeDefaults(), directory: folder, now: now, fetch: { request in
            // The main actor ticks every millisecond; the longest gap is how long it was held.
            let ticking = LockedBox(true)
            let longest = LockedBox(Duration.zero)
            let ticker = Task { @MainActor in
                var last = ContinuousClock.now
                while ticking.value {
                    try? await Task.sleep(for: .milliseconds(1))
                    let tick = ContinuousClock.now
                    longest.value = max(longest.value, last.duration(to: tick))
                    last = tick
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
            let start = ContinuousClock.now
            await request.publish(catalog.arrived)
            let publish = start.duration(to: .now)
            ticking.value = false
            await ticker.value
            timing.value = (publish, longest.value)
            return NewsFetcher.Result(cache: catalog.arrived, newModels: [])
        }, notify: { _, _, _ in })
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now)
        let measured = try XCTUnwrap(timing.value)
        print(String(format: "News publish over %d entries: %.1f ms, main actor held at most %.1f ms", catalog.entries, Self.milliseconds(measured.publish), Self.milliseconds(measured.held)))
        XCTAssertTrue(news.allAnnouncements.contains { $0.title == "Cursor post 59: a new feature for developers" }, "What arrived shows")
        XCTAssertEqual(folds.value, [false, false], "What arrived, then the pass's result, folded off the main thread")
    }

    /// A feed read seven minutes ago, while the next 5-minute check is under way, is still
    /// current; one read twenty minutes ago is delayed.
    func testSourcesStayCurrentWhileTheNextCheckIsUnderWay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = Array(FeedSource.catalog.prefix(2))
        var cache = NewsCache()
        cache.sourceChecks = [sources[0].id: .init(succeededAt: now.addingTimeInterval(-7 * 60)), sources[1].id: .init(succeededAt: now.addingTimeInterval(-20 * 60))]
        let summary = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.delayedCount, 1)
        XCTAssertGreaterThan(NewsSourceFreshness.currentInterval, NewsFetcher.liveInterval + NewsFetcher.downloadTimeout)
    }

    /// A live check under way (it doesn't notify) when a notifying background refresh comes in:
    /// the models the live check finds are taken off the list, so it notifies them, unless News
    /// is on screen.
    @MainActor
    func testANotifyingRefreshDuringALiveCheckIsntLost() async throws {
        for newsOnScreen in [false, true] {
            let held = LockedBox(true)
            let entered = LockedBox(false)
            let notified = LockedBox<[[String]]>([])
            // Everything checked before, so the background refresh asks for nothing fresher.
            let folder = try makeFolder()
            var checked = NewsCache()
            checked.modelsFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
            checked.sourceChecks = Dictionary(uniqueKeysWithValues: FeedSource.catalog.map { ($0.id, NewsCache.SourceCheck(succeededAt: checked.modelsFetchedAt)) })
            checked.save(to: folder)
            let news = NewsStore(defaults: makeDefaults(), directory: folder, now: Date(timeIntervalSince1970: 1_800_000_000), fetch: { request in
                entered.value = true
                for _ in 0..<1000 where held.value { try? await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(held.value, "Still held after five seconds: a refresh waited on this pass")
                var cache = request.cache
                cache.modelsFetchedAt = request.now
                return NewsFetcher.Result(cache: cache, newModels: [Self.release("anthropic/claude-new", created: request.now)])
            }, notify: { releases, _, _ in notified.value.append(releases.map(\.id)) })
            var preferences = AlertPreferences()
            preferences.newModels = true
            if newsOnScreen { news.beginVisit() }
            let live = Task { await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: preferences, notifies: false) }
            for _ in 0..<1000 where !entered.value { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(entered.value, "The pass reached its fetch")
            await news.refresh(preferences: preferences, notifies: true) // The background refresh.
            held.value = false
            await live.value
            XCTAssertEqual(notified.value, newsOnScreen ? [] : [["anthropic/claude-new"]], newsOnScreen ? "News on screen doesn't notify" : "The background refresh's notification isn't lost")
        }
    }

    /// News opened while another check runs still gets its 5-minute check right after it,
    /// without turning notifications on, and without losing an asked-for check of everything.
    @MainActor
    func testALiveCheckAskedForDuringAnotherPassFollowsIt() async throws {
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        checked.sourceChecks = Dictionary(uniqueKeysWithValues: FeedSource.catalog.map { ($0.id, NewsCache.SourceCheck(succeededAt: checked.modelsFetchedAt)) })
        checked.save(to: folder)
        let ages = LockedBox<[TimeInterval?]>([])
        let held = LockedBox(true)
        let entered = LockedBox(false)
        let notified = LockedBox(0)
        let news = NewsStore(defaults: makeDefaults(), directory: folder, fetch: { request in
            ages.value.append(request.maxAge)
            if ages.value.count == 1 {
                entered.value = true
                for _ in 0..<1000 where held.value { try? await Task.sleep(for: .milliseconds(5)) }
                XCTAssertFalse(held.value, "Still held after five seconds: a refresh waited on this pass")
                return NewsFetcher.Result(cache: request.cache, newModels: [])
            }
            return NewsFetcher.Result(cache: request.cache, newModels: [Self.release("anthropic/claude-new", created: request.now)])
        }, notify: { _, _, _ in notified.value += 1 })

        let background = Task { await news.refresh(preferences: { var p = AlertPreferences(); p.newModels = true; return p }()) }
        for _ in 0..<1000 where !entered.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered.value, "The pass reached its fetch")
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: { var p = AlertPreferences(); p.newModels = true; return p }(), notifies: false)
        held.value = false
        await background.value
        XCTAssertEqual(ages.value, [nil, NewsFetcher.liveInterval])
        XCTAssertEqual(notified.value, 0, "The live check doesn't notify")

        // A check of everything asked for meanwhile isn't shortened to the live interval.
        ages.value = []
        held.value = true
        entered.value = false
        let again = Task { await news.refresh(preferences: AlertPreferences()) }
        for _ in 0..<1000 where !entered.value { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(entered.value, "The pass reached its fetch")
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false)
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: AlertPreferences(), notifies: false)
        held.value = false
        await again.value
        XCTAssertEqual(ages.value, [nil, 0])
    }

    /// A check time or a last look saved while the clock was ahead doesn't hold News back until
    /// the clock catches up.
    @MainActor
    func testDatesSavedAheadOfTheClockDontHoldNewsBack() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ahead = now.addingTimeInterval(2 * 86_400)
        XCTAssertTrue(NewsFetcher.isDue(ahead, interval: NewsFetcher.announcementInterval, now: now), "A check dated ahead is due")
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: ahead, interval: NewsFetcher.announcementInterval, now: now), "…and so is a failure dated ahead")
        XCTAssertFalse(NewsFetcher.isDue(now.addingTimeInterval(-60), interval: NewsFetcher.announcementInterval, now: now))

        let defaults = makeDefaults()
        defaults.set(ahead.timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: try makeFolder(), now: now, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(news.seenAt, now, "A last look ahead of the clock comes back to now")
        XCTAssertEqual(news.visitBaseline, now)
        XCTAssertEqual(defaults.double(forKey: NewsStore.Keys.seenAt), now.timeIntervalSince1970, "…and is saved so")
        XCTAssertTrue(news.isNew(now.addingTimeInterval(60)), "So what comes next is new")
    }

    /// The iPhone ends a visit when the app goes to the background with News selected
    /// (`RootView.updateVisit`): what a background check finds then is badged, and marked New
    /// when the app comes back to News.
    @MainActor
    func testABackgroundCheckAfterLeavingNewsLeavesItsFindsNew() async throws {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeDefaults()
        defaults.set(opened.addingTimeInterval(-86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = opened.addingTimeInterval(-3600)
        checked.save(to: folder)
        let news = NewsStore(defaults: defaults, directory: folder, now: opened, fetch: { request in
            var cache = request.cache
            cache.models.append(Self.release("anthropic/claude-background", created: request.now))
            cache.modelsFetchedAt = request.now
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        news.beginVisit(now: opened)
        news.endVisit() // To the background, News still selected.
        let background = opened.addingTimeInterval(3600)
        await news.refresh(preferences: AlertPreferences(), now: background)
        XCTAssertEqual(news.unseenModelCount(now: background), 1, "Nobody saw it, so it's badged")
        news.beginVisit(now: background.addingTimeInterval(600)) // Back to the app, on News.
        XCTAssertTrue(news.isNew(background), "…and marked New when News is back on screen")
    }

    /// Turning News on with the Mac's window open (a visit already under way) marks nothing new.
    @MainActor
    func testTheFirstCheckMarksNothingNewWithNewsOpen() async throws {
        let installed = Date(timeIntervalSince1970: 1_800_000_000)
        let turnedOn = installed.addingTimeInterval(30 * 86_400)
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), now: installed, fetch: { request in
            var cache = request.cache
            cache.models = [Self.release("anthropic/claude-since-install", created: turnedOn.addingTimeInterval(-86_400))]
            cache.modelsFetchedAt = request.now
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        news.beginVisit(now: turnedOn.addingTimeInterval(-60)) // The window opened, then News was turned on.
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: turnedOn)
        XCTAssertEqual(news.visitBaseline, turnedOn)
        XCTAssertFalse(news.isNew(news.models().first?.created), "Released since install, but there before News was on")
        XCTAssertEqual(news.unseenModelCount(now: turnedOn), 0)
    }

    /// A feed that failed waits out its backoff during a visit, as it does in the background; a
    /// pull or Check Now still goes out at once.
    func testAFailedFeedWaitsItsBackoffDuringAVisit() {
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(NewsFetcher.retryIntervals, [5 * 60, 15 * 60, 30 * 60, 3600])
        for (failures, wait) in [(1, 300.0), (2, 900), (3, 1800), (4, 3600), (9, 3600)] {
            XCTAssertFalse(NewsFetcher.isDue(nil, failedAt: failedAt, failures: failures, interval: NewsFetcher.liveInterval, now: failedAt.addingTimeInterval(wait - 60)), "\(failures) in a row: not before \(wait) s")
            XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, failures: failures, interval: NewsFetcher.liveInterval, now: failedAt.addingTimeInterval(wait)), "\(failures) in a row: after \(wait) s")
        }
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, failures: 9, interval: 0, now: failedAt), "Pull to refresh and Check Now")
        XCTAssertFalse(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.modelInterval, now: failedAt.addingTimeInterval(240)))
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.modelInterval, now: failedAt.addingTimeInterval(300)), "A failure an earlier release saved, without a count, is the first")
    }
}
