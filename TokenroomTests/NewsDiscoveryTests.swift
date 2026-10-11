import XCTest
@testable import Tokenroom

final class NewsDiscoveryTests: XCTestCase {
    /// Treating a profile-only follow as a feed would fetch or badge an invented timeline.
    @MainActor func testProfileOnlyFollowDoesNotFetchBadgeOrNotify() async throws {
        let suite = "tokenroom.tests.profile-only." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = LockedBox<[NewsFetcher.Request]>([])
        let notifications = LockedBox(0)
        let news = NewsStore(defaults: defaults, directory: nil, now: now, fetch: { request in
            requests.value.append(request)
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in notifications.value += 1 })
        let voice = try XCTUnwrap(NewsVoice.catalog.first { $0.feed == nil })
        let cache = news.cache
        let unread = news.unseenCount
        news.followedVoices.insert(voice.id)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(news.followedVoices.contains(voice.id))
        XCTAssertFalse(news.sources.contains { $0.id == voice.id })
        XCTAssertTrue(requests.value.isEmpty)
        XCTAssertEqual(news.cache, cache)
        XCTAssertEqual(news.unseenCount, unread)
        XCTAssertEqual(notifications.value, 0)
    }

    /// A catalog re-ranking must update Skills without changing News or scheduling its alerts.
    @MainActor func testSkillRankMovementDoesNotFetchBadgeOrNotifyNews() async throws {
        let suite = "tokenroom.tests.skill-news-isolation." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = LockedBox(0)
        let notifications = LockedBox(0)
        let news = NewsStore(defaults: defaults, directory: nil, now: now, fetch: { request in
            requests.value += 1
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in notifications.value += 1 })
        let calls = LockedBox(0)
        let skills = SkillsStore(fetch: { _ in
            calls.value += 1
            let first = "{\"ownerHandle\":\"alice\",\"slug\":\"search\",\"displayName\":\"Search\"}"
            let second = "{\"ownerHandle\":\"bob\",\"slug\":\"search\",\"displayName\":\"Other search\"}"
            let items = calls.value == 1 ? first + "," + second : second + "," + first
            return .body(Data(("{\"items\":[" + items + "]}").utf8))
        }, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        let cache = news.cache
        let unread = news.unseenCount
        let seen = news.seenAt
        await skills.refresh(sort: .trending, force: true)
        XCTAssertEqual(skills.listings.map(\.id), ["alice/search", "bob/search"])
        await skills.refresh(sort: .trending, force: true)
        XCTAssertEqual(skills.listings.map(\.id), ["bob/search", "alice/search"])
        XCTAssertEqual(news.cache, cache)
        XCTAssertEqual(news.seenAt, seen)
        XCTAssertEqual(news.unseenCount, unread)
        XCTAssertEqual(requests.value, 0)
        XCTAssertEqual(notifications.value, 0)
    }

    @MainActor func testSourceDetailIncludesPairedWinnersAndFoldedAliases() throws {
        let primary = FeedSource.catalog.first { $0.id == "claude-code" }!
        let child = FeedItem(id: "child", title: "Release", published: now, source: "Claude Code", sourceID: "claude-code-releases", kind: .officialAnnouncement)
        let folded = FeedItem(id: "other", title: "Shared announcement", published: now, source: "Codex", sourceID: "codex-releases", kind: .officialAnnouncement, aliases: ["claude-code|original"])
        let unrelated = FeedItem(id: "other", title: "Unrelated", published: now, source: "Voice", sourceID: "voice-simonw", kind: .commentary)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "tokenroom.tests.source-detail." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var cache = NewsCache()
        cache.items["claude-code-releases"] = [child]
        cache.items["codex-releases"] = [folded]
        cache.items["voice-simonw"] = [unrelated]
        cache.save(to: directory)
        let news = NewsStore(defaults: defaults, directory: directory, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let detail = NewsSourceDetail(news: news, library: NewsLibrary(directory: nil), source: primary)
        XCTAssertEqual(detail.items.map(\.title), ["Release", "Shared announcement"])

    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func model(_ age: Double) -> ModelRelease {
        .init(id: "lab/model-\(age)", name: "Model", vendor: "lab", created: now.addingTimeInterval(-age * 86400), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
    }
    func testLatestOfficialLeadsAndStatusStaysSeparate() {
        let status = FeedItem(id: "status", title: "Service report", published: now, source: "Provider", kind: .officialStatus)
        let voice = FeedItem(id: "voice", title: "Analysis", published: now, source: "Voice", kind: .commentary)
        let release = FeedItem(id: "release", title: "Release", published: now.addingTimeInterval(-100), source: "Tool", kind: .officialAnnouncement)
        XCTAssertEqual(NewsDiscovery.latestOfficial([status, voice, release], now: now)?.id, "release")
        XCTAssertEqual(NewsDiscovery.stories([status, voice, release], collection: .status).map(\.id), ["status"])
        XCTAssertNil(NewsDiscovery.latestOfficial([voice, status], now: now))
    }
    func testOldModelsExcludedFromNewShelf() {
        let edition = NewsEditions.today(models: [model(1), model(20)], announcements: [], retiring: [], since: now.addingTimeInterval(-30 * 86400), now: now)
        XCTAssertEqual(edition.topStory?.id, "lab/model-1.0")
        XCTAssertTrue(edition.moreModels.isEmpty)
        XCTAssertEqual(edition.digest.models, 1)
    }
    @MainActor func testSearchFindsRetainedQuietSourceBeyondGlobalCap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cache = NewsCache()
        for source in FeedSource.catalog {
            cache.items[source.id] = (0..<30).map { FeedItem(id: "\($0)", title: "\(source.id) update \($0)", published: now, source: source.name) }
        }
        cache.items["devin"] = [FeedItem(id: "quiet", title: "Find this quiet article", published: now.addingTimeInterval(-1000), source: "Devin")]
        cache.save(to: folder)
        let suite = "tokenroom.tests.quiet-source." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        defaults.set([], forKey: NewsStore.Keys.vendors)
        defaults.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.knownVendors)
        let news = NewsStore(defaults: defaults, directory: folder, now: now,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertFalse(news.announcements.contains { $0.id == "quiet" })
        XCTAssertEqual(NewsDiscovery.stories(news.allAnnouncements, query: "quiet").map(\.id), ["quiet"])
    }
    func testBookmarkKeepsOriginalDatesAndSkillRankSnapshot() {
        let item = FeedItem(id: "a", title: "Title", published: now.addingTimeInterval(-100), source: "Voice", publisherPublishedAt: now, excerpt: "Real excerpt")
        XCTAssertEqual(item.bookmark(now: now).publishedAt, now)
        let skill = SkillListing(owner: "owner", slug: "tool", name: "Tool", summary: nil, version: "1.0", updatedAt: nil, downloads: nil, stars: nil, requirements: [], sourceRank: 2)
        let saved = skill.bookmark(sort: .trending, checkedAt: now)
        XCTAssertEqual(saved.skill?.ranking, "Trending · 7 days · Rank 2")
        XCTAssertEqual(saved.skill?.checkedAt, now)
    }
}
