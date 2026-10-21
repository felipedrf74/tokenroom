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
        XCTAssertLessThanOrEqual(NewsFetcher.openInterval, 15 * 60, "Opening News shows feeds no older than a quarter of an hour")
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
        let news = NewsStore(defaults: defaults, directory: folder, fetch: { request in
            NewsFetcher.Result(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        news.beginVisit(now: opened)
        let liveCheck = opened.addingTimeInterval(NewsFetcher.liveInterval)
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: AlertPreferences(), notifies: false, now: liveCheck)
        news.endVisit()

        let later = NewsStore(defaults: defaults, directory: folder, fetch: { request in
            var cache = request.cache
            cache.models.append(Self.release("anthropic/claude-missed", created: opened.addingTimeInterval(60)))
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        await later.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: liveCheck.addingTimeInterval(60))
        XCTAssertEqual(later.unseenModelCount(now: liveCheck.addingTimeInterval(60)), 1, "Created during the visit, but never on screen")
    }

    /// News opened while another check runs still gets its 15-minute check right after it,
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
                while held.value { try? await Task.sleep(for: .milliseconds(5)) }
                return NewsFetcher.Result(cache: request.cache, newModels: [])
            }
            return NewsFetcher.Result(cache: request.cache, newModels: [Self.release("anthropic/claude-new", created: request.now)])
        }, notify: { _, _, _ in notified.value += 1 })

        let background = Task { await news.refresh(preferences: { var p = AlertPreferences(); p.newModels = true; return p }()) }
        while !entered.value { try await Task.sleep(for: .milliseconds(5)) }
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
        while !entered.value { try await Task.sleep(for: .milliseconds(5)) }
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

    /// A feed that failed waits out the hour during a visit, as it does in the background; a
    /// pull or Check Now still goes out at once.
    func testAFailedFeedWaitsTheHourDuringAVisit() {
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.liveInterval, now: failedAt.addingTimeInterval(NewsFetcher.liveInterval)))
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.liveInterval, now: failedAt.addingTimeInterval(NewsFetcher.retryInterval)))
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, interval: 0, now: failedAt), "Pull to refresh and Check Now")
        XCTAssertFalse(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.modelInterval, now: failedAt.addingTimeInterval(1800)))
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: failedAt, interval: NewsFetcher.modelInterval, now: failedAt.addingTimeInterval(NewsFetcher.retryInterval)))
    }
}
