import XCTest
@testable import Tokenroom

final class NewsQAFixTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "tokenroom.tests.news-qa." + UUID().uuidString
        suites.append(name)
        let value = UserDefaults(suiteName: name)!
        value.set([], forKey: NewsStore.Keys.sources)
        value.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        value.set([], forKey: NewsStore.Keys.vendors)
        value.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.knownVendors)
        value.set(now.addingTimeInterval(-100).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        return value
    }
    private func folder(_ cache: NewsCache = NewsCache()) -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(value)
        cache.save(to: value)
        return value
    }
    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }
    private func bookmark(_ id: String) -> NewsBookmark {
        .init(id: id, aliases: [], kind: .story, title: id, publisher: "Publisher", url: nil,
              summary: nil, publishedAt: nil, updatedAt: nil, savedAt: now)
    }

    func testWellFormedNonFeedIsRejectedButEmptyRSSAndAtomAreValid() {
        let source = FeedSource.catalog[0]
        for xml in ["<html><body>Maintenance</body></html>", "<rss/>", "<html><item><title>Fake article</title></item></html>"] {
            let result = FeedParser.read(Data(xml.utf8), source: source)
            XCTAssertFalse(result.isComplete)
            XCTAssertTrue(result.items.isEmpty)
        }
        for xml in ["<rss><channel/></rss>", "<feed xmlns=\"http://www.w3.org/2005/Atom\"/>"] {
            let result = FeedParser.read(Data(xml.utf8), source: source)
            XCTAssertTrue(result.isComplete)
            XCTAssertTrue(result.items.isEmpty)
        }
    }
    func testNonFeedRetainsCacheAndInitiallyBrokenFeedDoesNotCreateUsableBucket() async {
        let source = FeedSource.catalog[0]
        var cache = NewsCache()
        cache.modelsFetchedAt = now
        cache.items[source.id] = [FeedItem(id: "retained", title: "Retained", source: source.name)]
        stub { _ in (200, Data("<html><body>Maintenance</body></html>".utf8)) }
        let retained = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now, forcedSources: [source.id]).cache
        XCTAssertEqual(retained.items[source.id], cache.items[source.id])
        XCTAssertEqual(retained.sourceChecks?[source.id]?.failedAt, now)
        XCTAssertNil(retained.sourceChecks?[source.id]?.succeededAt)
        cache.items = [:]
        stub { _ in (200, Data("<rss><channel><item>".utf8)) }
        let broken = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now, forcedSources: [source.id]).cache
        XCTAssertNil(broken.items[source.id], "An unusable first response must not suppress immediate uncached re-follow")
        stub { _ in (200, Data("<rss><channel><item><guid>a</guid><title>Recovered</title></item></channel></rss>".utf8)) }
        let recovered = await NewsFetcher.refresh(broken, sources: [source], following: [], now: now.addingTimeInterval(60), forcedSources: [source.id]).cache
        XCTAssertEqual(recovered.items[source.id]?.map(\.id), ["a"])
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }
    @MainActor func testUnfollowDuringFirstSuccessfulVoiceFetchStillEstablishesQuietBaseline() async throws {
        let voice = try XCTUnwrap(NewsVoice.catalog.first?.feed)
        let prefs = defaults()
        prefs.set([voice.id], forKey: NewsStore.Keys.voices)
        var initial = NewsCache(); initial.modelsFetchedAt = now.addingTimeInterval(-60)
        let gate = QANewsGate()
        let date = now
        let news = NewsStore(defaults: prefs, directory: folder(initial), now: now, fetch: { request in
            await gate.pause()
            var cache = request.cache
            cache.items[voice.id] = [FeedItem(id: "archive", title: "Archive", published: date.addingTimeInterval(-50), source: voice.name)]
            cache.sourceChecks = [voice.id: .init(succeededAt: request.now)]
            return .init(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false, now: date) }
        await gate.waitUntilPaused()
        news.followedVoices = []
        await gate.release(); await first.value
        news.followedVoices = [voice.id]
        let item = try XCTUnwrap(news.allAnnouncements.first)
        XCTAssertEqual(news.unseenAnnouncementCount, 0)
        XCTAssertFalse(news.isNew(item.newsDate))
        XCTAssertEqual(item.published, date.addingTimeInterval(-50))
    }
    @MainActor func testFirstSuccessfulVoiceCheckAfterAnEmptyFailedBucketIsQuiet() async throws {
        let voice = try XCTUnwrap(NewsVoice.catalog.first?.feed)
        let prefs = defaults(); prefs.set([voice.id], forKey: NewsStore.Keys.voices)
        var initial = NewsCache(); initial.modelsFetchedAt = now
        initial.items[voice.id] = []
        initial.sourceChecks = [voice.id: .init(failedAt: now.addingTimeInterval(-10))]
        let date = now
        let news = NewsStore(defaults: prefs, directory: folder(initial), now: now, fetch: { request in
            var cache = request.cache
            cache.items[voice.id] = [FeedItem(id: "archive", title: "Archive", published: date.addingTimeInterval(-50), source: voice.name)]
            cache.sourceChecks = [voice.id: .init(succeededAt: request.now)]
            return .init(cache: cache, newModels: [])
        }, notify: { _, _, _ in })
        await news.refresh(preferences: AlertPreferences(), notifies: false, now: now)
        XCTAssertEqual(news.unseenAnnouncementCount, 0)
        XCTAssertFalse(news.isNew(news.allAnnouncements.first?.newsDate))
    }
    @MainActor func testSourceRetryPreservesQueuedNotificationPreferences() async {
        for enabled in [false, true] {
            let gate = QANewsGate()
            let calls = LockedBox(0)
            var delivered: [AlertPreferences] = []
            let model = ModelRelease(id: "openai/new", name: "New", vendor: "openai", created: now,
                                     contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
            let news = NewsStore(defaults: defaults(), directory: nil, fetch: { request in
                calls.value += 1
                if calls.value == 1 { await gate.pause() }
                return .init(cache: request.cache, newModels: calls.value == 1 ? [] : [model])
            }, notify: { _, preferences, _ in delivered.append(preferences) })
            var preferences = AlertPreferences()
            preferences.newModels = enabled; preferences.quietStartHour = 19; preferences.quietEndHour = 10
            let first = Task { await news.refresh(preferences: preferences, notifies: false) }
            await gate.waitUntilPaused()
            await news.refresh(maxAge: 0, preferences: preferences, notifies: true)
            await news.retrySources([FeedSource.catalog[0].id])
            await gate.release(); await first.value
            XCTAssertEqual(calls.value, 2)
            XCTAssertEqual(delivered.count, enabled ? 1 : 0)
            XCTAssertEqual(delivered.first?.quietStartHour, enabled ? 19 : nil)
            XCTAssertEqual(delivered.first?.quietEndHour, enabled ? 10 : nil)
        }
    }
    func testTargetedModelRetryDoesNotForceOtherFeeds() async {
        var cache = NewsCache(); cache.modelsFetchedAt = now
        let source = FeedSource.catalog[0]
        cache.items[source.id] = []
        cache.sourceChecks = [source.id: .init(succeededAt: now)]
        stub { _ in (200, Data("{\"data\":[]}".utf8)) }
        _ = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now, forcedSources: [ModelFeed.id])
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [ModelFeed.url])
    }
    @MainActor func testFailedRemoveAndResavePreservePendingUndo() throws {
        let directory = folder()
        var fails = false
        let library = NewsLibrary(directory: directory, writer: { data, url in
            if fails { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let a = bookmark("a"), b = bookmark("b")
        XCTAssertTrue(library.save(a)); XCTAssertTrue(library.save(b))
        var undo = NewsRemovalUndo()
        XCTAssertTrue(undo.remove(id: a.id, from: library))
        fails = true
        XCTAssertFalse(undo.remove(id: b.id, from: library))
        XCTAssertEqual(undo.item, a)
        XCTAssertFalse(undo.save(a, in: library))
        XCTAssertEqual(undo.item, a)
        XCTAssertFalse(undo.restore(in: library))
        XCTAssertEqual(undo.item, a)
        fails = false
        XCTAssertTrue(undo.restore(in: library))
        XCTAssertNil(undo.item)
        XCTAssertEqual(Set(library.saved.map(\.id)), ["a", "b"])
    }
    @MainActor func testReadEvictionKeepsSavedSnapshotAndReopens() throws {
        let directory = folder()
        let entries = (0..<5000).map { ["ids": ["read-\($0)"], "date": 1_000_000_000.0 + Double($0)] as [String: Any] }
        // One uniquely oldest read plus 4,999 newer ones makes eviction deterministic.
        var read = entries
        read[0]["date"] = 900_000_000.0
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "saved": [], "read": read])
        try data.write(to: directory.appendingPathComponent(NewsLibrary.fileName))
        let library = NewsLibrary(directory: directory)
        XCTAssertNil(library.problem)
        XCTAssertTrue(library.save(bookmark("read-0")))
        library.markRead(id: "new-read")
        let reopened = NewsLibrary(directory: directory)
        XCTAssertFalse(reopened.isRead(id: "read-0"))
        XCTAssertTrue(reopened.isRead(id: "read-1"))
        XCTAssertTrue(reopened.isRead(id: "new-read"))
        XCTAssertTrue(reopened.isSaved(id: "read-0"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(NewsLibrary.fileName))) as? [String: Any])
        XCTAssertEqual((document["read"] as? [Any])?.count, 5000)
    }
    @MainActor func testRetirementScopeAndMacReleaseCountMatchDestinations() {
        let prefs = defaults(); prefs.set(["openai"], forKey: NewsStore.Keys.vendors)
        let voice = NewsVoice.catalog.first!.feed!, status = NewsStatusSource.catalog[0], release = FeedSource.catalog[0]
        prefs.set([voice.id], forKey: NewsStore.Keys.voices)
        prefs.set([status.id], forKey: NewsStore.Keys.status)
        prefs.set([release.id], forKey: NewsStore.Keys.sources)
        var cache = NewsCache()
        cache.models = ["openai", "anthropic"].map { vendor in
            ModelRelease(id: vendor + "/retiring", name: "Retiring", vendor: vendor, created: now,
                         contextLength: nil, promptPrice: nil, completionPrice: nil, expires: Date.now.addingTimeInterval(3600))
        }
        for source in [voice, status, release] { cache.items[source.id] = [FeedItem(id: source.id, title: source.name, published: now, source: source.name)] }
        let news = NewsStore(defaults: prefs, directory: folder(cache), now: now, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(news.retiringModels().map(\.vendor), ["openai"])
        XCTAssertEqual(news.retiringModels(all: true).count, 2)
        XCTAssertEqual(news.unseenAnnouncementCount, 3)
        XCTAssertEqual(news.unseenReleaseCount, 1)
    }
    @MainActor func testCollectionHealthDistinguishesColdFailureAndValidEmpty() {
        let source = FeedSource.catalog.first { $0.id == "devin" }!
        let prefs = defaults(); prefs.set([source.id], forKey: NewsStore.Keys.sources)
        let cold = NewsStore(defaults: prefs, directory: nil, now: now, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(cold.collectionHealth(for: .release).uncheckedCount, 1)
        var cache = NewsCache()
        cache.items[source.id] = []
        cache.sourceChecks = [source.id: .init(failedAt: now)]
        cache.unreadable = [source.id]
        let failed = NewsStore(defaults: prefs, directory: folder(cache), now: now, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertNotNil(failed.collectionHealth(for: .release).problem)
        XCTAssertEqual(failed.collectionHealth(for: .release).retryIDs, [source.id])
        cache.sourceChecks = [source.id: .init(succeededAt: now)]
        cache.unreadable = []
        let empty = NewsStore(defaults: prefs, directory: folder(cache), now: now, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertNil(empty.collectionHealth(for: .release).problem)
        XCTAssertEqual(empty.collectionHealth(for: .release).checkedAt, now)
        XCTAssertEqual(empty.collectionHealth(for: .release).uncheckedCount, 0)
    }
    @MainActor func testTestHostNewsIsInertWithoutSnapshotAndDoesNotUseLaunchChoices() async {
        let launch = defaults(), isolated = defaults()
        launch.set(["not-a-catalog-source"], forKey: NewsStore.Keys.sources)
        launch.set(["voice-embirico"], forKey: NewsStore.Keys.voices)
        stub { _ in XCTFail("Test composition must not start a public request"); return (503, Data()) }
        let news = NewsRuntime.newsStore(launchDefaults: launch, isUnitTestHost: true, inertDefaults: isolated)
        let before = news.cache
        await news.refresh(maxAge: 0, preferences: AlertPreferences())
        XCTAssertEqual(news.cache, before)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(news.followedVoices.isEmpty)
        XCTAssertEqual(launch.stringArray(forKey: NewsStore.Keys.voices), ["voice-embirico"])
    }
}

private actor QANewsGate {
    private var paused = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            gate = continuation; paused = true
            observers.forEach { $0.resume() }; observers = []
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}
