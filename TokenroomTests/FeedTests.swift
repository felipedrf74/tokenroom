import XCTest
@testable import Tokenroom

final class FeedTests: XCTestCase {
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    // MARK: Model releases

    private let models = Data("""
    {"data":[
      {"id":"anthropic/claude-opus-5.5:batch","name":"Anthropic: Claude Opus 5.5 (batch)","created":1790094732,"pricing":{"prompt":"0.000002","completion":"0.00001"}},
      {"id":"anthropic/claude-opus-5.5","canonical_slug":"anthropic/claude-opus-5.5-20260921","name":"Anthropic: Claude Opus 5.5","created":1790094732,"context_length":1000000,"pricing":{"prompt":"0.000004","completion":"0.00002"}},
      {"id":"z-ai/glm-5.3-prime","name":"Z.ai: GLM 5.3 Prime","created":1790199651,"pricing":{"prompt":"0.0000028","completion":"0.000011"}},
      {"id":"nex-agi/nex-n2.5-mini:free","name":"Nex AGI: Nex-N2.5-Mini (free)","created":1788890061,"pricing":{"prompt":"0","completion":"0"},"expiration_date":"2026-09-25"},
      {"id":"~openai/gpt-luna-latest","name":"OpenAI: GPT Luna Latest","created":1789130922},
      {"id":"openai/gpt-sol-latest","name":"OpenAI: GPT Sol Latest","created":1789130921},
      {"id":"openrouter/auto","name":"Auto Router","created":1789130920},
      {"id":"stealth/space-bunny-alpha","name":"Space Bunny Alpha","created":1790174884}
    ]}
    """.utf8)

    func testModelReleasesFoldVariantsAndSkipAliases() throws {
        let releases = try ModelFeed.releases(from: models)
        XCTAssertEqual(releases.map(\.id), ["z-ai/glm-5.3-prime", "anthropic/claude-opus-5.5", "nex-agi/nex-n2.5-mini"])
        let opus = releases[1]
        XCTAssertEqual(opus.name, "Anthropic: Claude Opus 5.5")
        XCTAssertEqual(opus.vendor, "anthropic")
        XCTAssertEqual(opus.promptPrice ?? 0, 4, accuracy: 0.0001, "The base model's price per million tokens, not the batch one's")
        XCTAssertEqual(opus.contextLength, 1_000_000)
        let free = releases[2]
        XCTAssertEqual(free.name, "Nex AGI: Nex-N2.5-Mini", "A variant alone keeps its model, without the suffix")
        XCTAssertEqual(free.expires, utc(2026, 9, 25))
    }

