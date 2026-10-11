import XCTest
@testable import Tokenroom

/// Regression sources for the second independent QA. Not executed in the no-tests fix pass.
final class NewsSecondQAFixTests: XCTestCase {
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
    private func defaults(sources: [String] = [], vendors: [String] = []) -> UserDefaults {
        let name = "tokenroom.tests.news-qa2." + UUID().uuidString
        suites.append(name)
        let value = UserDefaults(suiteName: name)!
        value.set(sources, forKey: NewsStore.Keys.sources)
        value.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        value.set(vendors, forKey: NewsStore.Keys.vendors)
        value.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.knownVendors)
        value.set(now.addingTimeInterval(-60 * 86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
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
    private func model(_ id: String = "lab/model", created: Date? = nil) -> ModelRelease {
        .init(id: id, name: id, vendor: "lab", created: created ?? now, contextLength: nil,
              promptPrice: nil, completionPrice: nil, expires: nil)
    }

    func testMalformedModelIDsDoNotDiscardAValidSibling() throws {
        let ids = ["", ":", ":free", "/model", "lab/", "missing-slash", "lab/model"]
        let items = ids.map { ["id": $0, "created": 1_800_000_000] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["data": items])
        XCTAssertEqual(try ModelFeed.releases(from: data).map(\.id), ["lab/model"])
        XCTAssertEqual(try ModelFeed.releases(from: Data("{\"data\":[]}".utf8)), [])
    }

    func testInvalidModelContextValuesRemainUnknown() throws {
        let invalid: [Any] = ["NaN", "Infinity", "-Infinity", 1e100, Double(Int.max), -1, 2.5, true]
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: ["data": [["id": "lab/model", "created": 1_800_000_000, "context_length": value]]])
            let release = try XCTUnwrap(ModelFeed.releases(from: data).first)
            XCTAssertNil(release.contextLength, "Invalid optional context: \(value)")
        }
        let data = Data("{\"data\":[{\"id\":\"lab/model\",\"created\":1800000000,\"context_length\":\"1000000\"}]}".utf8)
        XCTAssertEqual(try ModelFeed.releases(from: data).first?.contextLength, 1_000_000)
    }

    func testMalformedModelDatesAndPricesRemainUnknown() throws {
        let data = Data("""
        {"data":[
          {"id":"lab/bad-created","created":"Infinity"},
          {"id":"lab/huge-created","created":1e100},
          {"id":"lab/model","created":1800000000,"expiration_date":"Infinity","pricing":{"prompt":"NaN","completion":"1e300"}},
          {"id":"lab/negative","created":1800000000,"pricing":{"prompt":"-1","completion":"Infinity"}},
          {"id":"lab/valid","created":1800000000,"pricing":{"prompt":"0","completion":"0.000004"}}
        ]}
        """.utf8)
        let releases = try ModelFeed.releases(from: data)
        XCTAssertEqual(Set(releases.map(\.id)), ["lab/model", "lab/negative", "lab/valid"])
        let malformed = try XCTUnwrap(releases.first { $0.id == "lab/model" })
        XCTAssertNil(malformed.expires)
        XCTAssertNil(malformed.promptPrice)
        XCTAssertNil(malformed.completionPrice)
        let negative = try XCTUnwrap(releases.first { $0.id == "lab/negative" })
        XCTAssertNil(negative.promptPrice)
        XCTAssertNil(negative.completionPrice)
        let valid = try XCTUnwrap(releases.first { $0.id == "lab/valid" })
        XCTAssertEqual(valid.promptPrice, 0)
        XCTAssertEqual(valid.completionPrice, 4)
    }

    func testEntirelyMalformedModelCatalogRetainsThePreviousCache() async {
        var cache = NewsCache()
        cache.models = [model()]
        cache.modelsFetchedAt = now.addingTimeInterval(-60)
        stub { _ in (200, Data("{\"data\":[{\"id\":\"\",\"created\":1800000000},{\"id\":\":\",\"created\":1800000000}]}".utf8)) }
        let result = await NewsFetcher.refresh(cache, sources: [], following: ["lab"], now: now, forcedSources: [ModelFeed.id])
        XCTAssertEqual(result.cache.models, cache.models)
        XCTAssertEqual(result.cache.modelsFetchedAt, cache.modelsFetchedAt)
        XCTAssertEqual(result.cache.modelsFailedAt, now)
        XCTAssertTrue(result.cache.unreadable?.contains(ModelFeed.id) == true)
        XCTAssertTrue(result.newModels.isEmpty)
    }

