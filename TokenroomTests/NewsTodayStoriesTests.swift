import XCTest
@testable import Tokenroom

final class NewsTodayStoriesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_176_000)

    private func item(_ id: String, _ title: String, source: String = "Feed", kind: NewsSourceKind?) -> FeedItem {
        FeedItem(id: id, title: title, published: now, source: source, sourceID: source.lowercased(), kind: kind)
    }

    private func earlierStories(_ items: [FeedItem], collection: NewsCollection?, query: String = "") -> [FeedItem] {
        items.filter { item in
            let kind = item.kind ?? .officialAnnouncement
            let matches: Bool
            switch collection {
            case .release: matches = kind == .officialAnnouncement
            case .voice: matches = kind == .commentary
            case .status: matches = kind == .officialStatus
            case .model, .retirement: matches = false
            case nil: matches = true
            }
            return matches && NewsSearch.matches(query, title: item.displayTitle, source: item.source)
        }
    }

    func testTodayGivesEachSectionTheStoriesItHadFromItsOwnPass() {
        let items = [
            item("a", "0.157.0", source: "Codex", kind: .officialAnnouncement),
            item("b", "A note on agents", source: "Voice", kind: .commentary),
            item("c", "Elevated errors", source: "Status", kind: .officialStatus),
            item("d", "Add discernment skill (#1553)", source: "Skills", kind: nil),
            item("e", "Second note", source: "Voice", kind: .commentary),
            item("f", "Resolved", source: "Status", kind: .officialStatus),
        ]
        let today = NewsDiscovery.today(items)
        XCTAssertEqual(today.releases, earlierStories(items, collection: .release))
        XCTAssertEqual(today.voices, earlierStories(items, collection: .voice))
        XCTAssertEqual(today.status, earlierStories(items, collection: .status))
        XCTAssertEqual(today.releases.map(\.id), ["a", "d"], "An item without a kind is an official announcement")
        XCTAssertEqual(today.voices.map(\.id), ["b", "e"])
        XCTAssertEqual(today.status.map(\.id), ["c", "f"])
    }

    func testABlankQueryKeepsTheCollectionAndASearchStillReadsTheShownTitle() {
        let items = [
            item("a", "0.157.0", source: "Codex", kind: .officialAnnouncement),
            item("b", "Add discernment skill (#1553)", source: "Skills", kind: .officialAnnouncement),
            item("c", "A note on agents", source: "Voice", kind: .commentary),
        ]
        for collection in [NewsCollection?.none, .release, .voice, .status, .model, .retirement] {
            for query in ["", "   ", "\n\t", "codex 0.157", "(#1553)", "skill", "voice", "  Codex  "] {
                XCTAssertEqual(NewsDiscovery.stories(items, collection: collection, query: query),
                               earlierStories(items, collection: collection, query: query),
                               "\(collection?.rawValue ?? "all") “\(query)”")
            }
        }
        XCTAssertEqual(NewsDiscovery.stories(items, query: "codex 0.157").map(\.id), ["a"], "A bare version is found under the name it's shown with")
        XCTAssertTrue(NewsDiscovery.stories(items, query: "(#1553)").isEmpty, "A pull request number isn't shown, so it isn't searched")
    }

    @MainActor
    func testTodayReadsTheStoresAnnouncementsOnce() throws {
        var cache = NewsCache()
        let sources = FeedSource.catalog + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
        for source in sources {
            cache.items[source.id] = (0..<4).map {
                FeedItem(id: "\(source.id)-\($0)", title: "\(source.id) update \($0)", published: now.addingTimeInterval(-Double($0) * 3600), source: source.name)
            }
        }
        let suite = "tokenroom.tests.today-stories." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        defaults.set(NewsVoice.catalog.compactMap(\.feed).map(\.id), forKey: NewsStore.Keys.voices)
        defaults.set(NewsStatusSource.catalog.map(\.id), forKey: NewsStore.Keys.status)
        let news = NewsStore(defaults: defaults, directory: nil, now: now, initialCache: cache,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })

        let today = NewsDiscovery.today(news.allAnnouncements)
        XCTAssertEqual(today.releases, earlierStories(news.allAnnouncements, collection: .release))
        XCTAssertEqual(today.voices, earlierStories(news.allAnnouncements, collection: .voice))
        XCTAssertEqual(today.status, earlierStories(news.allAnnouncements, collection: .status))
        XCTAssertFalse(today.releases.isEmpty)
        XCTAssertFalse(today.voices.isEmpty)
        XCTAssertFalse(today.status.isEmpty)
        XCTAssertEqual(today.releases.count + today.voices.count + today.status.count, news.allAnnouncements.count, "Every announcement has one section")
    }
}