    func testFirstCheckSeedsQuietlyThenOnlyNewFollowedReleasesAnnounce() throws {
        var state = ModelFeedState()
        let first = try ModelFeed.releases(from: models)
        XCTAssertEqual(state.takeNew(from: first, following: ModelFeed.defaultVendors), [], "Installing Tokenroom doesn't announce the whole catalog")

        let newer = ModelRelease(id: "openai/gpt-6-luna", name: "OpenAI: GPT-6 Luna", vendor: "openai", created: utc(2026, 9, 26), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        let unfollowed = ModelRelease(id: "qwen/qwen3.8-max", name: "Qwen: Qwen3.8 Max", vendor: "qwen", created: utc(2026, 9, 26), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        let second = [newer, unfollowed] + first
        XCTAssertEqual(state.takeNew(from: second, following: ModelFeed.defaultVendors).map(\.id), ["openai/gpt-6-luna"])
        XCTAssertEqual(state.takeNew(from: second, following: ModelFeed.defaultVendors), [], "Each release is announced once")
    }

    func testAnEmptyFirstAnswerDoesntEndTheQuietSeed() throws {
        var state = ModelFeedState()
        XCTAssertEqual(state.takeNew(from: [], following: ModelFeed.defaultVendors), [])
        XCTAssertNil(state.newestSeen, "An empty answer isn't a first check")
        XCTAssertEqual(state.takeNew(from: try ModelFeed.releases(from: models), following: ModelFeed.defaultVendors), [], "The first real answer still only remembers what's there")
    }

    func testRetirementsComeFromTheWholeModelList() throws {
        XCTAssertNil(URLComponents(url: ModelFeed.url, resolvingAgainstBaseURL: false)?.queryItems, "The whole list, not the newest 50")
        // 55 models a day apart, newest first; two of the five oldest have retirement dates.
        let entries = (0..<55).map { index in
            let expires = index == 52 || index == 54 ? #","expiration_date":"2026-10-30""# : ""
            return #"{"id":"lab/model-\#(index)","name":"Lab: Model \#(index)","created":\#(1_790_000_000 - index * 86_400)\#(expires)}"#
        }
        let releases = try ModelFeed.releases(from: Data(#"{"data":[\#(entries.joined(separator: ","))]}"#.utf8))
        XCTAssertEqual(releases.count, ModelFeed.newestLimit + 2)
        XCTAssertEqual(releases.prefix(ModelFeed.newestLimit).map(\.id), (0..<50).map { "lab/model-\($0)" }, "The newest 50 for new models")
        XCTAssertEqual(releases.dropFirst(ModelFeed.newestLimit).map(\.id), ["lab/model-52", "lab/model-54"], "Older models only while they're retiring")
        XCTAssertEqual(releases.last?.expires, utc(2026, 10, 30))
    }

    // MARK: Announcements

    private let claudeCode = FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://example.com/rss.xml")!)

    func testRSSWithCDATAEntitiesAndTags() {
        let rss = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>Changelog</title>
          <item><title><![CDATA[2.1.282]]></title><link>https://example.com/changelog#2-1-282</link>
            <guid isPermaLink="false">d2514dd17c2aa91e</guid><pubDate>Thu, 24 Sep 2026 18:46:38 GMT</pubDate>
            <description><![CDATA[<p>Fixes</p>]]></description></item>
          <item><title>Sam Altman&amp;#8217;s remarks &lt;b&gt;today&lt;/b&gt;</title><link>https://example.com/remarks</link>
            <dc:date>2026-09-23T12:00:00Z</dc:date></item>
          <item><title>   </title><link>https://example.com/empty</link></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["2.1.282", "Sam Altman\u{2019}s remarks today"])
        XCTAssertEqual(items[0].id, "d2514dd17c2aa91e")
        XCTAssertEqual(items[0].published, utc(2026, 9, 24, 18, 46, 38))
        XCTAssertEqual(items[0].source, "Claude Code")
        XCTAssertEqual(items[1].id, "https://example.com/remarks", "No guid: the link identifies the item")
        XCTAssertEqual(items[1].published, utc(2026, 9, 23, 12))
    }

    func testFeedDatesReadTheVariantsFeedsWrite() {
        XCTAssertEqual(FeedParser.date("Thu, 24 Sep 2026 18:46:38 GMT"), utc(2026, 9, 24, 18, 46, 38))
        XCTAssertEqual(FeedParser.date("Thu, 24 Sep 2026 18:46:38 +0100"), utc(2026, 9, 24, 17, 46, 38))
        XCTAssertEqual(FeedParser.date("Thu, 24 Sep 2026 18:46 GMT"), utc(2026, 9, 24, 18, 46), "No seconds")
        XCTAssertEqual(FeedParser.date("Thu, 24 Sep 26 18:46:38 GMT"), utc(2026, 9, 24, 18, 46, 38), "A two-digit year is this century's, not the year 26")
        XCTAssertEqual(FeedParser.date("24 Sep 2026 18:46:38 +0000"), utc(2026, 9, 24, 18, 46, 38))
        XCTAssertEqual(FeedParser.date("2026-09-24T12:00:00Z"), utc(2026, 9, 24, 12))
        XCTAssertEqual(FeedParser.date("2026-09-24T12:00:00"), utc(2026, 9, 24, 12), "No time zone reads as UTC")
        XCTAssertEqual(FeedParser.date("2026-09-24 12:00:00Z"), utc(2026, 9, 24, 12), "A space for the T")
        XCTAssertEqual(FeedParser.date("2026-09-24 12:00:00"), utc(2026, 9, 24, 12))
        XCTAssertEqual(FeedParser.date("2026-09-24T12:00Z"), utc(2026, 9, 24, 12), "No seconds")
        XCTAssertEqual(FeedParser.date("2026-09-24T12:00+02:00"), utc(2026, 9, 24, 10))
        XCTAssertEqual(FeedParser.date(" 2026-09-24 "), utc(2026, 9, 24), "A day alone is its midnight, UTC")
        XCTAssertNil(FeedParser.date("soon"))
        XCTAssertNil(FeedParser.date(""))
    }

    func testAnUndatedEntryIsDatedWhenItArrivesAfterTheFirstRead() {
        let now = utc(2026, 9, 25, 12)
        let older = FeedItem(id: "o", title: "Older", link: nil, published: utc(2026, 9, 20), source: "Claude Code")
        let undated = FeedItem(id: "u", title: "Undated", link: nil, published: nil, source: "Claude Code")
        let arrived = NewsFetcher.firstSeen([undated, older], previous: [older], now: now)
        XCTAssertEqual(arrived.first?.published, now, "Dated when it arrives, so it sorts with what came then")
        XCTAssertEqual(arrived.first?.sortDate, now)
        XCTAssertNil(arrived.first?.publisherPublishedAt, "The publisher's own date stays unknown")
        let again = NewsFetcher.firstSeen([undated], previous: arrived, now: now.addingTimeInterval(86_400))
        XCTAssertEqual(again.first?.published, now, "…and keeps that date, still undated in the feed")
        let legacy = NewsFetcher.firstSeen([undated], previous: [undated], now: now)
        XCTAssertNil(legacy.first?.published, "One cached undated by an earlier release isn't dated now")

        // A feed whose dates don't parse: its back catalog doesn't all read as just published.
        let firstRead = NewsFetcher.firstSeen([undated], previous: [], now: now)
        XCTAssertNil(firstRead.first?.published, "On a first read an undated entry still sorts last")
        XCTAssertEqual(firstRead.first?.sortDate, .distantPast)
        let followedAgain = NewsFetcher.firstSeen([undated], previous: [older], now: now, quiet: true)
        XCTAssertNil(followedAgain.first?.published, "…and on the quiet read of a feed followed again")
        XCTAssertEqual(NewsFetcher.firstSeen([older], previous: [], now: now).first?.firstSeenAt, utc(2026, 9, 20), "A quiet read keeps entries' own dates")
    }

    func testAtomReleasesDropPrereleasesAndPackagePrefixes() {
        let atom = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><id>tag:example,2008:releases</id><title>Releases</title><updated>2026-09-25T13:02:46Z</updated>
          <entry><id>tag:example,2008:Repository/1/v0.158.0-alpha.14</id><updated>2026-09-25T13:02:46Z</updated>
            <link rel="alternate" type="text/html" href="https://example.com/releases/tag/v0.158.0-alpha.14"/><title>0.158.0-alpha.14</title></entry>
          <entry><id>tag:example,2008:Repository/1/v0.157.0</id><updated>2026-09-25T02:32:43Z</updated>
            <link rel="alternate" type="text/html" href="https://example.com/releases/tag/v0.157.0"/><title>0.157.0</title></entry>
          <entry><id>tag:example,2008:Repository/2/kimi-code-2.1.1</id><published>2026-09-24T07:45:05Z</published><updated>2026-09-25T00:00:00Z</updated>
            <link rel="alternate" href="https://example.com/releases/tag/kimi-code-2.1.1"/><title>@moonshot-ai/kimi-code@2.1.1</title></entry>
          <entry><id>tag:example,2008:Repository/2/kimi-code-2.2.0-rc.1</id><updated>2026-09-25T00:00:00Z</updated><title>@moonshot-ai/kimi-code@2.2.0-rc.1</title></entry>
        </feed>
        """.utf8)
        let source = FeedSource(id: "releases", name: "Releases", url: URL(string: "https://example.com/releases.atom")!, skipsPrereleases: true)
        let items = FeedParser.items(from: atom, source: source)
        XCTAssertEqual(items.map(\.title), ["0.157.0", "2.1.1"])
        XCTAssertEqual(items[0].link?.absoluteString, "https://example.com/releases/tag/v0.157.0")
        XCTAssertEqual(items[0].publisherPublishedAt, utc(2026, 9, 25, 2, 32, 43), "A release dated only by <updated> was released then")
        XCTAssertEqual(items[0].published, utc(2026, 9, 25, 2, 32, 43))
        XCTAssertNil(items[0].updatedAt, "…so it doesn't read as \"Updated\"")
        XCTAssertEqual(items[1].published, utc(2026, 9, 24, 7, 45, 5), "published wins over updated")
        XCTAssertEqual(items[1].updatedAt, utc(2026, 9, 25), "…and an update after it still shows as one")

        // Other feeds keep an <updated> as an update: the publication date stays unknown.
        let blog = FeedSource(id: "blog", name: "Blog", url: URL(string: "https://example.com/feed.atom")!)
        let post = FeedParser.items(from: Data("<feed><entry><id>p</id><title>Post</title><link href=\"https://example.com/post\"/><updated>2026-09-25T02:32:43Z</updated></entry></feed>".utf8), source: blog).first
        XCTAssertNil(post?.publisherPublishedAt)
        XCTAssertEqual(post?.updatedAt, utc(2026, 9, 25, 2, 32, 43))
    }

    func testOnlyAnItemsOwnTitleCounts() {
        let rss = Data("""
        <rss version="2.0"><channel><item>
          <title>Introducing Gemini Live</title>
          <og><title>Introducing Gemini Live</title><image>https://example.com/card.png</image></og>
          <link>https://example.com/gemini-live</link>
          <author><name>Placeholder Author</name><title>Research Scientist</title></author>
          <pubDate>Thu, 24 Sep 2026 15:30:00 +0000</pubDate>
        </item></channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["Introducing Gemini Live"])
        XCTAssertEqual(items.first?.published, utc(2026, 9, 24, 15, 30))
    }

    func testLinkFilterKeepsOnlyAnnouncements() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Batch API</title><link>https://example.com/blog/announcements/batch-api/</link><pubDate>Tue, 22 Sep 2026 00:00:00 GMT</pubDate></item>
          <item><title>Is it open source?</title><link>https://example.com/blog/insights/open-source/</link><pubDate>Fri, 25 Sep 2026 00:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let source = FeedSource(id: "blog", name: "Blog", url: URL(string: "https://example.com/feed.xml")!, linkContains: "/blog/announcements/")
        XCTAssertEqual(FeedParser.items(from: rss, source: source).map(\.title), ["Batch API"])
    }

    func testTitlesKeepAngleBracketsThatArentHTML() {
        XCTAssertEqual(FeedParser.plainText("Support for <thinking> blocks"), "Support for <thinking> blocks")
        XCTAssertEqual(FeedParser.plainText("Fix </s> handling in Either<A, B>"), "Fix </s> handling in Either<A, B>")
        XCTAssertEqual(FeedParser.plainText("Use <code>--resume</code> to <b>pick up</b><br/>a session"), "Use --resume to pick up a session")
        XCTAssertEqual(FeedParser.plainText(#"<a href="https://example.com">Read</a> <img src="card.png"> more"#), "Read more")
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Support for &lt;thinking&gt; blocks</title><link>https://example.com/thinking</link></item></channel></rss>".utf8)
        XCTAssertEqual(FeedParser.items(from: rss, source: claudeCode).map(\.title), ["Support for <thinking> blocks"], "Escaped in the feed, still text")
    }

    func testLinksAreWebPagesOnly() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>Script</title><link>javascript:alert(1)</link></item>
          <item><title>File</title><link>file:///tmp/feed</link></item>
          <item><title>App</title><link>shortcuts://run-shortcut?name=x</link></item>
          <item><title>Relative</title><link>/blog/relative</link></item>
          <item><title>Web</title><link>https://example.com/web</link></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map { $0.link?.absoluteString }, [nil, nil, nil, "https://example.com/blog/relative", "https://example.com/web"], "Web pages only; a relative link is on the feed's site")
        XCTAssertEqual(items.first?.id, "Script", "No guid and no usable link: the title identifies it")
    }

    func testLimitsItemsAndSize() {
        let items = (0..<40).map { "<item><title>Post \($0)</title><link>https://example.com/\($0)</link></item>" }.joined()
        let rss = Data("<rss version=\"2.0\"><channel>\(items)</channel></rss>".utf8)
        XCTAssertEqual(FeedParser.items(from: rss, source: claudeCode).count, FeedParser.itemLimit)
        XCTAssertTrue(FeedParser.items(from: Data(count: FeedParser.sizeLimit + 1), source: claudeCode).isEmpty)
    }

    // MARK: Fetching

    func testConditionalGetsKeepCachedItemsOn304() async throws {
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        let rss = Data("<rss version=\"2.0\"><channel><item><title>2.1.282</title><link>https://example.com/a</link><pubDate>Thu, 24 Sep 2026 18:46:38 GMT</pubDate></item></channel></rss>".utf8)
        StubURLProtocol.handler = { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" ? (304, Data()) : (200, rss)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))

        let source = FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://example.com/rss.xml")!)
        let now = utc(2026, 9, 25, 12)
        let first = await NewsFetcher.refresh(NewsCache(), sources: [source], following: [], now: now)
        XCTAssertEqual(first.cache.items["claude-code"]?.map(\.title), ["2.1.282"])
        XCTAssertEqual(first.cache.validators[source.url.absoluteString]?.etag, "\"v1\"")

        let second = await NewsFetcher.refresh(first.cache, sources: [source], following: [], maxAge: 0, now: now.addingTimeInterval(60))
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(second.cache.items["claude-code"]?.map(\.title), ["2.1.282"], "A 304 keeps what was cached")
        XCTAssertEqual(second.cache.announcementsFetchedAt, now.addingTimeInterval(60))
        XCTAssertFalse(NewsFetcher.isDue(second.cache.announcementsFetchedAt, interval: NewsFetcher.announcementInterval, now: now.addingTimeInterval(3600)))
    }

    func testLegacyExcerptRevalidatesBodyOnceWithoutLosingReadIdentity() async throws {
        defer { unstubNetwork() }
        let rss = Data("<rss><channel><item><guid>release</guid><title>Release</title><description><![CDATA[<p>Supplied summary.</p>]]></description></item></channel></rss>".utf8)
        stubNetwork { request in
            request.url == ModelFeed.url ? (200, Self.noModels) :
                (request.value(forHTTPHeaderField: "If-None-Match") == nil ? 200 : 304, rss)
        }
        let now = utc(2026, 10, 11, 12)
        var cache = NewsCache()
        cache.items[claudeCode.id] = [FeedItem(id: "release", title: "Release", source: "Claude Code", firstSeenAt: now.addingTimeInterval(-3600), excerpt: "Supplied summary. <!DOCTYPE html><html>Full copy</html>")]
        cache.validators[claudeCode.url.absoluteString] = .init(etag: "\"v1\"")
        let first = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: now)
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(first.cache.items[claudeCode.id]?.first?.excerpt, "Supplied summary.")
        XCTAssertEqual(first.cache.items[claudeCode.id]?.first?.firstSeenAt, now.addingTimeInterval(-3600))
        let second = await NewsFetcher.refresh(first.cache, sources: [claudeCode], following: [], maxAge: 0, now: now.addingTimeInterval(60))
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        XCTAssertEqual(second.cache.items[claudeCode.id]?.first?.excerpt, "Supplied summary.")
    }

    func testTheModelsRequestSendsNoAnthropicVersion() async {
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        StubURLProtocol.handler = { _ in (200, Data(#"{"data":[]}"#.utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        _ = await NewsFetcher.refresh(NewsCache(), sources: [], following: ["anthropic"], now: utc(2026, 9, 25, 12))
        let request = StubURLProtocol.requests.first { $0.url == ModelFeed.url }
        XCTAssertNotNil(request, "The models list was asked for")
        XCTAssertNil(request?.value(forHTTPHeaderField: "anthropic-version"), "That header changes OpenRouter's answer")
    }

    /// Answers every request with `handler`, through `StubETagProtocol`. Pair with `unstubNetwork`.
    private func stubNetwork(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    private func unstubNetwork() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
    }

    private static let noModels = Data(#"{"data":[]}"#.utf8)

    func testALargeBodyIsReadWholeAndQuickly() async {
        defer { unstubNetwork() }
        // About the size of OpenRouter's whole model list, read through the same GET.
        let body = Data(repeating: UInt8(ascii: "x"), count: 1_500_000)
        stubNetwork { _ in (200, body) }
        let started = Date.now
        guard case let .body(data, _, isTruncated) = await NewsFetcher.get(URL(string: "https://example.com/models")!, validator: nil) else {
            return XCTFail("A 200 has a body")
        }
        XCTAssertEqual(data.count, body.count)
        XCTAssertFalse(isTruncated, "A complete body is never marked cut off")
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 3, "Read off the main actor a buffer at a time, not a hop per byte")
    }

    func testOnScreenChecksLeaveTheModelListToItsHour() async {
        defer { unstubNetwork() }
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (304, Data()) }
        let now = utc(2026, 10, 21, 12)
        var cache = NewsCache()
        cache.modelsFetchedAt = now.addingTimeInterval(-10 * 60)
        _ = await NewsFetcher.refresh(cache, sources: [], following: [], maxAge: NewsFetcher.liveInterval, now: now)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url == ModelFeed.url }, "The whole list isn't downloaded again every 5 minutes")
        _ = await NewsFetcher.refresh(cache, sources: [], following: [], maxAge: NewsFetcher.openInterval, now: now.addingTimeInterval(50 * 60))
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url == ModelFeed.url }.count, 1, "…but is once its hour is up")
        _ = await NewsFetcher.refresh(cache, sources: [], following: [], maxAge: 0, now: now)
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.url == ModelFeed.url }.count, 2, "A pull or Check Now still asks")
    }

    func testAFeedThatAsksToWaitIsntAskedSooner() async {
        defer {
            TokenroomHTTP.overrideSession(nil)
            StubURLProtocol.reset()
        }
        StubURLProtocol.reset()
        RetryAfterProtocol.retryAfter = "7200"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        let now = utc(2026, 10, 21, 12)
        var cache = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(cache.sourceChecks?[claudeCode.id]?.retryAt, now.addingTimeInterval(7200))
        XCTAssertEqual(cache.modelsRetryAt, now.addingTimeInterval(7200))
        let asked = StubURLProtocol.requests.count
        for minutes in [5.0, 30, 60, 119] {
            cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(minutes * 60)).cache
        }
        XCTAssertEqual(StubURLProtocol.requests.count, asked, "Nothing goes out before the two hours it asked for")
        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(7200)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, asked + 2, "…and both go out once they're up")
        _ = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: now.addingTimeInterval(7260)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, asked + 4, "A pull or Check Now still goes out")

        // A server asking for days is tried again within six hours.
        RetryAfterProtocol.retryAfter = "\(3 * 86_400)"
        let held = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(held.sourceChecks?[claudeCode.id]?.retryAt, now.addingTimeInterval(NewsFetcher.longestRetryAfter))
        XCTAssertTrue(NewsFetcher.isDue(nil, failedAt: now, failures: 1, retryAt: now.addingTimeInterval(30 * 86_400), interval: 3600, now: now.addingTimeInterval(300)), "A time further off than allowed was saved while the clock was ahead")
    }

    func testTheSizeLimitStopsTheDownload() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (200, Data(repeating: UInt8(ascii: "x"), count: 3000)) }
        let url = URL(string: "https://example.com/big.xml")!
        guard case let .body(data, _, isTruncated) = await NewsFetcher.get(url, validator: nil, sizeLimit: 1024) else {
            return XCTFail("A 200 has a body")
        }
        XCTAssertEqual(data.count, 1024, "Reading stops at the limit")
        XCTAssertTrue(isTruncated)
        guard case let .body(whole, _, cut) = await NewsFetcher.get(url, validator: nil, sizeLimit: 3000) else {
            return XCTFail("A 200 has a body")
        }
        XCTAssertEqual(whole.count, 3000)
        XCTAssertFalse(cut, "A body exactly at the limit is whole")
    }

    func testAFeedPastItsLimitShowsWhatArrivedAndSaysSo() async {
        defer { unstubNetwork() }
        let long = Data("""
        <rss version="2.0"><channel>
          <item><title>Short post</title><link>https://example.com/short</link><pubDate>Thu, 24 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>Long post</title><link>https://example.com/long</link><pubDate>Wed, 23 Sep 2026 12:00:00 GMT</pubDate><description>\(String(repeating: "Notes. ", count: 400))</description></item>
        </channel></rss>
        """.utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, long) }
        let source = FeedSource(id: "long", name: "Long", url: URL(string: "https://example.com/long.xml")!, sizeLimit: 1024)
        let now = utc(2026, 9, 25, 12)
        let first = await NewsFetcher.refresh(NewsCache(), sources: [source], following: [], now: now)
        XCTAssertEqual(first.cache.items["long"]?.map(\.title), ["Short post"], "What arrived before the limit")
        XCTAssertNil(first.cache.validators[source.url.absoluteString], "Not taken for the whole feed: no 304 keeps it")
        XCTAssertEqual(first.cache.unreadable, ["long"])
        XCTAssertNil(first.cache.announcementsFetchedAt, "A partial answer is a failure, not a successful check")
        XCTAssertEqual(first.cache.sourceChecks?["long"]?.failedAt, now)

        let short = Data("<rss version=\"2.0\"><channel><item><title>Short post</title><link>https://example.com/short</link></item></channel></rss>".utf8)
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, short) }
        let second = await NewsFetcher.refresh(first.cache, sources: [source], following: [], maxAge: 0, now: now.addingTimeInterval(60))
        XCTAssertNil(second.cache.unreadable, "Read in full again")
        XCTAssertEqual(second.cache.validators[source.url.absoluteString]?.etag, "\"v1\"")
    }

    func testFeedsHaveLongerToDownloadThanAProviderCheck() throws {
        TokenroomHTTP.overrideSession(nil)
        let session = NewsFetcher.session
        let configuration = session.configuration
        XCTAssertGreaterThan(NewsFetcher.downloadTimeout, TokenroomHTTP.timeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, NewsFetcher.downloadTimeout, "Room for a 4 MB changelog on a slow network")
        XCTAssertEqual(configuration.timeoutIntervalForRequest, TokenroomHTTP.timeout, "A stalled download still ends soon")
        XCTAssertEqual(configuration.httpAdditionalHeaders?["User-Agent"] as? String, TokenroomIdentity.userAgent)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(TokenroomHTTP.defaultSession.configuration.timeoutIntervalForResource, TokenroomHTTP.timeout, "Providers keep theirs")

        // The shared session's redirect rules come along: never to cleartext.
        let delegate = try XCTUnwrap(session.delegate as? any URLSessionTaskDelegate)
        let original = URLRequest(url: URL(string: "https://example.invalid/feed.xml")!)
        let task = session.dataTask(with: original) // Kept suspended: no networking.
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil))
        let answers = LockedBox<[URLRequest?]>([])
        for destination in ["http://example.invalid/feed.xml", "https://feeds.example.invalid/feed.xml"] {
            delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: destination)!)) { answers.value.append($0) }
        }
        XCTAssertEqual(answers.value.map { $0?.url?.absoluteString }, [nil, "https://feeds.example.invalid/feed.xml"])

        let stub = URLSession(configuration: .ephemeral)
        TokenroomHTTP.overrideSession(stub)
        defer { TokenroomHTTP.overrideSession(nil) }
        XCTAssertTrue(NewsFetcher.session === stub, "A session tests swap in is used as it is")
    }

    func testAFeedCutOffPartwayShowsWhatArrived() async {
        defer { unstubNetwork() }
        let partial = Data("<rss version=\"2.0\"><channel><item><title>Arrived</title><link>https://example.com/arrived</link><pubDate>Thu, 24 Sep 2026 12:00:00 GMT</pubDate></item><item><title>Cut".utf8)
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, partial) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CutOffFeedProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))

        guard case let .body(data, _, isTruncated) = await NewsFetcher.get(claudeCode.url, validator: nil) else {
            return XCTFail("What arrived before the time ran out is kept")
        }
        XCTAssertEqual(data, partial)
        XCTAssertTrue(isTruncated)

        let now = utc(2026, 9, 25, 12)
        let cache = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(cache.items["claude-code"]?.map(\.title), ["Arrived"], "It shows, as a feed past its size limit does")
        XCTAssertEqual(cache.unreadable, ["claude-code"], "…and says it couldn't read the rest")
        XCTAssertEqual(cache.sourceChecks?["claude-code"]?.failedAt, now)
    }

    func testABrokenFeedKeepsWhatItHad() async {
        defer { unstubNetwork() }
        let page = Data("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>Down for maintenance</body></html>".utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, page) }
        var cache = NewsCache()
        cache.items["claude-code"] = [FeedItem(id: "old", title: "2.1.282", link: URL(string: "https://example.com/2-1-282"), published: utc(2026, 9, 24), source: "Claude Code")]
        cache.validators[claudeCode.url.absoluteString] = NewsCache.Validator(etag: "\"v0\"")
        let result = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: utc(2026, 9, 25, 12))
        XCTAssertEqual(result.cache.items["claude-code"]?.map(\.id), ["old"], "A page that isn't the feed leaves the last items")
        XCTAssertNil(result.cache.validators[claudeCode.url.absoluteString])
        XCTAssertEqual(result.cache.unreadable, ["claude-code"])
    }

    func testADocumentWithNoEntriesKeepsWhatWasCached() async {
        defer { unstubNetwork() }
        let cached = [FeedItem(id: "old", title: "2.1.282", link: URL(string: "https://example.com/2-1-282"), published: utc(2026, 9, 24), source: "Claude Code")]
        let now = utc(2026, 9, 25, 12)
        for body in ["<error>rate limited</error>", "<html><body><p>Sign in to the Wi-Fi</p></body></html>", "<rss version=\"2.0\"><channel><title>Changelog</title></channel></rss>"] {
            stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, Data(body.utf8)) }
            var cache = NewsCache()
            cache.items["claude-code"] = cached
            let result = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now).cache
            XCTAssertEqual(result.items["claude-code"]?.map(\.id), ["old"], "\(body) leaves the last items")
            XCTAssertEqual(result.unreadable, ["claude-code"], "\(body) is a failed read")
            XCTAssertNil(result.sourceChecks?["claude-code"]?.succeededAt, "\(body) isn't a successful check")
        }

        // An empty feed is taken at its word only when nothing was cached.
        let fresh = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(fresh.items["claude-code"], [])
        XCTAssertNil(fresh.unreadable)
        XCTAssertEqual(fresh.sourceChecks?["claude-code"]?.succeededAt, now)
    }

    func testAFeedOfOnlyPrereleasesKeepsTheLastReleases() async {
        defer { unstubNetwork() }
        let alphas = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>tag:example,2008:Repository/1/v0.158.0-alpha.2</id><updated>2026-09-25T10:00:00Z</updated><link rel="alternate" href="https://example.com/v0.158.0-alpha.2"/><title>0.158.0-alpha.2</title></entry>
          <entry><id>tag:example,2008:Repository/1/v0.158.0-alpha.1</id><updated>2026-09-25T09:00:00Z</updated><link rel="alternate" href="https://example.com/v0.158.0-alpha.1"/><title>0.158.0-alpha.1</title></entry>
        </feed>
        """.utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, alphas) }
        let releases = FeedSource(id: "codex-releases", name: "Codex", url: URL(string: "https://example.com/releases.atom")!, skipsPrereleases: true)
        var cache = NewsCache()
        cache.items[releases.id] = [FeedItem(id: "v0.157.0", title: "0.157.0", link: URL(string: "https://example.com/v0.157.0"), published: utc(2026, 9, 24), source: "Codex")]
        let now = utc(2026, 9, 25, 12)
        let result = await NewsFetcher.refresh(cache, sources: [releases], following: [], now: now).cache
        XCTAssertEqual(result.items[releases.id]?.map(\.id), ["v0.157.0"], "Nothing left after skipping pre-releases: the last releases stay")
        XCTAssertNil(result.unreadable, "The feed was read")
        XCTAssertEqual(result.sourceChecks?[releases.id]?.succeededAt, now)
    }

    func testAPartialReadKeepsToAFeedsUsualLength() async {
        defer { unstubNetwork() }
        let now = utc(2026, 9, 25, 12)
        var cache = NewsCache()
        cache.items["long"] = (0..<FeedParser.itemLimit).map { index in
            FeedItem(id: "old-\(index)", title: "Old \(index)", link: URL(string: "https://example.com/old-\(index)"), published: utc(2026, 9, 1).addingTimeInterval(Double(index) * 3600), source: "Long")
        }
        let fresh = (0..<5).map { "<item><title>New \($0)</title><link>https://example.com/new-\($0)</link><pubDate>Thu, 24 Sep 2026 1\($0):00:00 GMT</pubDate></item>" }.joined()
        let cut = Data("<rss version=\"2.0\"><channel>\(fresh)<item><title>Cut off".utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, cut) }
        let source = FeedSource(id: "long", name: "Long", url: URL(string: "https://example.com/long.xml")!)
        let items = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now).cache.items["long"] ?? []
        XCTAssertEqual(items.count, FeedParser.itemLimit, "What arrived joins the last copy, up to a feed's usual length")
        XCTAssertEqual(items.prefix(5).map(\.title), ["New 4", "New 3", "New 2", "New 1", "New 0"])
        XCTAssertFalse(items.contains { $0.id == "old-0" || $0.id == "old-4" }, "The oldest give way")
        XCTAssertEqual(items.last?.id, "old-5")
    }

    func testFailedChecksWaitBeforeAskingAgain() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (503, Data()) }
        let now = utc(2026, 9, 25, 12)
        var cache = await NewsFetcher.refresh(NewsCache(), sources: [claudeCode], following: [], now: now).cache
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "The model list and the feed")
        XCTAssertEqual(cache.modelsFailedAt, now)
        XCTAssertEqual(cache.announcementsFailedAt, now)
        XCTAssertEqual(cache.unreadable, [ModelFeed.id, "claude-code"])

        XCTAssertEqual(cache.modelsFailures, 1)
        XCTAssertEqual(cache.sourceChecks?["claude-code"]?.failures, 1)

        // Each failure in a row waits longer: 5 minutes, 15, 30, then an hour.
        var last = now
        var expected = 2
        for (failures, wait) in [(1, 300.0), (2, 900), (3, 1800), (4, 3600), (5, 3600)] {
            cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: last.addingTimeInterval(wait - 60)).cache
            XCTAssertEqual(StubURLProtocol.requests.count, expected, "After \(failures) in a row, not before \(wait) s")
            last = last.addingTimeInterval(wait)
            cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: last).cache
            expected += 2
            XCTAssertEqual(StubURLProtocol.requests.count, expected, "After \(failures) in a row, again at \(wait) s")
            XCTAssertEqual(cache.modelsFailures, failures + 1)
            XCTAssertEqual(cache.sourceChecks?["claude-code"]?.failures, failures + 1)
        }

        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: last.addingTimeInterval(60)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, expected + 2, "Asking now (pulling to refresh, Check now) still goes out")

        // An answer starts the count again.
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (200, Self.noModels) : (200, Self.rss("Back", "Thu, 24 Sep 2026 12:00:00 GMT")) }
        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: last.addingTimeInterval(120)).cache
        XCTAssertNil(cache.modelsFailures)
        XCTAssertNil(cache.sourceChecks?["claude-code"]?.failures)
        StubURLProtocol.handler = { _ in (503, Data()) }
        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: last.addingTimeInterval(180)).cache
        XCTAssertEqual(cache.sourceChecks?["claude-code"]?.failures, 1)
        XCTAssertEqual(cache.modelsFailures, 1)
        let count = StubURLProtocol.requests.count
        _ = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: last.addingTimeInterval(180 + 300)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, count + 2, "Back to a 5-minute wait")
    }

    func testCatalogIsHTTPSAndUnique() {
        XCTAssertEqual(Set(FeedSource.catalog.map(\.id)).count, FeedSource.catalog.count)
        XCTAssertTrue(FeedSource.catalog.allSatisfy { $0.url.scheme == "https" })
    }

    func testCodexChangelogKeepsOnlyCodexNotesAndMayBeLarger() throws {
        let changelog = try XCTUnwrap(FeedSource.catalog.first { $0.id == "codex-changelog" })
        XCTAssertEqual(changelog.linkContains, "#codex-", "Its CLI entries repeat codex-releases")
        XCTAssertEqual(changelog.sizeLimit, 4 * 1024 * 1024)
        let releaseFeeds = FeedSource.catalog.filter { $0.url.path.hasSuffix("/releases.atom") }
        XCTAssertGreaterThanOrEqual(releaseFeeds.count, 9)
        for source in releaseFeeds {
            XCTAssertTrue(source.skipsPrereleases, "\(source.id) is a release feed, so it skips pre-releases")
        }
        XCTAssertFalse(try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-skills" }).skipsPrereleases, "A commit feed has no pre-releases to skip")
        XCTAssertTrue(FeedSource.catalog.filter { $0.id != "codex-changelog" }.allSatisfy { $0.sizeLimit == FeedParser.sizeLimit })
    }

    /// The official feeds added in October 2026, checked live from the main checkout that day.
    private static let addedSources: [String: Provider] = [
        "gemini-cli": .antigravity, "copilot-cli": .copilot, "opencode": .opencodeGo, "claude-code-whats-new": .claude,
        "claude-agent-sdk": .claude, "claude-skills": .claude, "deepmind": .antigravity,
    ]

    @MainActor
    func testTheAddedSourcesAreTogglesWithTheirToolsIcons() throws {
        let added = FeedSource.catalog.filter { Self.addedSources[$0.id] != nil }
        XCTAssertEqual(Set(added.map(\.id)), Set(Self.addedSources.keys))
        for source in added {
            XCTAssertEqual(source.provider, Self.addedSources[source.id], "\(source.id) shows its tool's icon")
            XCTAssertNil(source.partOf, "\(source.id) is turned on and off by itself")
            XCTAssertTrue(FeedSource.toggles.contains(source))
            XCTAssertEqual(source.kind, .officialAnnouncement)
        }
        XCTAssertEqual(Set(added.filter(\.skipsPrereleases).map(\.id)), ["gemini-cli", "copilot-cli", "opencode", "claude-agent-sdk"])
        XCTAssertTrue(added.allSatisfy { !NewsStore.firstCatalog.contains($0.id) }, "New since 2.0, so a list saved before turns them on")
    }

    func testPrereleasesIncludeNightliesPreviewsAndNumberedOnes() throws {
        for title in ["v0.67.0-nightly.20261021.gd00859d6b", "v0.66.0-preview.0", "1.0.102-0", "1.0.102-1", "0.158.0-alpha.14",
                      "2.2.0-rc.1", "2.2.0 beta", "1.0.0-canary.3", "1.2.0.dev1", "3.0.0-next.2", "1.0.0-SNAPSHOT"] {
            XCTAssertTrue(FeedParser.isPrerelease(title), title)
        }
        for title in ["Release v0.65.0", "1.0.102", "v2.1.2", "v0.66.0", "Claude Code 2.1.282", "kimi-code-2.1.1",
                      "What's next for Gemini", "Developer preview of agents", "2026-10-21 release notes"] {
            XCTAssertFalse(FeedParser.isPrerelease(title), title)
        }
        // Gemini CLI's releases as published: mostly nightlies and previews.
        let gemini = try XCTUnwrap(FeedSource.catalog.first { $0.id == "gemini-cli" })
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>n</id><title>v0.67.0-nightly.20261021.gd00859d6b</title><link href="https://github.com/google-gemini/gemini-cli/releases/tag/n"/><updated>2026-10-21T00:00:00Z</updated></entry>
          <entry><id>p</id><title>v0.66.0-preview.0</title><link href="https://github.com/google-gemini/gemini-cli/releases/tag/p"/><updated>2026-10-20T00:00:00Z</updated></entry>
          <entry><id>s</id><title>Release v0.65.0</title><link href="https://github.com/google-gemini/gemini-cli/releases/tag/s"/><updated>2026-10-19T00:00:00Z</updated></entry>
        </feed>
        """.utf8)
        XCTAssertEqual(FeedParser.items(from: atom, source: gemini).map(\.title), ["Release v0.65.0"])
    }

    func testOpenCodeReadsItsNewHomeWithoutItsGitHubIntegrationsReleases() throws {
        let opencode = try XCTUnwrap(FeedSource.catalog.first { $0.id == "opencode" })
        XCTAssertEqual(opencode.url.absoluteString, "https://github.com/anomalyco/opencode/releases.atom", "sst/opencode answers with a redirect here")
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>a</id><title>v1.2.28</title><link href="https://github.com/anomalyco/opencode/releases/tag/v1.2.28"/><updated>2026-10-21T00:00:00Z</updated></entry>
          <entry><id>b</id><title>github-v1.2.27</title><link href="https://github.com/anomalyco/opencode/releases/tag/github-v1.2.27"/><updated>2026-10-20T00:00:00Z</updated></entry>
          <entry><id>c</id><title>GitHub-v1.2.26</title><link href="https://github.com/anomalyco/opencode/releases/tag/github-v1.2.26"/><updated>2026-10-19T00:00:00Z</updated></entry>
          <entry><id>d</id><title>v1.2.27</title><link href="https://github.com/anomalyco/opencode/releases/tag/v1.2.27"/><updated>2026-10-18T00:00:00Z</updated></entry>
        </feed>
        """.utf8)
        XCTAssertEqual(FeedParser.items(from: atom, source: opencode).map(\.displayTitle), ["OpenCode v1.2.28", "OpenCode v1.2.27"])
        let read = FeedParser.read(atom, source: opencode)
        XCTAssertEqual(read.entries, 4, "Left out, not missing: the feed is still whole")
        XCTAssertTrue(read.isComplete)
    }

    func testGoogleDeepMindAndGeminiShowAPostTheyShareOnce() throws {
        let gemini = try XCTUnwrap(FeedSource.catalog.first { $0.id == "gemini" })
        let deepmind = try XCTUnwrap(FeedSource.catalog.first { $0.id == "deepmind" })
        var cache = NewsCache()
        cache.items = [
            "gemini": [
                FeedItem(id: "g1", title: "Gemini 3 Flash is here", link: URL(string: "https://blog.google/products/gemini/gemini-3-flash/?utm_source=rss"), published: utc(2026, 10, 20, 15), source: "Google Gemini"),
                FeedItem(id: "g2", title: "Try Gemini in Chrome", link: URL(string: "https://blog.google/products/gemini/gemini-in-chrome/"), published: utc(2026, 10, 19), source: "Google Gemini"),
            ],
            "deepmind": [
                FeedItem(id: "d1", title: "Gemini 3 Flash: frontier intelligence built for speed", link: URL(string: "https://deepmind.google/discover/blog/gemini-3-flash/"), published: utc(2026, 10, 20, 16), source: "Google DeepMind"),
                FeedItem(id: "d2", title: "Try Gemini in Chrome", link: URL(string: "https://www.blog.google/products/gemini/gemini-in-chrome"), published: utc(2026, 10, 19, 1), source: "Google DeepMind"),
                FeedItem(id: "d3", title: "AlphaFold at five", link: URL(string: "https://deepmind.google/discover/blog/alphafold-at-five/"), published: utc(2026, 10, 18), source: "Google DeepMind"),
            ],
        ]
        let shown = cache.announcements(from: [gemini, deepmind])
        XCTAssertEqual(shown.count, 3, "The same post on both blogs shows once, however its link is written")
        XCTAssertNotNil(shown.first { $0.title.contains("Gemini 3 Flash") }?.alsoIn, "…noting the other blog")
        XCTAssertNotNil(shown.first { $0.title == "Try Gemini in Chrome" }?.alsoIn)
        XCTAssertTrue(shown.contains { $0.title == "AlphaFold at five" })

        // Changelogs link each entry to its own anchor on one page: those stay apart.
        var anchors = NewsCache()
        let cursor = try XCTUnwrap(FeedSource.catalog.first { $0.id == "cursor" })
        anchors.items["cursor"] = (1...3).map { FeedItem(id: "c\($0)", title: "Release \($0)", link: URL(string: "https://cursor.com/changelog#1-\($0)"), published: utc(2026, 10, $0), source: "Cursor") }
        XCTAssertEqual(anchors.announcements(from: [cursor]).count, 3)
    }

    func testOpenCodesPullRequestArtifactsAreLeftOut() throws {
        let opencode = try XCTUnwrap(FeedSource.catalog.first { $0.id == "opencode" })
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><id>a</id><title>PR #38252 verification videos</title><link href="https://github.com/anomalyco/opencode/releases/tag/pr-38252"/><updated>2026-10-21T00:00:00Z</updated></entry>
          <entry><id>b</id><title>v1.2.28</title><link href="https://github.com/anomalyco/opencode/releases/tag/v1.2.28"/><updated>2026-10-20T00:00:00Z</updated></entry>
        </feed>
        """.utf8)
        XCTAssertEqual(FeedParser.items(from: atom, source: opencode).map(\.title), ["v1.2.28"])
    }

    func testTheSkillsLogShowsADaysUpdatesOnceAndWholeWords() throws {
        let skills = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-skills" })
        func entry(_ sha: String, _ title: String, _ time: String) -> String {
            "<entry><id>tag:github.com,2008:Grit::Commit/\(sha)</id><link rel=\"alternate\" href=\"https://github.com/anthropics/skills/commit/\(sha)\"/><title>\(title)</title><updated>\(time)</updated></entry>"
        }
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom">
        \(entry("a3", "Update claude-api skill: add guidance for structured outp…", "2026-10-21T18:00:00Z"))
        \(entry("a2", "Update claude-api skill (#1601)", "2026-10-21T12:00:00Z"))
        \(entry("p1", "Update pdf skill (#1600)", "2026-10-21T11:00:00Z"))
        \(entry("n1", "Add discernment-nudge skill (#1553)", "2026-10-21T10:00:00Z"))
        \(entry("a1", "Update claude-api skill (#1590)", "2026-10-20T09:00:00Z"))
        </feed>
        """.utf8)
        let items = FeedParser.items(from: atom, source: skills)
        XCTAssertEqual(items.map { $0.id.components(separatedBy: "/").last }, ["a3", "p1", "n1", "a1"], "One row per thing updated a day, the newest; a new skill always shows")
        XCTAssertEqual(items.first?.displayTitle, "Update claude-api skill: add guidance for structured…", "GitHub's cut word goes; the ellipsis stays")
        XCTAssertEqual(FeedParser.wholeWords("Short title"), "Short title")
        XCTAssertEqual(FeedParser.wholeWords("Trailing space …"), "Trailing space…")
        XCTAssertEqual(FeedParser.wholeWords("Onewordcutoff…"), "Onewordcutoff…", "Nothing to cut back to")
    }

    func testCommitsWithTheSameMessageStayApartAndShowWithoutTheirPullRequestNumber() throws {
        func entry(_ sha: String, _ title: String, _ day: Int) -> String {
            """
            <entry><id>tag:github.com,2008:Grit::Commit/\(sha)</id><link type="text/html" rel="alternate" href="https://github.com/anthropics/skills/commit/\(sha)"/>
              <title>
                  \(title)
              </title><updated>2026-10-\(day)T09:00:00Z</updated></entry>
            """
        }
        let atom = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Recent Commits to skills:main</title>
        \(entry("c162", "Update pdf skill (#162)", 20))
        \(entry("c140", "Update pdf skill (#140)", 18))
        \(entry("r2", "Update README.md", 17))
        \(entry("r1", "Update README.md", 16))
        \(entry("n1", "Update the (#1) ranking notes", 15))
        </feed>
        """.utf8)
        let skills = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-skills" })
        let items = FeedParser.items(from: atom, source: skills)
        XCTAssertEqual(items.map(\.id).map { $0.components(separatedBy: "/").last }, ["c162", "c140", "r2", "r1", "n1"], "Each commit is its own entry, whatever its message")
        XCTAssertEqual(items.map(\.displayTitle), ["Update pdf skill", "Update pdf skill", "Update README.md", "Update README.md", "Update the (#1) ranking notes"], "Only a trailing pull request number is left off, and only when shown")
        XCTAssertEqual(items.first?.title, "Update pdf skill (#162)")

        // Read before with the older commits; the newer pdf commit arrives later and is new.
        var cache = NewsCache()
        cache.items[skills.id] = NewsFetcher.firstSeen(Array(items.dropFirst()), previous: [], now: utc(2026, 10, 19))
        cache.items[skills.id] = NewsFetcher.firstSeen(items, previous: cache.items[skills.id] ?? [], now: utc(2026, 10, 21))
        let shown = cache.announcements(from: [skills])
        XCTAssertEqual(shown.count, 5, "Nothing folds by title in a commit feed")
        XCTAssertEqual(shown.first { $0.id.hasSuffix("c162") }?.newsDate, utc(2026, 10, 21), "The new commit counts from when it arrived")
        XCTAssertEqual(FeedParser.cleanTitle("@scope/package@2.1.1"), "2.1.1")
    }

    // MARK: Titles and duplicates

    func testBareVersionTitlesNameTheirFeed() {
        func title(_ text: String) -> String {
            FeedItem(id: text, title: text, link: nil, published: nil, source: "Codex").displayTitle
        }
        XCTAssertEqual(title("0.157.0"), "Codex 0.157.0")
        XCTAssertEqual(title("v2.1.282"), "Codex v2.1.282")
        XCTAssertEqual(title("1.2.0-beta.1"), "Codex 1.2.0-beta.1")
        XCTAssertEqual(title("Introducing GPT-6"), "Introducing GPT-6")
        XCTAssertEqual(title("Codex 0.157.0"), "Codex 0.157.0", "Already named")
        XCTAssertEqual(title("2026"), "2026", "A year isn't a version")
    }

    func testARepeatedTitleInOneFeedShowsOnce() {
        let rss = Data("""
        <rss version="2.0"><channel>
          <item><title>ChatGPT for iOS</title><link>https://example.com/ios-3</link><pubDate>Thu, 24 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>Projects in ChatGPT</title><link>https://example.com/projects</link><pubDate>Wed, 23 Sep 2026 12:00:00 GMT</pubDate></item>
          <item><title>chatgpt for iOS</title><link>https://example.com/ios-2</link><pubDate>Tue, 22 Sep 2026 12:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        let items = FeedParser.items(from: rss, source: claudeCode)
        XCTAssertEqual(items.map(\.title), ["ChatGPT for iOS", "Projects in ChatGPT"])
        XCTAssertEqual(items.first?.link?.absoluteString, "https://example.com/ios-3", "The first, newest one stays")
    }

    func testAnAnnouncementTwoFeedsShareShowsOnce() {
        let shared = URL(string: "https://example.com/blog/launch")!
        var cache = NewsCache()
        cache.items = [
            "blog": [
                FeedItem(id: "b1", title: "Launch", link: shared, published: utc(2026, 9, 24), source: "Blog"),
                FeedItem(id: "b2", title: "Without a link", link: nil, published: utc(2026, 9, 20), source: "Blog"),
            ],
            "news": [
                FeedItem(id: "n1", title: "Launch", link: shared, published: utc(2026, 9, 23), source: "News"),
                FeedItem(id: "n2", title: "Also without a link", link: nil, published: utc(2026, 9, 19), source: "News"),
            ],
        ]
        let sources = ["blog", "news"].map { FeedSource(id: $0, name: $0, url: URL(string: "https://example.com/\($0).xml")!) }
        XCTAssertEqual(cache.announcements(from: sources).map(\.id), ["b1", "b2", "n2"], "The newest copy of a shared link; items without links all stay")
        XCTAssertEqual(cache.announcements(from: sources).map(\.alsoIn), ["news", nil, nil], "The kept copy notes the feed folded into it")
        XCTAssertEqual(cache.announcements(from: [sources[1]]).map(\.id), ["n1", "n2"], "Alone, a feed keeps its copy")
        XCTAssertNil(cache.announcements(from: [sources[1]]).first?.alsoIn)
    }

    func testTitlesOnlyFoldWithinAProduct() {
        var cache = NewsCache()
        cache.items = [
            "zai": [FeedItem(id: "z1", title: "Release notes", link: URL(string: "https://example.com/zai/notes"), published: utc(2026, 9, 24), source: "Z.ai")],
            "devin": [FeedItem(id: "d1", title: "Release notes", link: URL(string: "https://example.com/devin/notes"), published: utc(2026, 9, 20), source: "Devin")],
            "cursor": [FeedItem(id: "c1", title: "Faster agents", link: URL(string: "https://example.com/launch"), published: utc(2026, 9, 23), source: "Cursor")],
            "copilot": [FeedItem(id: "g1", title: "Agents everywhere", link: URL(string: "https://example.com/launch"), published: utc(2026, 9, 22), source: "GitHub Copilot")],
        ]
        let shown = cache.announcements(from: FeedSource.catalog)
        XCTAssertEqual(shown.map(\.id), ["z1", "c1", "d1"], "Two labs' \"Release notes\" are two posts; two products linking to one page are one")
        XCTAssertEqual(shown.map(\.alsoIn), [nil, "GitHub Copilot", nil])
        XCTAssertEqual(shown.last?.published, utc(2026, 9, 20), "Each dated by its own feed")
    }

    func testTheSameVersionFromTwoFeedsShowsOnce() throws {
        let releases = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code-releases" })
        XCTAssertEqual(releases.partOf, "claude-code")
        XCTAssertFalse(FeedSource.toggles.contains(releases), "It's turned on and off with the changelog")
        let atom = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Release notes from claude-code</title>
          <entry><id>tag:github.com,2008:Repository/1/v2.1.283</id><updated>2026-09-25T18:00:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/anthropics/claude-code/releases/tag/v2.1.283"/><title>v2.1.283</title></entry>
          <entry><id>tag:github.com,2008:Repository/1/v2.1.282</id><updated>2026-09-24T18:00:00Z</updated>
            <link rel="alternate" type="text/html" href="https://github.com/anthropics/claude-code/releases/tag/v2.1.282"/><title>v2.1.282</title></entry>
        </feed>
        """.utf8)
        var cache = NewsCache()
        cache.items = [
            "claude-code": [FeedItem(id: "c1", title: "2.1.282", link: URL(string: "https://code.claude.com/docs/en/changelog#2-1-282"), published: utc(2026, 9, 24, 20), source: "Claude Code")],
            "claude-code-releases": FeedParser.items(from: atom, source: releases),
        ]
        let shown = cache.announcements(from: FeedSource.catalog)
        XCTAssertEqual(shown.map(\.displayTitle), ["Claude Code v2.1.283", "Claude Code 2.1.282"], "2.1.282 is in both feeds and shows once; 2.1.283 isn't in the changelog yet")
        XCTAssertEqual(Set(shown.map(\.source)), ["Claude Code"], "Both read as Claude Code")
        XCTAssertEqual(shown.last?.firstSeenAt, utc(2026, 9, 24, 18), "First-seen bookkeeping stays separate from publication date")
        XCTAssertEqual(shown.map(\.alsoIn), [nil, "Claude Code releases"], "The changelog's copy notes the releases feed it folded")

        // The releases feed's copy kept, the changelog's folded: named so it doesn't read as its own source.
        cache.items["claude-code"] = [FeedItem(id: "c1", title: "2.1.282", link: URL(string: "https://code.claude.com/docs/en/changelog#2-1-282"), published: utc(2026, 9, 24, 12), source: "Claude Code")]
        XCTAssertEqual(cache.announcements(from: FeedSource.catalog).last?.alsoIn, "Claude Code changelog")
    }

    func testEachFeedHasItsOwnSizeLimit() {
        let notes = String(repeating: "Release notes. ", count: 180_000) // about 2.6 MB
        let rss = Data("<rss version=\"2.0\"><channel><item><title>Long notes</title><link>https://example.com/notes</link><description>\(notes)</description></item></channel></rss>".utf8)
        XCTAssertGreaterThan(rss.count, FeedParser.sizeLimit)
        XCTAssertTrue(FeedParser.items(from: rss, source: claudeCode).isEmpty)
        let larger = FeedSource(id: "long", name: "Long", url: URL(string: "https://example.com/long.xml")!, sizeLimit: 4 * 1024 * 1024)
        XCTAssertEqual(FeedParser.items(from: rss, source: larger).map(\.title), ["Long notes"])
    }

    // MARK: What's new since News was opened

    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        // Named by the class and a count: macOS keeps an empty preferences file for every name.
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

    /// A News folder holding two followed releases, one unfollowed, and two Claude Code notes.
    private func makeNewsFolder() throws -> URL {
        let folder = try makeFolder()
        func release(_ id: String, _ vendor: String, _ created: Date) -> ModelRelease {
            ModelRelease(id: id, name: id, vendor: vendor, created: created, contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        }
        var cache = NewsCache()
        cache.models = [
            release("anthropic/claude-new", "anthropic", utc(2026, 9, 25, 9)),
            release("qwen/qwen-new", "qwen", utc(2026, 9, 25, 9)),
            release("openai/gpt-old", "openai", utc(2026, 9, 20)),
        ]
        cache.items = ["claude-code": [
            FeedItem(id: "new", title: "2.1.300", link: URL(string: "https://example.com/2-1-300"), published: utc(2026, 9, 25, 8), source: "Claude Code"),
            FeedItem(id: "old", title: "2.1.200", link: URL(string: "https://example.com/2-1-200"), published: utc(2026, 9, 1), source: "Claude Code"),
        ]]
        cache.save(to: folder)
        return folder
    }

    @MainActor
    func testUnseenCountsCoverFollowedNewsSinceTheLastVisit() throws {
        let defaults = makeDefaults()
        let folder = try makeNewsFolder()
        defaults.set(utc(2026, 9, 24).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: folder, now: utc(2026, 9, 25, 12), fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(news.unseenModelCount(now: utc(2026, 9, 25, 12)), 1, "Only labs that are followed")
        XCTAssertEqual(news.unseenAnnouncementCount, 1)
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 25, 12)), 2)

        news.markSeen(now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 25, 12)), 0, "Opening News clears the badge")
        XCTAssertTrue(news.isNew(utc(2026, 9, 25, 8)), "…and keeps this visit's new items marked")
        XCTAssertFalse(news.isNew(utc(2026, 9, 23)))
        XCTAssertFalse(news.isNew(nil))

        let nextVisit = NewsStore(defaults: defaults, directory: folder, now: utc(2026, 9, 26), fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(nextVisit.unseenCount(now: utc(2026, 9, 26)), 0)
        XCTAssertFalse(nextVisit.isNew(utc(2026, 9, 25, 8)), "Seen last time")
    }

    @MainActor
    func testAFirstLaunchDoesntCallEverythingNew() throws {
        let defaults = makeDefaults()
        let news = NewsStore(defaults: defaults, directory: try makeNewsFolder(), now: utc(2026, 9, 25, 12), fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 25, 12)), 0)
        XCTAssertEqual(defaults.double(forKey: NewsStore.Keys.seenAt), utc(2026, 9, 25, 12).timeIntervalSince1970, "Remembered, so the next launch counts from here")
        news.markSeen(now: utc(2026, 9, 25, 11))
        XCTAssertEqual(defaults.double(forKey: NewsStore.Keys.seenAt), utc(2026, 9, 25, 12).timeIntervalSince1970, "Never moves back")
    }

    /// One item, linked to `https://example.com/<title>`.
    private static func rss(_ title: String, _ date: String) -> Data {
        Data("<rss version=\"2.0\"><channel><item><title>\(title)</title><link>https://example.com/\(title)</link><pubDate>\(date)</pubDate></item></channel></rss>".utf8)
    }

    /// One model from a followed lab.
    private static func modelList(_ id: String, created: Date) -> Data {
        Data(#"{"data":[{"id":"\#(id)","name":"Anthropic: Test","created":\#(Int(created.timeIntervalSince1970))}]}"#.utf8)
    }

    @MainActor
    func testTurningNewsOnCountsFromTheFirstCheck() async throws {
        defer { unstubNetwork() }
        let models = Self.modelList("anthropic/claude-test", created: utc(2026, 9, 24))
        let feed = Self.rss("2.1.300", "Thu, 24 Sep 2026 12:00:00 GMT")
        stubNetwork { request in request.url == ModelFeed.url ? (200, models) : (200, feed) }
        // The Mac makes its News store at first launch, weeks before News is turned on.
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), now: utc(2026, 9, 1), fetch: { await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources, isAllowed: $0.isAllowed) }, notify: { _, _, _ in })
        news.followedSources = ["claude-code"]
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.models().count, 1)
        XCTAssertEqual(news.announcements.count, 1)
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 25, 12)), 0, "What News finds when it's turned on isn't new")
        XCTAssertFalse(news.isNew(utc(2026, 9, 24)))

        let newer = Self.rss("2.1.301", "Sat, 26 Sep 2026 12:00:00 GMT")
        StubURLProtocol.handler = { request in request.url == ModelFeed.url ? (304, Data()) : (200, newer) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 26, 13))
        XCTAssertEqual(news.unseenAnnouncementCount, 1, "What later checks find is")
    }

    @MainActor
    func testAnItemDatedAheadIsSeenOnceNewsOpens() async throws {
        defer { unstubNetwork() }
        // Two days ahead: a wrong time zone, or a post scheduled early.
        let models = Self.modelList("anthropic/claude-ahead", created: utc(2026, 9, 27, 12))
        let feed = Self.rss("Scheduled", "Sun, 27 Sep 2026 12:00:00 GMT")
        stubNetwork { request in request.url == ModelFeed.url ? (200, models) : (200, feed) }
        let folder = try makeFolder()
        var checked = NewsCache()
        checked.modelsFetchedAt = utc(2026, 9, 24)
        checked.announcementsFetchedAt = utc(2026, 9, 24)
        // Read before, so what they bring now is new: a feed's first read marks nothing new.
        let older = FeedItem(id: "older", title: "Older", link: URL(string: "https://example.com/older"), published: utc(2026, 9, 20), source: "Claude Code")
        checked.items = ["claude-code": [older], "claude-code-releases": [older]]
        checked.save(to: folder)
        let defaults = makeDefaults()
        defaults.set(utc(2026, 9, 24).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: folder, fetch: { await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources, isAllowed: $0.isAllowed) }, notify: { _, _, _ in })
        news.followedSources = ["claude-code"]
        let now = utc(2026, 9, 25, 12)
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now)
        XCTAssertEqual(news.announcements.first?.published, now, "Dated when it arrived")
        XCTAssertEqual(news.models().first?.created, now)
        XCTAssertEqual(news.unseenCount(now: now), 2)

        news.markSeen(now: now.addingTimeInterval(3600))
        XCTAssertEqual(news.unseenCount(now: now.addingTimeInterval(3600)), 0, "Opening News clears it")

        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 28))
        XCTAssertEqual(news.announcements.first?.published, now, "Once its date has passed, it keeps the one it arrived with")
        XCTAssertEqual(news.models().first?.created, now)
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 28)), 0, "…so it isn't new again")
    }

    /// Feeds read before, with a cached copy each, as of `checkedAt`.
    private func readBefore(_ ids: [String], checkedAt: Date) -> NewsCache {
        var cache = NewsCache()
        cache.modelsFetchedAt = checkedAt
        cache.announcementsFetchedAt = checkedAt
        for id in ids {
            cache.items[id] = [FeedItem(id: "older", title: "Older", link: URL(string: "https://example.com/older"), published: checkedAt.addingTimeInterval(-86_400), source: id)]
            cache.sourceChecks = (cache.sourceChecks ?? [:]).merging([id: .init(succeededAt: checkedAt)]) { $1 }
        }
        return cache
    }

    @MainActor
    func testAnEntryDatedBeforeItArrivedIsStillNew() async throws {
        defer { unstubNetwork() }
        let folder = try makeFolder()
        readBefore(["claude-code", "claude-code-releases"], checkedAt: utc(2026, 9, 26, 9)).save(to: folder)
        let defaults = makeDefaults()
        defaults.set(utc(2026, 9, 26, 10).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt) // Looked at 10:00.
        let news = NewsStore(defaults: defaults, directory: folder, notify: { _, _, _ in })
        news.followedSources = ["claude-code"]
        // Dated by the day, so midnight, but only in the feed at 14:00.
        let feed = Self.rss("Midnight-post", "Sat, 26 Sep 2026 00:00:00 GMT")
        stubNetwork { request in request.url == ModelFeed.url ? (304, Data()) : (200, feed) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 26, 14))
        let post = try XCTUnwrap(news.allAnnouncements.first { $0.title == "Midnight-post" })
        XCTAssertEqual(post.newsDate, utc(2026, 9, 26, 14), "New as of when it arrived")
        XCTAssertEqual(post.sortDate, utc(2026, 9, 26), "Still sorted and shown by its own date")
        XCTAssertEqual(news.unseenAnnouncementCount, 1, "Badged, though dated before the last look")

        news.beginVisit(now: utc(2026, 9, 26, 15))
        XCTAssertTrue(news.isNew(post.newsDate), "…and marked New on the next")
        let edition = NewsEditions.today(models: [], announcements: news.allAnnouncements, retiring: [], since: news.visitBaseline, now: utc(2026, 9, 26, 15))
        XCTAssertEqual(edition.digest.updates, 1)
        XCTAssertEqual(edition.tools.first { $0.sourceID == "claude-code" || $0.source == "Claude Code" }?.newCount, 1)
    }

    /// Updating to a release with the added feeds: they start on, are read on the next check,
    /// and their back catalogs, recent posts included, aren't badged or marked New.
    @MainActor
    func testTheAddedSourcesStartOnAndTheirBackCatalogsArentNew() async throws {
        defer { unstubNetwork() }
        let added = Set(Self.addedSources.keys)
        let folder = try makeFolder()
        readBefore(["claude-code", "claude-code-releases"], checkedAt: utc(2026, 10, 20, 9)).save(to: folder)
        let defaults = makeDefaults()
        defaults.set(utc(2026, 10, 20, 10).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        defaults.set(["claude-code"], forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id).filter { !added.contains($0) }, forKey: NewsStore.Keys.knownSources)
        let news = NewsStore(defaults: defaults, directory: folder, notify: { _, _, _ in })
        XCTAssertEqual(news.followedSources, added.union(["claude-code"]), "Added since the list was saved: they start on")

        let ids = Dictionary(uniqueKeysWithValues: FeedSource.catalog.filter { added.contains($0.id) }.map { ($0.url, $0.id) })
        // Each one's back catalog has a post from after the last look.
        stubNetwork { request in
            guard let url = request.url, let id = ids[url] else { return (304, Data()) }
            return (200, Self.rss("Archive-\(id)", "Tue, 20 Oct 2026 12:00:00 GMT"))
        }
        await news.refresh(preferences: AlertPreferences(), notifies: false, now: utc(2026, 10, 20, 14))
        for id in added {
            XCTAssertEqual(news.cache.items[id]?.map(\.title), ["Archive-\(id)"], "\(id) is read on the next check")
        }
        XCTAssertEqual(news.unseenAnnouncementCount, 0, "No back catalog is badged")
        news.beginVisit(now: utc(2026, 10, 20, 15))
        XCTAssertFalse(news.allAnnouncements.contains { added.contains($0.sourceID ?? "") && news.isNew($0.newsDate) }, "…or marked New")
        news.endVisit()

        // What they bring after that is new.
        stubNetwork { request in
            guard let url = request.url, let id = ids[url] else { return (304, Data()) }
            return (200, Data("<rss version=\"2.0\"><channel><item><title>Next-\(id)</title><link>https://example.com/Next-\(id)</link><pubDate>Tue, 20 Oct 2026 16:00:00 GMT</pubDate></item><item><title>Archive-\(id)</title><link>https://example.com/Archive-\(id)</link><pubDate>Tue, 20 Oct 2026 12:00:00 GMT</pubDate></item></channel></rss>".utf8))
        }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 10, 20, 17))
        XCTAssertEqual(news.unseenAnnouncementCount, added.count)
    }

    /// Turned off, then followed again before it was ever read: the feed is fetched at once.
    @MainActor
    func testFollowingAnAddedSourceFetchesItAtOnce() async throws {
        let defaults = makeDefaults()
        defaults.set(FeedSource.catalog.map(\.id).filter { $0 != "deepmind" }, forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        let forced = LockedBox<[Set<String>]>([])
        let news = NewsStore(defaults: defaults, directory: try makeFolder(), fetch: { request in
            forced.value.append(request.forcedSources)
            return .init(cache: request.cache, newModels: [])
        }, notify: { _, _, _ in })
        XCTAssertFalse(news.followedSources.contains("deepmind"), "Turned off stays off")
        news.followedSources.insert("deepmind")
        for _ in 0..<200 where forced.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(forced.value, [["deepmind"]])
        XCTAssertTrue(news.sources.contains { $0.id == "deepmind" })
    }

    /// Unfollowed for a month while News was in use, then followed again: what the feed and the
    /// voice published meanwhile is their back catalog, not a flood of New.
    @MainActor
    func testFollowingASourceAgainBringsWhatItMissedQuietly() async throws {
        defer { unstubNetwork() }
        let now = Date.now
        let month = now.addingTimeInterval(-30 * 86_400)
        let voice = try XCTUnwrap(NewsVoice.catalog.first?.feed)
        let folder = try makeFolder()
        var cache = readBefore(["claude-code", "claude-code-releases", "codex-releases", voice.id], checkedAt: month)
        cache.modelsFetchedAt = now.addingTimeInterval(-60)
        cache.save(to: folder)
        let defaults = makeDefaults()
        defaults.set(now.addingTimeInterval(-3600).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt) // Looked an hour ago.
        defaults.set(FeedSource.catalog.map(\.id).filter { $0 != "codex-releases" }, forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        let news = NewsStore(defaults: defaults, directory: folder, now: now, notify: { _, _, _ in })
        XCTAssertFalse(news.followedSources.contains("codex-releases"))

        // Each feed has three posts from the month it wasn't followed, and its old one.
        let missed = (1...3).map { "<item><title>Missed-\($0)</title><link>https://example.com/Missed-\($0)</link><pubDate>\(Self.rfc822(month.addingTimeInterval(Double($0) * 86_400)))</pubDate></item>" }.joined()
        let feed = Data("<rss version=\"2.0\"><channel>\(missed)<item><title>Older</title><link>https://example.com/older</link></item></channel></rss>".utf8)
        let codex = try XCTUnwrap(FeedSource.catalog.first { $0.id == "codex-releases" }).url
        let followedAgain: Set<URL> = [codex, voice.url]
        stubNetwork { request in followedAgain.contains(request.url!) ? (200, feed) : (304, Data()) }
        news.followedSources.insert("codex-releases")
        news.followedVoices.insert(voice.id)
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now)
        for _ in 0..<200 where news.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        for id in ["codex-releases", voice.id] {
            XCTAssertEqual(news.cache.items[id]?.filter { $0.title.hasPrefix("Missed") }.count, 3, "\(id) was read")
        }
        XCTAssertEqual(news.unseenAnnouncementCount, 0, "What they published while unfollowed isn't badged")
        news.beginVisit(now: now.addingTimeInterval(60))
        XCTAssertFalse(news.allAnnouncements.contains { news.isNew($0.newsDate) }, "…or marked New")
        news.endVisit()

        // After that read, what they bring is new again.
        let next = Data("<rss version=\"2.0\"><channel><item><title>Next</title><link>https://example.com/Next</link><pubDate>\(Self.rfc822(now))</pubDate></item>\(missed)</channel></rss>".utf8)
        stubNetwork { request in followedAgain.contains(request.url!) ? (200, next) : (304, Data()) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now.addingTimeInterval(120))
        for _ in 0..<200 where news.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(news.cache.items["codex-releases"]?.contains { $0.title == "Next" && ($0.newsDate ?? .distantPast) > news.seenAt } == true)
        XCTAssertTrue(news.cache.items[voice.id]?.contains { $0.title == "Next" && ($0.newsDate ?? .distantPast) > news.seenAt } == true)
    }

    private static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    /// An older post that newly enters the feed's 30-entry window was out before the last read,
    /// so it isn't new; a post dated by the day that turns up a few hours later still is.
    func testAnOldEntryEnteringTheWindowKeepsItsOwnDate() async {
        defer { unstubNetwork() }
        let now = utc(2026, 10, 21, 14)
        var cache = readBefore(["claude-code"], checkedAt: now.addingTimeInterval(-3600))
        cache.items["claude-code"] = [FeedItem(id: "https://example.com/older", title: "Older", link: URL(string: "https://example.com/older"), published: utc(2026, 10, 19), source: "Claude Code")]
        let feed = Data("""
        <rss version="2.0"><channel>
          <item><title>Midnight</title><link>https://example.com/midnight</link><pubDate>Wed, 21 Oct 2026 00:00:00 GMT</pubDate></item>
          <item><title>Older</title><link>https://example.com/older</link><pubDate>Mon, 19 Oct 2026 00:00:00 GMT</pubDate></item>
          <item><title>Ten-days-old</title><link>https://example.com/ten-days-old</link><pubDate>Sun, 11 Oct 2026 12:00:00 GMT</pubDate></item>
        </channel></rss>
        """.utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (304, Data()) : (200, feed) }
        let items = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now).cache.items["claude-code"] ?? []
        XCTAssertEqual(items.first { $0.title == "Ten-days-old" }?.newsDate, utc(2026, 10, 11, 12), "Out ten days before the last read: not new")
        XCTAssertEqual(items.first { $0.title == "Midnight" }?.newsDate, now, "Dated by the day, arrived since the last read: new")
    }

    /// A model listed after the last visit though created before it is new, as an announcement
    /// is; an old model newly in the list (one OpenRouter will retire) isn't.
    @MainActor
    func testAModelListedAfterTheLastVisitIsNew() async throws {
        defer { unstubNetwork() }
        let now = Date.now
        let folder = try makeFolder()
        var cache = readBefore([], checkedAt: now.addingTimeInterval(-3600))
        cache.models = [ModelRelease(id: "anthropic/claude-a", name: "Anthropic: A", vendor: "anthropic", created: now.addingTimeInterval(-86_400), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)]
        cache.save(to: folder)
        let defaults = makeDefaults()
        defaults.set(now.addingTimeInterval(-1800).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt) // Looked half an hour ago.
        let news = NewsStore(defaults: defaults, directory: folder, now: now, notify: { _, _, _ in })
        func model(_ id: String, _ created: Date, expires: String = "") -> String {
            #"{"id":"anthropic/\#(id)","name":"Anthropic: \#(id)","created":\#(Int(created.timeIntervalSince1970))\#(expires)}"#
        }
        let list = Data(#"{"data":[\#(model("claude-b", now.addingTimeInterval(-7200))),\#(model("claude-a", now.addingTimeInterval(-86_400))),\#(model("claude-old", now.addingTimeInterval(-90 * 86_400), expires: #","expiration_date":"2026-12-31""#))]}"#.utf8)
        stubNetwork { request in request.url == ModelFeed.url ? (200, list) : (304, Data()) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: now)
        XCTAssertEqual(news.models().first { $0.id == "anthropic/claude-b" }?.newsDate, now, "Created two hours ago, listed now")
        XCTAssertEqual(news.unseenModelCount(now: now), 1, "Badged, though created before the last look")
        news.beginVisit(now: now.addingTimeInterval(60))
        XCTAssertTrue(news.isNew(news.models().first { $0.id == "anthropic/claude-b" }?.newsDate))
        XCTAssertFalse(news.isNew(news.models().first { $0.id == "anthropic/claude-old" }?.newsDate), "An old model newly listed isn't new")
    }

    /// Dates saved while the clock was ahead don't keep a badge through visits.
    @MainActor
    func testFirstSeenDatesAheadOfTheClockComeBackToNow() throws {
        let now = Date.now
        let folder = try makeFolder()
        var cache = readBefore(["claude-code", "claude-code-releases"], checkedAt: now.addingTimeInterval(-3600))
        cache.items["claude-code"]?.append(FeedItem(id: "ahead", title: "Ahead", link: URL(string: "https://example.com/ahead"), published: now.addingTimeInterval(2 * 86_400), source: "Claude Code", firstSeenAt: now.addingTimeInterval(2 * 86_400)))
        cache.models = [ModelRelease(id: "anthropic/claude-ahead", name: "Anthropic: Ahead", vendor: "anthropic", created: now.addingTimeInterval(2 * 86_400), contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)]
        cache.save(to: folder)
        let defaults = makeDefaults()
        defaults.set(now.addingTimeInterval(-3600).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: folder, now: now, notify: { _, _, _ in })
        news.beginVisit(now: now)
        news.endVisit()
        XCTAssertEqual(news.unseenAnnouncementCount, 0, "Seen on the visit, not badged again until the clock catches up")
        XCTAssertEqual(news.unseenModelCount(now: now), 0)
        XCTAssertEqual(news.allAnnouncements.first { $0.id == "ahead" }?.newsDate, now)
    }

    @MainActor
    func testASourcesFirstReadMarksNothingNew() async throws {
        defer { unstubNetwork() }
        let folder = try makeFolder()
        readBefore(["claude-code", "claude-code-releases"], checkedAt: utc(2026, 9, 26, 9)).save(to: folder)
        let defaults = makeDefaults()
        defaults.set(utc(2026, 9, 26, 10).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        // Saved before Cursor was offered: it starts on, never read.
        defaults.set(["claude-code"], forKey: NewsStore.Keys.sources)
        defaults.set(FeedSource.catalog.map(\.id).filter { $0 != "cursor" }, forKey: NewsStore.Keys.knownSources)
        let news = NewsStore(defaults: defaults, directory: folder, notify: { _, _, _ in })
        XCTAssertTrue(news.followedSources.contains("cursor"))
        let cursor = try XCTUnwrap(FeedSource.catalog.first { $0.id == "cursor" }).url
        // Its back catalog includes a post from after the last look.
        let archive = Self.rss("Cursor-archive", "Sat, 26 Sep 2026 12:00:00 GMT")
        stubNetwork { request in
            if request.url == ModelFeed.url { return (304, Data()) }
            return request.url == cursor ? (200, archive) : (304, Data())
        }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 26, 14))
        let old = try XCTUnwrap(news.allAnnouncements.first { $0.title == "Cursor-archive" })
        XCTAssertEqual(news.unseenAnnouncementCount, 0, "A source's first read brings what it had: none of it is new")
        news.beginVisit(now: utc(2026, 9, 26, 15))
        XCTAssertFalse(news.isNew(old.newsDate))
        news.endVisit()

        let next = Data("<rss version=\"2.0\"><channel><item><title>Cursor-next</title><link>https://example.com/Cursor-next</link><pubDate>Sat, 26 Sep 2026 16:00:00 GMT</pubDate></item><item><title>Cursor-archive</title><link>https://example.com/Cursor-archive</link><pubDate>Sat, 26 Sep 2026 12:00:00 GMT</pubDate></item></channel></rss>".utf8)
        stubNetwork { request in
            if request.url == ModelFeed.url { return (304, Data()) }
            return request.url == cursor ? (200, next) : (304, Data())
        }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 26, 17))
        XCTAssertEqual(news.unseenAnnouncementCount, 1, "What it brings after that is new")
        XCTAssertEqual(news.allAnnouncements.first { $0.title == "Cursor-archive" }?.newsDate, old.newsDate, "The archive stays quiet")
    }

    @MainActor
    func testProblemsNameTheFeedsThatCouldntBeRead() async throws {
        defer { unstubNetwork() }
        let cursor = try XCTUnwrap(FeedSource.catalog.first { $0.id == "cursor" }).url
        let devin = try XCTUnwrap(FeedSource.catalog.first { $0.id == "devin" }).url
        // Each feed has one post of its own, titled by its host.
        let post: @Sendable (URLRequest) -> Data = { Self.rss($0.url?.host ?? "post", "Thu, 24 Sep 2026 12:00:00 GMT") }
        stubNetwork { request in
            if request.url == ModelFeed.url { return (503, Data()) }
            return request.url == cursor ? (200, Data("<rss><channel><item><title>Cut".utf8)) : (200, post(request))
        }
        let news = NewsStore(defaults: makeDefaults(), directory: try makeFolder(), now: utc(2026, 9, 25), fetch: { await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources, isAllowed: $0.isAllowed) }, notify: { _, _, _ in })
        news.followedSources = ["cursor", "devin", "zai"]
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 12))
        XCTAssertEqual(news.modelProblem, "Couldn't read OpenRouter's model list.")
        XCTAssertEqual(news.announcementProblem, "Couldn't read Cursor.")
        XCTAssertEqual(Set(news.announcements.map(\.source)), ["Devin", "Z.ai"], "The others still read")

        StubURLProtocol.handler = { _ in (500, Data()) }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 13))
        XCTAssertEqual(news.announcementProblem, "Couldn't read the feeds.")
        XCTAssertEqual(Set(news.announcements.map(\.source)), ["Devin", "Z.ai"], "What was read stays")

        StubURLProtocol.handler = { request in
            if request.url == ModelFeed.url { return (200, Self.noModels) }
            return request.url == cursor || request.url == devin ? (404, Data()) : (200, post(request))
        }
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false, now: utc(2026, 9, 25, 14))
        XCTAssertEqual(news.announcementProblem, "Couldn't read Cursor and Devin.")
        XCTAssertNil(news.modelProblem, "A good answer clears it")
    }

    @MainActor
    func testFeedsAddedSinceTheListWasSavedStartOn() {
        let defaults = makeDefaults()
        // Saved before MiniMax Code was in the catalog, with Cursor turned off.
        let earlier = FeedSource.catalog.map(\.id).filter { $0 != "minimax-code" }
        defaults.set(earlier.filter { $0 != "cursor" }, forKey: NewsStore.Keys.sources)
        defaults.set(earlier, forKey: NewsStore.Keys.knownSources)
        let news = NewsStore(defaults: defaults, directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertTrue(news.followedSources.contains("minimax-code"), "A feed added since starts on")
        XCTAssertFalse(news.followedSources.contains("cursor"), "One turned off stays off")

        news.followedSources.remove("minimax-code")
        XCTAssertFalse(NewsStore(defaults: defaults, directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in }).followedSources.contains("minimax-code"), "Turned off once offered, it stays off")
    }

    @MainActor
    func testLabsAddedToTheDefaultsSinceTheListWasSavedStartOn() {
        let defaults = makeDefaults()
        // Saved when the defaults didn't have DeepSeek yet, with OpenAI turned off.
        let earlier = ModelFeed.defaultVendors.subtracting(["deepseek"])
        defaults.set(earlier.subtracting(["openai"]).sorted(), forKey: NewsStore.Keys.vendors)
        defaults.set(earlier.sorted(), forKey: NewsStore.Keys.knownVendors)
        let news = NewsStore(defaults: defaults, directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        XCTAssertTrue(news.followedVendors.contains("deepseek"), "A lab added to the defaults since starts on")
        XCTAssertFalse(news.followedVendors.contains("openai"), "One turned off stays off")

        let saved = makeDefaults()
        saved.set(["anthropic"], forKey: NewsStore.Keys.vendors)
        XCTAssertEqual(NewsStore(defaults: saved, directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in }).followedVendors, Set(["anthropic"]).union(ModelFeed.defaultVendors.subtracting(NewsStore.firstDefaultVendors)), "A list saved by 2.0 had 2.0's defaults to choose from")
    }

    @MainActor
    func testAListSavedBeforeTheCatalogWasRememberedKeepsItsChoices() {
        let defaults = makeDefaults()
        defaults.set(["claude-code", "cursor"], forKey: NewsStore.Keys.sources)
        let news = NewsStore(defaults: defaults, directory: nil, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        let addedSince = Set(FeedSource.catalog.map(\.id)).subtracting(NewsStore.firstCatalog)
        XCTAssertEqual(news.followedSources, Set(["claude-code", "cursor"]).union(addedSince), "2.0 had offered every feed it knew")
    }
    func testFeedsRetryIndependentlyAndNewlyFollowedSourcesFetchImmediately() async {
        defer { unstubNetwork() }
        let good = FeedSource(id: "good", name: "Good", url: URL(string: "https://example.com/good.xml")!)
        let failed = FeedSource(id: "failed", name: "Failed", url: URL(string: "https://example.com/failed.xml")!)
        let added = FeedSource(id: "added", name: "Added", url: URL(string: "https://example.com/added.xml")!)
        stubNetwork { request in
            if request.url == ModelFeed.url { return (200, Self.noModels) }
            if request.url?.lastPathComponent == "failed.xml" { return (503, Data()) }
            return (200, Self.rss("Update", "Thu, 24 Sep 2026 12:00:00 GMT"))
        }
        let now = utc(2026, 9, 25, 12)
        let first = await NewsFetcher.refresh(NewsCache(), sources: [good, failed], following: [], now: now).cache
        XCTAssertEqual(first.sourceChecks?[good.id]?.succeededAt, now)
        XCTAssertEqual(first.sourceChecks?[failed.id]?.failedAt, now)
        let before = StubURLProtocol.requests.count
        let second = await NewsFetcher.refresh(first, sources: [good, failed, added], following: [], now: now.addingTimeInterval(240)).cache
        XCTAssertEqual(StubURLProtocol.requests.count, before + 1)
        XCTAssertEqual(StubURLProtocol.requests.last?.url, added.url, "A fresh global timestamp cannot delay an uncached source")
        _ = await NewsFetcher.refresh(second, sources: [good, failed, added], following: [], now: now.addingTimeInterval(300))
        XCTAssertEqual(StubURLProtocol.requests.count, before + 2)
        XCTAssertEqual(StubURLProtocol.requests.last?.url, failed.url, "Only the failed source retries, after its first 5-minute wait")
    }

    func testParsingFailureDoesNotAdvanceSuccessAndRetriesAfterAnHour() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (200, Data("not a feed".utf8)) }
        let now = utc(2026, 9, 25, 12)
        var cache = NewsCache()
        cache.modelsFetchedAt = now.addingTimeInterval(-60)
        cache.announcementsFetchedAt = now.addingTimeInterval(-60)
        cache.items[claudeCode.id] = []
        cache = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], maxAge: 0, now: now).cache
        XCTAssertEqual(cache.modelsFetchedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(cache.modelsFailedAt, now)
        XCTAssertEqual(cache.sourceChecks?[claudeCode.id]?.succeededAt, now.addingTimeInterval(-60))
        XCTAssertEqual(cache.sourceChecks?[claudeCode.id]?.failedAt, now)
        let count = StubURLProtocol.requests.count
        _ = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(3600))
        XCTAssertEqual(StubURLProtocol.requests.count, count + 2, "A recently successful check does not delay a failed manual check's retry")
    }

    func testTransportFailureIsVisibleInSourceHealth() async {
        defer { unstubNetwork() }
        StubURLProtocol.handler = { _ in (200, Self.noModels) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineFeedProtocol.self, StubETagProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        let source = FeedSource(id: "offline", name: "Offline", url: URL(string: "https://offline.example.com/feed")!)
        let now = utc(2026, 9, 25, 12)
        let cache = await NewsFetcher.refresh(NewsCache(), sources: [source], following: [], now: now).cache
        XCTAssertEqual(cache.sourceChecks?[source.id]?.failedAt, now)
        XCTAssertTrue(cache.unreadable?.contains(source.id) == true)
    }

    func testAnExplicitUncachedFollowRetriesOnlyThatSourceBeforeItsFailureCooldown() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (200, Self.rss("Recovered", "Thu, 24 Sep 2026 12:00:00 GMT")) }
        let now = utc(2026, 9, 25, 12)
        let other = FeedSource(id: "other", name: "Other", url: URL(string: "https://example.com/other.xml")!)
        var cache = NewsCache()
        cache.modelsFetchedAt = now
        cache.sourceChecks = [claudeCode.id: .init(failedAt: now), other.id: .init(failedAt: now)]
        let result = await NewsFetcher.refresh(cache, sources: [claudeCode, other], following: [], now: now.addingTimeInterval(60), forcedSources: [claudeCode.id]).cache
        XCTAssertEqual(StubURLProtocol.requests.map(\.url), [claudeCode.url])
        XCTAssertEqual(result.sourceChecks?[claudeCode.id]?.succeededAt, now.addingTimeInterval(60))
        XCTAssertNil(result.sourceChecks?[claudeCode.id]?.failedAt)
        XCTAssertEqual(result.sourceChecks?[other.id]?.failedAt, now)
    }

    func testOldNewsCacheMetadataIsOptional() throws {
        var cache = NewsCache()
        cache.sourceChecks = nil
        let decoded = try RelayEnvelope.decoder.decode(NewsCache.self, from: RelayEnvelope.encoder.encode(cache))
        XCTAssertNil(decoded.sourceChecks)
        XCTAssertEqual(decoded.items, [:])
        // Written before failures were counted.
        let legacy = try RelayEnvelope.decoder.decode(NewsCache.self, from: Data(#"{"models":[],"modelsFailedAt":1790000000,"modelState":{"seenIDs":[]},"items":{},"validators":{},"sourceChecks":{"cursor":{"failedAt":1790000000}}}"#.utf8))
        XCTAssertNil(legacy.modelsFailures)
        XCTAssertNil(legacy.sourceChecks?["cursor"]?.failures)
        XCTAssertEqual(legacy.sourceChecks?["cursor"]?.failedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testLegacyFeedDatesDoNotAdvanceWhenANewSourceSucceeds() async {
        defer { unstubNetwork() }
        stubNetwork { _ in (200, Self.rss("Update", "Thu, 24 Sep 2026 12:00:00 GMT")) }
        let now = utc(2026, 9, 25, 12)
        let added = FeedSource(id: "added", name: "Added", url: URL(string: "https://example.com/added.xml")!)
        var cache = NewsCache()
        cache.modelsFetchedAt = now
        cache.announcementsFetchedAt = now
        cache.items[claudeCode.id] = []
        let result = await NewsFetcher.refresh(cache, sources: [claudeCode, added], following: [], now: now.addingTimeInterval(600)).cache
        XCTAssertEqual(result.sourceChecks?[claudeCode.id]?.succeededAt, now)
        XCTAssertEqual(result.sourceChecks?[added.id]?.succeededAt, now.addingTimeInterval(600))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)

        // Older partial failures had no shared failure date when another source succeeded.
        cache.unreadable = [claudeCode.id]
        XCTAssertEqual(cache.check(for: claudeCode).failedAt, now)
        let retried = await NewsFetcher.refresh(cache, sources: [claudeCode], following: [], now: now.addingTimeInterval(3600)).cache
        XCTAssertEqual(retried.sourceChecks?[claudeCode.id]?.succeededAt, now.addingTimeInterval(3600))
        XCTAssertNil(retried.sourceChecks?[claudeCode.id]?.failedAt)
    }

    @MainActor
    func testVisitBaselineSurvivesFollowNavigationAndAdvancesAtNextEntry() throws {
        let defaults = makeDefaults()
        defaults.set(utc(2026, 9, 24).timeIntervalSince1970, forKey: NewsStore.Keys.seenAt)
        let news = NewsStore(defaults: defaults, directory: try makeNewsFolder(), now: utc(2026, 9, 25, 12), fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        news.beginVisit(now: utc(2026, 9, 25, 12))
        let baseline = news.visitBaseline
        news.beginVisit(now: utc(2026, 9, 25, 13))
        XCTAssertEqual(news.visitBaseline, baseline)
        XCTAssertTrue(news.isNew(utc(2026, 9, 25, 8)))
        XCTAssertEqual(news.unseenCount(now: utc(2026, 9, 25, 13)), 0)
        news.endVisit()
        news.beginVisit(now: utc(2026, 9, 26))
        XCTAssertFalse(news.isNew(utc(2026, 9, 25, 8)))
    }

    @MainActor
    func testManualRefreshesDuringARefreshCoalesceIntoOneFollowUp() async {
        let probe = NewsRefreshProbe()
        let news = NewsStore(defaults: makeDefaults(), directory: nil, fetch: { await probe.fetch($0) }, notify: { _, _, _ in })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false)
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false)
        await probe.release()
        await first.value
        let ages = await probe.ages
        XCTAssertEqual(ages.count, 2)
        XCTAssertNil(ages[0])
        XCTAssertEqual(ages[1], 0)
        XCTAssertFalse(news.isRefreshing)
    }

    @MainActor
    func testQueuedUncachedFollowsSurviveAManualRefreshInOneFollowUp() async {
        let probe = NewsRefreshProbe()
        let news = NewsStore(defaults: makeDefaults(), directory: nil, fetch: { await probe.fetch($0) }, notify: { _, _, _ in })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(preferences: AlertPreferences(), notifies: false, forcedSources: ["claude-code"])
        await news.refresh(preferences: AlertPreferences(), notifies: false, forcedSources: ["cursor"])
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false)
        await probe.release()
        await first.value
        let forced = await probe.forcedSources
        let ages = await probe.ages
        XCTAssertEqual(forced, [[], ["claude-code", "cursor"]])
        XCTAssertEqual(ages.count, 2)
        XCTAssertEqual(ages.last!, 0)
        XCTAssertFalse(news.isRefreshing)
    }

    @MainActor
    func testQueuedFollowKeepsManualNotificationIntentAndLatestPreferences() async {
        let model = ModelRelease(id: "lab/model", name: "Model", vendor: "lab", created: .now, contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        let probe = NewsRefreshProbe(newModels: [model])
        var notifications: [AlertPreferences] = []
        let news = NewsStore(defaults: makeDefaults(), directory: nil, fetch: { await probe.fetch($0) },
                             notify: { _, preferences, _ in notifications.append(preferences) })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: true)
        var latest = AlertPreferences()
        latest.resets = false
        await news.refresh(preferences: latest, notifies: false, forcedSources: ["claude-code"])
        await probe.release()
        await first.value
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.resets, false, "Follow-up uses the latest preferences")
        let ages = await probe.ages
        let forced = await probe.forcedSources
        XCTAssertEqual(ages.count, 2)
        XCTAssertEqual(ages[1], 0)
        XCTAssertEqual(forced[1], ["claude-code"])
    }

    @MainActor
    func testCancelledRefreshOwnerStillRunsQueuedManualAndFollowRequest() async {
        let probe = NewsRefreshProbe()
        let news = NewsStore(defaults: makeDefaults(), directory: nil, fetch: { await probe.fetch($0) }, notify: { _, _, _ in })
        let first = Task { await news.refresh(preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false)
        await news.refresh(preferences: AlertPreferences(), notifies: false, forcedSources: ["claude-code"])
        first.cancel() // A SwiftUI .task can be cancelled when its page disappears.
        await probe.release()
        await first.value
        let ages = await probe.ages
        let forced = await probe.forcedSources
        XCTAssertEqual(ages.count, 2, "The queued pass has its own lifetime")
        XCTAssertEqual(ages.last!, 0)
        XCTAssertEqual(forced.last!, ["claude-code"])
        XCTAssertFalse(news.isRefreshing)
    }

    func testNewsSearchAndEmptyStatesExplainTheCurrentSection() {
        XCTAssertTrue(NewsSearch.matches("openai", title: "A new model", source: "OpenAI"))
        XCTAssertTrue(NewsSearch.matches("NEW", title: "A new model", source: "Lab"))
        XCTAssertFalse(NewsSearch.matches("other", title: "Model", source: "Lab"))
        XCTAssertEqual(NewsEmptyPresentation.make(section: .announcements, searching: false, hasLabs: true, hasSources: false, problem: nil).title, "No sources followed")
        XCTAssertEqual(NewsEmptyPresentation.make(section: .retiring, searching: false, hasLabs: true, hasSources: true, problem: nil).title, "No upcoming retirements")
        XCTAssertEqual(NewsEmptyPresentation.make(section: .retiring, searching: false, hasLabs: true, hasSources: true, problem: "Couldn't load").title, "Couldn't load this section")
    }

}