    @MainActor func testOwnerPolicyBlocksManualRetryAndAutomaticFollows() async throws {
        let calls = LockedBox(0)
        let news = NewsStore(defaults: defaults(), directory: nil, now: now, fetch: {
            calls.value += 1
            return .init(cache: $0.cache, newModels: [])
        }, notify: { _, _, _ in XCTFail("Disabled News must not notify") })
        news.allowsRefresh = { false }
        await news.refresh(maxAge: 0, preferences: AlertPreferences())
        await news.retrySources([ModelFeed.id])
        news.followedSources.insert("devin")
        news.followedVoices.insert(try XCTUnwrap(NewsVoice.catalog.compactMap(\.feed).first).id)
        news.followedStatusSources.insert(try XCTUnwrap(NewsStatusSource.catalog.first).id)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(news.isRefreshing)
        XCTAssertTrue(news.followedSources.contains("devin"), "Following is still saved while dispatch is disabled")
    }

    @MainActor func testMacOwnerBlocksQueuedFollowRetryAndManualPassThenAllowsReenable() async throws {
        let calls = LockedBox<[NewsFetcher.Request]>([])
        let gate = SecondQANewsGate()
        let prefs = defaults()
        let news = NewsStore(defaults: prefs, directory: nil, now: now, fetch: { request in
            calls.value.append(request)
            if calls.value.count == 1 { await gate.pause() }
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        let settings = AppSettings(defaults: prefs)
        settings.newsEnabled = true
        let owner = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: folder()), news: news)
        let first = Task { await owner.refreshNews(force: true, now: self.now) }
        await gate.waitUntilPaused()
        news.followedSources.insert("devin")
        for _ in 0..<100 { await Task.yield() }
        await news.retrySources(["devin"])
        await owner.refreshNews(force: true, now: now)
        settings.newsEnabled = false
        await gate.release()
        await first.value
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertFalse(news.isRefreshing)
        settings.newsEnabled = true
        await owner.refreshNews(force: true, now: now)
        XCTAssertEqual(calls.value.count, 2)
        XCTAssertEqual(calls.value.last?.forcedSources, [], "Disabled queued intent must not leak into a later pass")
    }

