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
        let news = NewsStore(defaults: defaults, directory: folder, fetch: { request in
            var cache = request.cache
            cache.models = [Self.release("anthropic/claude-arrived", created: request.now)]
            cache.modelsFetchedAt = request.now
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })

        news.beginVisit(now: opened)
        await news.refresh(maxAge: NewsFetcher.liveInterval, preferences: AlertPreferences(), notifies: false, now: arrived)
        XCTAssertTrue(news.isNew(arrived), "Marked New for the rest of the visit")
        news.endVisit()
        XCTAssertEqual(news.unseenModelCount, 0, "Seen as it arrived, so no badge after closing News")

        // Outside a visit, a check's finds still count.
        let later = arrived.addingTimeInterval(86_400)
        let closed = NewsStore(defaults: defaults, directory: folder, fetch: { request in
            var cache = request.cache
            cache.models.append(Self.release("anthropic/claude-later", created: request.now))
            return NewsFetcher.Result(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        await closed.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: later)
        XCTAssertEqual(closed.unseenModelCount, 1)
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
        XCTAssertEqual(later.unseenModelCount, 1, "Created during the visit, but never on screen")
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
