import XCTest
@testable import Tokenroom

final class MacNewsPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var sources: [FeedSource] {
        [.init(id: "healthy", name: "Healthy", url: URL(string: "https://example.org/healthy.xml")!),
         .init(id: "delayed", name: "Delayed", url: URL(string: "https://example.org/delayed.xml")!)]
    }

    func testFailedOldFeedDoesNotMakeHealthySourcesAppearStale() {
        var cache = NewsCache()
        cache.sourceChecks = [
            "healthy": .init(succeededAt: now.addingTimeInterval(-300)),
            "delayed": .init(succeededAt: now.addingTimeInterval(-36_000), failedAt: now.addingTimeInterval(-300))
        ]
        let summary = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.delayedCount, 1)
        XCTAssertEqual(summary.unloadedCount, 0)
        XCTAssertEqual(summary.failedIDs, ["delayed"])
    }

    func testRecoveredFeedBecomesCurrentWithoutChangingOtherChecks() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-300)),
                              "delayed": .init(succeededAt: now)]
        let summary = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(summary.currentCount, 2)
        XCTAssertEqual(summary.delayedCount, 0)
        XCTAssertTrue(summary.failedIDs.isEmpty)
    }

    func testFirstFailureIsUnloadedAndRetryableRatherThanRetained() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(failedAt: now)]
        let summary = NewsSourceFreshness(cache: cache, sources: [sources[0]], now: now)
        XCTAssertEqual(summary.currentCount, 0)
        XCTAssertEqual(summary.delayedCount, 0)
        XCTAssertEqual(summary.unloadedCount, 1)
        XCTAssertEqual(summary.failedIDs, ["healthy"])
    }

    func testSuccessfulEmptyFeedAndLegacyCacheStillCountAsChecked() {
        var cache = NewsCache()
        cache.items = ["healthy": []]
        cache.announcementsFetchedAt = now.addingTimeInterval(-300)
        let summary = NewsSourceFreshness(cache: cache, sources: [sources[0]], now: now)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.unloadedCount, 0)
    }

    func testScopeDeduplicatesSourcesAndExcludesUnfollowedAndModelFailures() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(succeededAt: now), "delayed": .init(failedAt: now)]
        cache.unreadable = ["delayed", ModelFeed.id]
        let summary = NewsSourceFreshness(cache: cache, sources: [sources[0], sources[0]], now: now)
        XCTAssertEqual(summary.totalCount, 1)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertTrue(summary.failedIDs.isEmpty)
    }

    func testAgedAndFutureChecksDoNotClaimCurrentData() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-901)),
                              "delayed": .init(succeededAt: now.addingTimeInterval(30))]
        let summary = NewsSourceFreshness(cache: cache, sources: sources, now: now, currentInterval: 900)
        XCTAssertEqual(summary.currentCount, 0)
        XCTAssertEqual(summary.delayedCount, 2)
    }

    func testBoundaryAndOlderFailurePreserveNewerSuccess() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-900), failedAt: now.addingTimeInterval(-1800))]
        let summary = NewsSourceFreshness(cache: cache, sources: [sources[0]], now: now, currentInterval: 900)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertTrue(summary.failedIDs.isEmpty)
    }

    func testEmptyBriefingWaitsUntilASourceHasAnswered() {
        var cache = NewsCache()
        let unchecked = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(unchecked.briefing(isChecking: false, modelsCheckedAt: now, modelsFailed: false), .waiting)
        XCTAssertEqual(unchecked.briefing(isChecking: true, modelsCheckedAt: now, modelsFailed: false), .waiting)
        XCTAssertEqual(unchecked.uncheckedIDs, ["healthy", "delayed"])
        XCTAssertEqual(unchecked.caption, "2 sources not checked yet")

        cache.sourceChecks = ["healthy": .init(failedAt: now), "delayed": .init(failedAt: now)]
        let failed = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(failed.briefing(isChecking: false, modelsCheckedAt: now, modelsFailed: false), .couldNotCheck)
        XCTAssertEqual(failed.briefing(isChecking: true, modelsCheckedAt: now, modelsFailed: false), .waiting)
        XCTAssertEqual(NewsEmptyBriefing.couldNotCheck.title, "Couldn't check your sources")
        XCTAssertEqual(NewsEmptyBriefing.couldNotCheck.actionTitle, "Retry")
        XCTAssertEqual(failed.caption, "No sources checked successfully yet")

        cache.sourceChecks = ["delayed": .init(failedAt: now)]
        let mixed = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(mixed.uncheckedIDs, ["healthy", "delayed"])
        XCTAssertEqual(mixed.caption, "No sources checked successfully yet")
        XCTAssertEqual(NewsSourceFreshness(cache: cache, sources: [sources[0]], now: now).caption, "1 source not checked yet")

        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-60)), "delayed": .init(failedAt: now)]
        let answered = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(answered.briefing(isChecking: false, modelsCheckedAt: nil, modelsFailed: true), .quiet)
        XCTAssertNil(NewsEmptyBriefing.quiet.actionTitle)

        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-7200), failedAt: now), "delayed": .init(succeededAt: now.addingTimeInterval(-7200), failedAt: now)]
        let outage = NewsSourceFreshness(cache: cache, sources: sources, now: now)
        XCTAssertEqual(outage.briefing(isChecking: false, modelsCheckedAt: now, modelsFailed: false), .couldNotCheck, "Answered once is not answering now")
        XCTAssertEqual(outage.failedIDs, ["healthy", "delayed"])
    }

    func testEmptyBriefingWithNoFeedsFollowedFollowsTheModelList() {
        let summary = NewsSourceFreshness(cache: NewsCache(), sources: [], now: now)
        XCTAssertEqual(summary.briefing(isChecking: false, modelsCheckedAt: nil, modelsFailed: false), .waiting)
        XCTAssertEqual(summary.briefing(isChecking: false, modelsCheckedAt: nil, modelsFailed: true), .couldNotCheck)
        XCTAssertEqual(summary.briefing(isChecking: false, modelsCheckedAt: now, modelsFailed: false), .quiet)
        XCTAssertEqual(summary.briefing(isChecking: false, modelsCheckedAt: now, modelsFailed: true), .couldNotCheck, "An earlier model list doesn't hide a failed one")
    }

    @MainActor
    func testStoreOffersAFirstCheckOfEverySourceNotYetRead() {
        let suite = TestDefaults.make(owner: "MacNewsPresentation", index: 1)
        defer { TestDefaults.remove(suite.name) }
        var cache = NewsCache()
        cache.sourceChecks = ["claude-code": .init(failedAt: now)]
        let news = NewsStore(defaults: suite.defaults, directory: nil, now: now, initialCache: cache,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let summary = NewsSourceFreshness(cache: news.cache, sources: news.sources, now: now)
        XCTAssertEqual(news.emptyBriefing(summary), .couldNotCheck)
        XCTAssertEqual(news.firstCheckIDs(summary), Set(news.sources.map(\.id)).union([ModelFeed.id]))
    }

    func testCaptionSaysHowManySourcesWereCheckedRecently() {
        var cache = NewsCache()
        cache.sourceChecks = ["healthy": .init(succeededAt: now.addingTimeInterval(-60)),
                              "delayed": .init(succeededAt: now.addingTimeInterval(-36_000))]
        XCTAssertEqual(NewsSourceFreshness(cache: cache, sources: sources, now: now).caption, "1 of 2 sources checked recently")
        cache.sourceChecks?["delayed"] = .init(succeededAt: now)
        XCTAssertEqual(NewsSourceFreshness(cache: cache, sources: sources, now: now).caption, "All 2 sources checked recently")
        XCTAssertEqual(NewsSourceFreshness(cache: cache, sources: [sources[0]], now: now).caption, "1 source checked recently")
        XCTAssertEqual(NewsSourceFreshness(cache: NewsCache(), sources: [], now: now).caption, "No sources followed")
    }

    @MainActor
    func testSourceDetailShowsWhenTheSourceLastPublished() throws {
        let suite = TestDefaults.make(owner: "MacNewsPresentation", index: 2)
        defer { TestDefaults.remove(suite.name) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 12)))
        let lastPost = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8)))
        let source = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code-whats-new" })
        var cache = NewsCache()
        cache.sourceChecks = [source.id: .init(succeededAt: today.addingTimeInterval(-120))]
        cache.items[source.id] = [
            FeedItem(id: "older", title: "Older", published: lastPost.addingTimeInterval(-86_400 * 7), source: source.name,
                     publisherPublishedAt: lastPost.addingTimeInterval(-86_400 * 7)),
            FeedItem(id: "newest", title: "Newest", published: lastPost, source: source.name, publisherPublishedAt: lastPost),
        ]
        let news = NewsStore(defaults: suite.defaults, directory: nil, now: today, initialCache: cache,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let health = news.sourceHealth(for: source)
        XCTAssertEqual(health.latestItemAt, lastPost)
        XCTAssertEqual(health.detailCaption(now: today, calendar: calendar), health.caption + " · Latest update Sep 15")
        XCTAssertEqual(health.detailCaption(now: today.addingTimeInterval(86_400 * 60), calendar: calendar), health.caption + " · Latest update Sep 15, 2026")
        let empty = NewsCollectionHealth(checkedAt: today, uncheckedCount: 0, sourceCount: 1, problem: nil, retryIDs: [], sourceIDs: [source.id])
        XCTAssertEqual(empty.detailCaption(now: today, calendar: calendar), empty.caption)
    }

    @MainActor
    func testSourceDetailDoesNotDateAnUndatedArticleByItsArrival() throws {
        let suite = TestDefaults.make(owner: "MacNewsPresentation", index: 3)
        defer { TestDefaults.remove(suite.name) }
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let source = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code-whats-new" })
        let previous = [FeedItem(id: "dated", title: "Dated", published: today.addingTimeInterval(-86_400 * 30), source: source.name,
                                 publisherPublishedAt: today.addingTimeInterval(-86_400 * 30))]
        let incoming = [FeedItem(id: "undated", title: "Undated", published: nil, source: source.name)]
        let arrived = NewsFetcher.firstSeen(incoming, previous: previous, now: today)
        XCTAssertEqual(arrived.first?.published, today)

        var cache = NewsCache()
        cache.sourceChecks = [source.id: .init(succeededAt: today.addingTimeInterval(-120))]
        cache.items[source.id] = arrived
        let undated = NewsStore(defaults: suite.defaults, directory: nil, now: today, initialCache: cache,
                                fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let health = undated.sourceHealth(for: source)
        XCTAssertNil(health.latestItemAt)
        XCTAssertEqual(health.detailCaption(now: today), health.caption)

        cache.items[source.id] = arrived + previous
        let mixed = NewsStore(defaults: suite.defaults, directory: nil, now: today, initialCache: cache,
                              fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(mixed.sourceHealth(for: source).latestItemAt, previous[0].publisherPublishedAt)
    }

    @MainActor
    func testAStatusSourceIsDatedByItsLatestIncidentUpdate() throws {
        let suite = TestDefaults.make(owner: "MacNewsPresentation", index: 4)
        defer { TestDefaults.remove(suite.name) }
        let today = Date(timeIntervalSince1970: 1_800_000_000)
        let opened = today.addingTimeInterval(-86_400 * 2)
        let updated = today.addingTimeInterval(-86_400)
        let source = try XCTUnwrap(NewsStatusSource.catalog.first { $0.id == "status-claude" })
        var cache = NewsCache()
        cache.sourceChecks = [source.id: .init(succeededAt: today.addingTimeInterval(-120))]
        cache.items[source.id] = [FeedItem(id: "incident", title: "Incident", published: opened, source: source.name,
                                           publisherPublishedAt: opened, updatedAt: updated)]
        let news = NewsStore(defaults: suite.defaults, directory: nil, now: today, initialCache: cache,
                             fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        news.setFollowing(source, true)
        XCTAssertEqual(news.sourceHealth(for: source).latestItemAt, updated)
    }

    @MainActor
    func testDesktopPreviewFlagIsInertWithoutOtherFixtureArguments() {
        let name = "tokenroom.tests.news-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "TokenroomNewsPreview")
        XCTAssertTrue(NewsRuntime.isInert(launchDefaults: defaults, isUnitTestHost: false))
    }

    func testRSSExcerptUsesSuppliedSummaryWithoutAppendingFullDocument() throws {
        let xml = Data("""
        <rss xmlns:content="urn:content"><channel><item><title>Release</title>
        <description><![CDATA[<p>Supplied summary.</p>]]></description>
        <content:encoded><![CDATA[<!DOCTYPE html><html><head><title>Document title</title></head><body><p>Full document copy.</p></body></html>]]></content:encoded>
        </item></channel></rss>
        """.utf8)
        let page = FeedParser.read(xml, source: sources[0])
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(try XCTUnwrap(page.items.first).excerpt, "Supplied summary.")
    }

    func testHTMLOnlyExcerptDoesNotExposeDocumentOrScriptChrome() throws {
        let xml = Data("""
        <rss xmlns:content="urn:content"><channel><item><title>Release</title>
        <content:encoded><![CDATA[<!DOCTYPE html><html><head><title>Document title</title><style>.hidden { display:none }</style></head><body><p>Actual notes.</p><script>tracking()</script></body></html>]]></content:encoded>
        </item></channel></rss>
        """.utf8)
        let page = FeedParser.read(xml, source: sources[0])
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(try XCTUnwrap(page.items.first).excerpt, "Actual notes.")
    }

    func testAtomXHTMLPreservesEscapedCodeTokens() throws {
        let xml = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>code</id><title>Release</title>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Use <code>&lt;button&gt;</code> for actions.</p></div></content>
        </entry></feed>
        """.utf8)
        let item = try XCTUnwrap(FeedParser.read(xml, source: sources[0]).items.first)
        XCTAssertEqual(item.excerpt, "Use <button> for actions.")
        XCTAssertEqual(item.displayExcerpt, "Use <button> for actions.")
        XCTAssertEqual(item.bookmark().summary, "Use <button> for actions.")
    }

    func testRSSCodeExampleSurvivesDisplayAndBookmark() throws {
        let xml = Data("""
        <rss><channel><item><title>Release</title>
        <description><![CDATA[<pre><code>&lt;script&gt;tracking()&lt;/script&gt;</code></pre>]]></description>
        </item></channel></rss>
        """.utf8)
        let item = try XCTUnwrap(FeedParser.read(xml, source: sources[0]).items.first)
        XCTAssertEqual(item.excerpt, "<script>tracking()</script>")
        XCTAssertEqual(item.displayExcerpt, "<script>tracking()</script>")
        XCTAssertEqual(item.bookmark().summary, "<script>tracking()</script>")
        let legacy = FeedItem(id: "legacy", title: "Code", source: "Publisher", excerpt: "<script>tracking()</script>")
        XCTAssertEqual(legacy.displayExcerpt, "<script>tracking()</script>")
    }

    func testEmptyHTMLDescriptionDoesNotHideSuppliedContent() throws {
        let xml = Data("""
        <rss xmlns:content="urn:content"><channel><item><title>Release</title>
        <description><![CDATA[<p>&nbsp;</p>]]></description>
        <content:encoded><![CDATA[<p>Actual notes.</p>]]></content:encoded>
        </item></channel></rss>
        """.utf8)
        XCTAssertEqual(try XCTUnwrap(FeedParser.read(xml, source: sources[0]).items.first).excerpt, "Actual notes.")
    }
}
