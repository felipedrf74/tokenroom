import XCTest
@testable import Tokenroom

final class NewsSourceContractTests: XCTestCase {
    @MainActor func testFoldedIdentitySurvivesWinnerChangeAndFirstFeedRotation() async throws {
        let primary = FeedSource.catalog.first { $0.id == "claude-code" }!
        let secondary = FeedSource.catalog.first { $0.id == "claude-code-releases" }!
        let sources = [primary, secondary]
        var cache = NewsCache()
        cache.modelsFetchedAt = Date(timeIntervalSince1970: 100)
        let a = FeedItem(id: "a", title: "Feature announcement", link: URL(string: "https://example.com/feature"), published: Date(timeIntervalSince1970: 10), source: "Claude Code")
        cache.items[primary.id] = [a]
        let initial = try XCTUnwrap(cache.announcements(from: sources).first)
        let library = NewsLibrary(directory: nil)
        XCTAssertTrue(library.save(initial.bookmark()))
        library.markRead(id: initial.stableID, aliases: initial.aliasIDs)
        let b = FeedItem(id: "b", title: "Feature announcement", link: a.link, published: Date(timeIntervalSince1970: 20), source: "Claude Code")
        cache.items[secondary.id] = [b]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.items[secondary.id] = []
        cache.save(to: directory)
        let suite = "tokenroom.tests.rotation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calls = LockedBox(0)
        let news = NewsStore(defaults: defaults, directory: directory, fetch: { request in
            calls.value += 1
            var result = request.cache
            result.items[secondary.id] = NewsFetcher.firstSeen([b], previous: result.items[secondary.id] ?? [], now: request.now)
            if calls.value > 1 { result.items[primary.id] = [] }
            return .init(cache: result, newModels: [])
        }, notify: { _, _, _ in })
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: Date(timeIntervalSince1970: 100))
        let winner = try XCTUnwrap(news.allAnnouncements.first)
        XCTAssertTrue(library.isSaved(id: winner.stableID, aliases: winner.aliasIDs))
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: Date(timeIntervalSince1970: 200))
        let rotated = try XCTUnwrap(NewsCache.load(from: directory).announcements(from: sources).first)
        XCTAssertTrue(library.isSaved(id: rotated.stableID, aliases: rotated.aliasIDs))
        XCTAssertTrue(library.isRead(id: rotated.stableID, aliases: rotated.aliasIDs))
        XCTAssertEqual(rotated.newsDate, initial.newsDate)
    }
    private func source(_ id: String) -> FeedSource {
        FeedSource(id: id, name: "Same publisher name", url: URL(string: "https://example.com/\(id)")!, provider: nil)
    }

    func testSameGUIDFromTwoPublishersStaysDistinct() {
        let a = source("one"), b = source("two")
        var cache = NewsCache()
        cache.items = [a.id: [FeedItem(id: "guid", title: "One", source: a.name)], b.id: [FeedItem(id: "guid", title: "Two", source: b.name)]]
        let items = cache.announcements(from: [a, b])
        XCTAssertEqual(Set(items.map(\.stableID)).count, 2)
    }

    func testSameNamedVoicesStayDistinct() {
        let a = source("one"), b = source("two")
        var cache = NewsCache()
        cache.items = [a.id: [FeedItem(id: "a", title: "Shared title", source: a.name)], b.id: [FeedItem(id: "b", title: "Shared title", source: b.name)]]
        XCTAssertEqual(Set(cache.announcements(from: [a, b]).compactMap(\.sourceID)), ["one", "two"])
    }

    func testStatusRepeatedTitleAndUpdatesSurvive() {
        var feed = source("status")
        feed.kind = .officialStatus
        let xml = "<feed><entry><id>a</id><title>Service update</title><updated>2026-10-10T10:00:00Z</updated></entry><entry><id>b</id><title>Service update</title><updated>2026-10-10T11:00:00Z</updated></entry></feed>"
        XCTAssertEqual(FeedParser.items(from: Data(xml.utf8), source: feed).count, 2)
    }

    /// Losing prior incident observations, duplicating a repeated check, or using its
    /// newest update as its publication/first-seen date must fail this contract.
    func testStatusKeepsFiveDistinctObservedUpdatesWithoutChangingOriginalDates() throws {
        var feed = source("status")
        feed.kind = .officialStatus
        let published = Date(timeIntervalSince1970: 1_800_000_000)
        let observed = published.addingTimeInterval(3600)
        var previous: [FeedItem] = []
        for index in 0...6 {
            let xml = """
            <feed><entry><id>incident</id><title>Service update</title>
            <published>\(published.ISO8601Format())</published>
            <updated>\(observed.addingTimeInterval(Double(index) * 60).ISO8601Format())</updated>
            <summary>Observed update \(index)</summary></entry></feed>
            """
            previous = NewsFetcher.firstSeen(FeedParser.items(from: Data(xml.utf8), source: feed), previous: previous,
                                             now: observed.addingTimeInterval(Double(index) * 60))
        }
        let incident = try XCTUnwrap(previous.first)
        XCTAssertEqual(incident.publisherPublishedAt, published)
        XCTAssertEqual(incident.firstSeenAt, published)
        XCTAssertEqual(incident.updatedAt, observed.addingTimeInterval(360))
        XCTAssertEqual(incident.observedUpdates?.compactMap(\.date), [
            observed.addingTimeInterval(360), observed.addingTimeInterval(300),
            observed.addingTimeInterval(240), observed.addingTimeInterval(180),
            observed.addingTimeInterval(120),
        ])
        XCTAssertEqual(incident.observedUpdates?.compactMap(\.excerpt), [
            "Observed update 6", "Observed update 5", "Observed update 4", "Observed update 3", "Observed update 2",
        ])
        let replay = NewsFetcher.firstSeen(previous, previous: previous, now: observed.addingTimeInterval(420))
        XCTAssertEqual(replay.first?.observedUpdates, incident.observedUpdates)
        XCTAssertEqual(replay.first?.firstSeenAt, published)
        XCTAssertEqual(try JSONDecoder().decode([FeedItem].self, from: JSONEncoder().encode(replay)), replay)
    }

    func testMissingPublishedStaysMissing() {
        let xml = "<feed><entry><id>a</id><title>Service update</title><updated>2026-10-10T10:00:00Z</updated></entry></feed>"
        let item = FeedParser.items(from: Data(xml.utf8), source: source("voice")).first!
        XCTAssertNil(item.publisherPublishedAt)
        XCTAssertNil(item.published)
        XCTAssertEqual(item.updatedAt, FeedParser.date("2026-10-10T10:00:00Z"))
    }

    @MainActor func testFirstVoiceFetchDoesNotMarkArchiveNew() async {
        let suite = "tokenroom.tests.legacy-news." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let voice = NewsVoice.catalog.first!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = NewsStore(defaults: defaults, directory: nil, fetch: { request in
            var cache = request.cache
            cache.items[voice.feed!.id] = [FeedItem(id: "archive", title: "Earlier article", published: now, source: voice.name)]
            cache.announcementsFetchedAt = request.now
            return .init(cache: cache, newModels: [])
        }, notify: { _, _, _ in XCTFail("Voice must never notify") })
        store.followedVoices = [voice.id]
        await store.refresh(preferences: AlertPreferences(), now: now)
        XCTAssertEqual(store.unseenCount, 0)
        XCTAssertFalse(store.isNew(store.allAnnouncements.first?.firstSeenAt))
        XCTAssertFalse(store.sources.contains { $0.id == "voice-embirico" })
    }

    @MainActor func testLegacyDatesAndFollowsMigrateWithoutNewBadge() {
        let suite = "tokenroom.tests.legacy-migration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["codex-releases"], forKey: NewsStore.Keys.sources)
        defaults.set(Array(NewsStore.firstCatalog), forKey: NewsStore.Keys.knownSources)
        defaults.set(1_800_000_000.0, forKey: NewsStore.Keys.seenAt)
        var cache = NewsCache()
        cache.items["codex-releases"] = [FeedItem(id: "old", title: "1.0", published: Date(timeIntervalSince1970: 1_799_000_000), source: "Codex")]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        cache.save(to: folder)
        let store = NewsStore(defaults: defaults, directory: folder, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(store.followedSources, ["codex-releases"])
        XCTAssertTrue(store.followedVoices.isEmpty)
        XCTAssertTrue(store.followedStatusSources.isEmpty)
        XCTAssertEqual(store.unseenCount, 0)
        XCTAssertEqual(store.allAnnouncements.first?.sourceID, "codex-releases")
    }

    func testPairedReleaseWinnerKeepsCanonicalIdentityAndAliases() {
        let sources = FeedSource.catalog.filter { $0.id == "claude-code" || $0.partOf == "claude-code" }
        var cache = NewsCache()
        cache.items["claude-code"] = [FeedItem(id: "changelog", title: "Claude Code 2.1.0", published: Date(timeIntervalSince1970: 10), source: "Claude Code")]
        let first = cache.announcements(from: sources).first!
        cache.items["claude-code-releases"] = [FeedItem(id: "github", title: "v2.1.0", published: Date(timeIntervalSince1970: 20), source: "Claude Code")]
        let second = cache.announcements(from: sources).first!
        XCTAssertEqual(first.stableID, second.stableID)
        XCTAssertTrue(second.aliasIDs.contains("claude-code|changelog"))
        XCTAssertTrue(second.aliasIDs.contains("claude-code-releases|github"))
    }
}
