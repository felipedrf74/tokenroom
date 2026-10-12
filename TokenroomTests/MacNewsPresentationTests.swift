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

    @MainActor
    func testDesktopPreviewFlagIsInertWithoutOtherFixtureArguments() {
        let name = "MacNewsPreviewIsolation-\(UUID().uuidString)"
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