/// Like StubURLProtocol, with an ETag on every 200.
final class StubETagProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        let (status, data) = StubURLProtocol.handler?(request) ?? (404, Data())
        let headers = status == 200 ? ["ETag": "\"v1\""] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Like StubURLProtocol, but a feed's body is cut off by a timeout a moment after what the handler
/// gives has arrived. The content type is set, so the session doesn't hold a short body back to
/// sniff it.
/// Every request answers 429 with `retryAfter` as its Retry-After.
private final class RetryAfterProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var retryAfter = "7200"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: ["Retry-After": Self.retryAfter])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CutOffFeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.requests.append(request)
        let (status, data) = StubURLProtocol.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/rss+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if request.url == ModelFeed.url {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
        }
    }

    override func stopLoading() {}
}

private final class OfflineFeedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "offline.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private actor NewsRefreshProbe {
    var newModels: [ModelRelease]
    init(newModels: [ModelRelease] = []) { self.newModels = newModels }
    var ages: [TimeInterval?] = []
    var forcedSources: [Set<String>] = []
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func fetch(_ request: NewsFetcher.Request) async -> NewsFetcher.Result {
        ages.append(request.maxAge)
        forcedSources.append(request.forcedSources)
        if ages.count == 1 {
            await withCheckedContinuation { continuation in
                blocked = continuation
                started?.resume()
                started = nil
            }
        }
        return .init(cache: request.cache, newModels: ages.count > 1 ? newModels : [])
    }
    func waitUntilStarted() async {
        if !ages.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