    @MainActor func testQueuedRetryInheritsLivePassPermissionWithoutAnOwnerPolicy() async {
        let enabled = LockedBox(true)
        let calls = LockedBox(0)
        let gate = SecondQANewsGate()
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: {
            calls.value += 1
            if calls.value == 1 { await gate.pause() }
            return .init(cache: $0.cache, newModels: [])
        }, notify: { _, _, _ in })
        let live = Task {
            await news.keepCurrent(preferences: { AlertPreferences() }, isAllowed: { enabled.value },
                                   sleep: { _ in throw CancellationError() })
        }
        await gate.waitUntilPaused()
        await news.retrySources([ModelFeed.id])
        enabled.value = false
        await gate.release()
        await live.value
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(news.isRefreshing)
    }

    func testDisablingDuringModelGETDoesNotStartFeedGETOrRecordItsFailure() async {
        let enabled = LockedBox(true)
        let source = FeedSource.catalog[0]
        var cache = NewsCache()
        cache.items[source.id] = [FeedItem(id: "retained", title: "Retained", source: source.name)]
        cache.sourceChecks = [source.id: .init(succeededAt: now.addingTimeInterval(-60), failedAt: now.addingTimeInterval(-30))]
        cache.announcementsFailedAt = now.addingTimeInterval(-30)
        cache.unreadable = [source.id]
        stub { request in
            if request.url == ModelFeed.url {
                enabled.value = false
                return (200, Data("{\"data\":[]}".utf8))
            }
            return (200, Data("<rss><channel/></rss>".utf8))
        }
        let result = await NewsFetcher.refresh(cache, sources: [source], following: [], maxAge: 0, now: now, isAllowed: { enabled.value })
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [ModelFeed.url])
        XCTAssertEqual(result.cache.items[source.id], cache.items[source.id])
        XCTAssertEqual(result.cache.sourceChecks?[source.id], cache.sourceChecks?[source.id])
        XCTAssertEqual(result.cache.announcementsFailedAt, cache.announcementsFailedAt)
        XCTAssertTrue(result.cache.unreadable?.contains(source.id) == true)
    }

    @MainActor func testArchiveModelsDoNotIncreaseNewCountOrNewsBadge() {
        let date = Date.now
        var cache = NewsCache()
        cache.models = [model("lab/recent", created: date.addingTimeInterval(-86_400)), model("lab/archive", created: date.addingTimeInterval(-20 * 86_400))]
        let prefs = defaults(vendors: ["lab"])
        prefs.set(date.addingTimeInterval(-60 * 86_400).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: prefs, directory: folder(cache), now: date,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(news.unseenModelCount, 1)
        XCTAssertEqual(news.unseenCount, 1)
        XCTAssertEqual(news.models().count, 2, "Archive remains available")
        let edition = NewsEditions.today(models: news.models(), announcements: [], retiring: [], since: news.seenAt, now: date)
        XCTAssertEqual(news.unseenModelCount(now: date), edition.digest.models)
        XCTAssertEqual(news.unseenCount(now: date), 1)
        XCTAssertEqual(news.unseenCount(now: date.addingTimeInterval(20 * 86_400)), 0, "The combined badge uses its supplied render date")
        let boundary = model(created: date.addingTimeInterval(-NewsEditions.topStoryAge))
        XCTAssertTrue(NewsEditions.isRecentModel(boundary, now: date))
        XCTAssertFalse(NewsEditions.isRecentModel(boundary, now: date.addingTimeInterval(1)))
    }

    @MainActor func testRejectedSkillRowsPreserveRankThroughSearchDetailsAndSavedReopen() throws {
        let data = Data("""
        {"items":[
          {"slug":"ownerless","displayName":"Rejected"},
          {"ownerHandle":"alice","slug":"first","displayName":"First"},
          {"ownerHandle":"alice","slug":"first","displayName":"Duplicate"},
          {"ownerHandle":"bob","slug":"second","displayName":"Second"}
        ]}
        """.utf8)
        let page = try SkillFeed.parse(data)
        XCTAssertEqual(page.listings.map(\.sourceRank), [2, 4])
        let result = try XCTUnwrap(page.listings.first { NewsSearch.matches("Second", title: $0.name, source: $0.owner) })
        let directory = folder()
        let library = NewsLibrary(directory: directory)
        let detail = SkillListingDetail(item: result, sort: .trending, checkedAt: now, library: library)
        XCTAssertEqual(detail.item.rankText, "Rank 4")
        XCTAssertTrue(library.save(result.bookmark(sort: .trending, checkedAt: now, now: now)))
        let reopened = NewsLibrary(directory: directory)
        XCTAssertEqual(reopened.saved.first?.skill?.ranking, "Trending · 7 days · Rank 4")
        XCTAssertEqual(reopened.saved.first?.skill?.checkedAt, now)
    }

    func testLegacySkillWithoutSourceRankDoesNotInventOne() throws {
        let data = Data("{\"owner\":\"alice\",\"slug\":\"first\",\"name\":\"First\",\"requirements\":[]}".utf8)
        let item = try JSONDecoder().decode(SkillListing.self, from: data)
        XCTAssertNil(item.sourceRank)
        XCTAssertEqual(item.bookmark(sort: .downloads, checkedAt: now).skill?.ranking, "Most downloaded · Rank not supplied")
    }

    @MainActor func testPrimarySourceHealthIncludesFailedPairedFeedAndTargetsItsRetry() async throws {
        let primary = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code" })
        let child = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code-releases" })
        var cache = NewsCache()
        cache.items[primary.id] = []
        cache.items[child.id] = [FeedItem(id: "retained", title: "Retained", source: child.name)]
        cache.sourceChecks = [primary.id: .init(succeededAt: now), child.id: .init(succeededAt: now.addingTimeInterval(-60), failedAt: now)]
        let calls = LockedBox<[NewsFetcher.Request]>([])
        let news = NewsStore(defaults: defaults(sources: [primary.id]), directory: folder(cache), fetch: {
            calls.value.append($0)
            return .init(cache: $0.cache, newModels: [])
        }, notify: { _, _, _ in })
        let health = news.sourceHealth(for: primary)
        XCTAssertEqual(health.sourceIDs, [primary.id, child.id])
        XCTAssertEqual(health.sourceCount, 2)
        XCTAssertEqual(health.checkedAt, now.addingTimeInterval(-60))
        XCTAssertNotNil(health.problem)
        XCTAssertEqual(health.retryIDs, [child.id])
        XCTAssertEqual(news.collectionHealth(for: .release, sourceID: primary.id).sourceIDs, health.sourceIDs)
        await news.retrySources(health.retryIDs)
        XCTAssertEqual(calls.value.last?.forcedSources, [child.id])
    }
}

private actor SecondQANewsGate {
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            paused = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        blocked?.resume()
        blocked = nil
    }
}
