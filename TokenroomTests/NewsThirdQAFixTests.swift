import XCTest
@testable import Tokenroom

/// Regression sources for QA3; not compiled or executed in the no-tests fix pass.
final class NewsThirdQAFixTests: XCTestCase {
    private static let body = Data("{\"items\":[{\"ownerHandle\":\"owner\",\"slug\":\"tool\",\"displayName\":\"Tool\"}]}".utf8)

    func testAtomXHTMLKeepsDirectFieldTextAndSeparateDates() throws {
        let source = FeedSource.catalog[0]
        let xml = Data("""
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>release</id>
        <author><title>Wrong author</title></author><card><title>Wrong card</title></card>
        <title type="xhtml">Before<div xmlns="http://www.w3.org/1999/xhtml">Release<span>inside</span></div>After</title>
        <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>One</p><p>Two<br/>Three</p></div>After</summary>
        <link rel="self" href="https://example.com/self"/><link rel="alternate" href="https://example.com/release"/>
        <published>2026-10-01T12:00:00Z</published><updated>2026-10-02T12:00:00Z</updated>
        </entry></feed>
        """.utf8)
        let page = FeedParser.read(xml, source: source)
        XCTAssertTrue(page.isComplete)
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(item.title, "Before Release inside After")
        XCTAssertEqual(item.excerpt, "One Two Three After")
        XCTAssertEqual(item.link?.absoluteString, "https://example.com/release")
        XCTAssertEqual(item.publisherPublishedAt, FeedParser.date("2026-10-01T12:00:00Z"))
        XCTAssertEqual(item.updatedAt, FeedParser.date("2026-10-02T12:00:00Z"))
    }

    func testPrefixedAtomAndRSSKeepExistingScalarAndHTMLContracts() throws {
        let source = FeedSource.catalog[0]
        let atom = Data("""
        <a:feed xmlns:a="http://www.w3.org/2005/Atom"><a:entry><a:id>right<child>wrong</child>tail</a:id>
        <a:author><a:title>Wrong</a:title></a:author><a:title type="xhtml"><div>Right</div></a:title>
        <a:content type="xhtml"><p>First</p><p>Second</p></a:content></a:entry>
        <a:entry><a:author><a:title>Missing direct title</a:title></a:author></a:entry></a:feed>
        """.utf8)
        let page = FeedParser.read(atom, source: source)
        XCTAssertTrue(page.isComplete)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.id, "righttail")
        XCTAssertEqual(page.items.first?.title, "Right")
        XCTAssertEqual(page.items.first?.excerpt, "First Second")
        let rss = Data("""
        <rss xmlns:dc="urn:dc" xmlns:content="urn:content"><channel><item><title><![CDATA[Release <b>One</b>]]></title>
        <guid>rss-id</guid><dc:date>2026-10-01T12:00:00Z</dc:date>
        <content:encoded><![CDATA[<p>First</p><p>Second</p>]]></content:encoded></item></channel></rss>
        """.utf8)
        let item = try XCTUnwrap(FeedParser.read(rss, source: source).items.first)
        XCTAssertEqual(item.title, "Release One")
        XCTAssertEqual(item.excerpt, "First Second")
        XCTAssertEqual(item.publisherPublishedAt, FeedParser.date("2026-10-01T12:00:00Z"))
    }

    func testNestedExcerptHasOneCumulativeBound() throws {
        let paragraphs = (0..<100).map { _ in "<p>" + String(repeating: "x", count: 100) + "</p>" }.joined()
        let xml = Data("<feed><entry><title>Title</title><summary>\(paragraphs)</summary></entry></feed>".utf8)
        let item = try XCTUnwrap(FeedParser.read(xml, source: FeedSource.catalog[0]).items.first)
        XCTAssertEqual(item.excerpt?.count, 2000)
    }

    func testXHTMLFeedRefreshKeepsUsableContentAndBrokenRetryRetainsIt() async {
        let source = FeedSource(id: "test-xhtml", name: "Fixture", url: URL(string: "https://example.com/feed")!)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        defer { TokenroomHTTP.overrideSession(nil); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            (200, Data("<feed><entry><id>a</id><title type='xhtml'><div>Release</div></title><summary type='xhtml'><p>Supplied</p><p>excerpt</p></summary></entry></feed>".utf8))
        }
        var cache = NewsCache()
        cache.modelsFetchedAt = now
        cache.items[source.id] = [FeedItem(id: "a", title: "Previous", source: source.name)]
        let refreshed = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now, forcedSources: [source.id]).cache
        XCTAssertEqual(refreshed.items[source.id]?.map(\.title), ["Release"])
        XCTAssertEqual(refreshed.items[source.id]?.first?.excerpt, "Supplied excerpt")
        XCTAssertEqual(refreshed.sourceChecks?[source.id]?.succeededAt, now)
        StubURLProtocol.handler = { _ in (200, Data("<feed><entry><title type='xhtml'><div>Broken".utf8)) }
        let failed = await NewsFetcher.refresh(refreshed, sources: [source], following: [], now: now.addingTimeInterval(60), forcedSources: [source.id]).cache
        XCTAssertEqual(failed.items[source.id], refreshed.items[source.id])
        XCTAssertEqual(failed.sourceChecks?[source.id]?.succeededAt, now)
        XCTAssertEqual(failed.sourceChecks?[source.id]?.failedAt, now.addingTimeInterval(60))
    }

    @MainActor func testNewsTransportEntryVetoSkipsGETAndPreservesFailureState() async {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        defer { TokenroomHTTP.overrideSession(nil); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in XCTFail("Vetoed transport must not issue a GET"); return (503, Data()) }
        let source = FeedSource.catalog[0], now = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = NewsCache()
        cache.modelsFetchedAt = now.addingTimeInterval(-60)
        cache.modelsFailedAt = now.addingTimeInterval(-30)
        cache.items[source.id] = [FeedItem(id: "kept", title: "Kept", source: source.name)]
        cache.sourceChecks = [source.id: .init(succeededAt: now.addingTimeInterval(-60), failedAt: now.addingTimeInterval(-30))]
        let answer = await NewsFetcher.permittedGet(source.url, validator: nil, isAllowed: { false })
        XCTAssertNil(answer)
        let result = await NewsFetcher.refresh(cache, sources: [source], following: [], now: now, forcedSources: [ModelFeed.id, source.id], isAllowed: { false })
        XCTAssertEqual(result.cache, cache)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertTrue(result.newModels.isEmpty)
    }

    func testAllRejectedBoundedSkillPagesFailButEmptyAndMixedPagesSucceed() throws {
        XCTAssertThrowsError(try SkillFeed.parse(Data("{\"items\":[{}]}".utf8)))
        let tooLate = Array(repeating: [:] as [String: String], count: 30) + [["ownerHandle": "owner", "slug": "tool", "displayName": "Tool"]]
        XCTAssertThrowsError(try SkillFeed.parse(JSONSerialization.data(withJSONObject: ["items": tooLate])))
        XCTAssertTrue(try SkillFeed.parse(Data("{\"items\":[]}".utf8)).listings.isEmpty)
        let mixed = try SkillFeed.parse(Data("{\"items\":[{}, {\"ownerHandle\":\"owner\",\"slug\":\"tool\",\"displayName\":\"Tool\"}],\"nextCursor\":\"more\"}".utf8))
        XCTAssertEqual(mixed.listings.map(\.sourceRank), [2])
        XCTAssertEqual(mixed.cursor, "more")
    }

    @MainActor func testMalformedSkillsRetainShelfAndDateThenExplicitEmptyClearsThem() async {
        let calls = LockedBox(0), now = LockedBox(Date(timeIntervalSince1970: 100))
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            return .body(calls.value == 1 ? Self.body : Data((calls.value == 2 ? "{\"items\":[{}]}" : "{\"items\":[]}").utf8))
        }, clock: { now.value })
        await store.refresh(sort: .trending)
        let shelf = store.listings, checked = store.checkedAt
        now.value = Date(timeIntervalSince1970: 200)
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(store.listings, shelf)
        XCTAssertEqual(store.checkedAt, checked)
        XCTAssertNotNil(store.problem)
        await store.refresh(sort: .trending, force: true)
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertEqual(store.checkedAt, now.value)
        XCTAssertNil(store.problem)
    }

    @MainActor func testDisabledSkillsOwnerBlocksEntryAndQueuedDispatchThenReenables() async {
        let calls = LockedBox(0), entries = LockedBox(0), enabled = LockedBox(true), gate = ThirdQAGate()
        let store = SkillsStore(fetch: { _ in calls.value += 1; return .body(Self.body) }, beforeDispatch: {
            entries.value += 1
            if entries.value == 1 { await gate.pause() }
        })
        store.allowsRefresh = { enabled.value }
        enabled.value = false
        await store.refresh(sort: .downloads, force: true)
        XCTAssertEqual(entries.value, 0)
        XCTAssertEqual(store.sort, .trending, "A blocked entry does not mutate presentation")
        enabled.value = true
        let reader = Task { await store.refresh(sort: .trending) }
        await gate.waitForPauses(1)
        enabled.value = false
        await gate.release(); await reader.value
        XCTAssertEqual(calls.value, 0)
        XCTAssertNil(store.problem)
        XCTAssertNil(store.checkedAt)
        XCTAssertFalse(store.isRefreshing)
        enabled.value = true
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(store.listings.first?.name, "Tool")
    }

    @MainActor func testCancelledQueuedSkillsReaderDoesNotDispatchOrInventFailure() async {
        let gate = ThirdQAGate(), assigned = ThirdQACounter(), calls = LockedBox(0), physical = LockedBox<Task<SkillsStore.Answer, Never>?>(nil)
        let store = SkillsStore(fetch: { _ in calls.value += 1; return .body(Self.body) }, beforeDispatch: { await gate.pause() }, limitAnswer: { _, task in
            physical.value = task
            await assigned.arrive()
            return await task.value
        })
        let reader = Task { await store.refresh(sort: .trending) }
        await gate.waitForPauses(1)
        await assigned.waitFor(1)
        reader.cancel(); await reader.value
        await gate.release()
        _ = await physical.value?.value
        XCTAssertEqual(calls.value, 0)
        XCTAssertNil(store.problem)
        XCTAssertNil(store.checkedAt)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor func testAlreadyCancelledSkillsCallerDoesNotCreateARequest() async {
        let entry = ThirdQAGate(), calls = LockedBox(0)
        let store = SkillsStore(fetch: { _ in calls.value += 1; return .body(Self.body) })
        let reader = Task {
            await entry.pause()
            await store.refresh(sort: .downloads, force: true)
        }
        await entry.waitForPauses(1)
        reader.cancel()
        await entry.release(); await reader.value
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(store.sort, .trending)
        XCTAssertNil(store.problem)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor func testJoinedReadersShareOriginalDeadlineAndRejectLateBody() async {
        await checkSharedDeadline(lateAnswer: .body(Self.body), expectedRetry: nil)
    }

    @MainActor func testExpiredPhysicalSlotRetainsAuthoritativeLate429() async {
        await checkSharedDeadline(lateAnswer: .status(429, retryAfter: "600"), expectedRetry: Date(timeIntervalSince1970: 700))
    }

    @MainActor private func checkSharedDeadline(lateAnswer: SkillsStore.Answer, expectedRetry: Date?) async {
        let fetchGate = ThirdQAGate(), deadlineGate = ThirdQAGate(), readers = ThirdQACounter()
        let calls = LockedBox(0), budgets = LockedBox<[TimeInterval]>([]), monotonic = LockedBox(0.0)
        let physical = LockedBox<Task<SkillsStore.Answer, Never>?>(nil), wasCancelled = LockedBox(false)
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            await fetchGate.pause()
            wasCancelled.value = Task.isCancelled
            return lateAnswer
        }, clock: { Date(timeIntervalSince1970: 100) }, waitForAnswer: { task in
            await readers.arrive()
            return await task.value
        }, monotonicClock: { monotonic.value }, limitAnswer: { seconds, task in
            budgets.value.append(seconds); physical.value = task
            await deadlineGate.pause()
            return nil
        })
        let first = Task { await store.refresh(sort: .trending) }
        await fetchGate.waitForPauses(1); await deadlineGate.waitForPauses(1)
        monotonic.value = 4
        let joined = Task { await store.refresh(sort: .trending, force: true) }
        await readers.waitFor(2)
        XCTAssertEqual(budgets.value, [8], "Joining does not create another budget")
        monotonic.value = 8
        await deadlineGate.release(); await first.value; await joined.value
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.isRefreshing)
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 1, "An expired physical worker still owns its slot")
        monotonic.value = 10
        await fetchGate.release()
        _ = await physical.value?.value
        XCTAssertTrue(wasCancelled.value)
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertNil(store.checkedAt)
        XCTAssertEqual(store.retryAt, expectedRetry)
        if expectedRetry != nil {
            await store.refresh(sort: .trending, force: true)
            XCTAssertEqual(calls.value, 1)
        }
    }

    @MainActor func testAbsoluteDeadlineRejectsBodyEvenBeforeTimerCallbackResumes() async {
        let gate = ThirdQAGate(), monotonic = LockedBox(0.0)
        let store = SkillsStore(fetch: { _ in await gate.pause(); return .body(Self.body) }, monotonicClock: { monotonic.value }, limitAnswer: { _, task in await task.value })
        let reader = Task { await store.refresh(sort: .trending) }
        await gate.waitForPauses(1)
        monotonic.value = 9
        await gate.release(); await reader.value
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertNil(store.checkedAt)
        XCTAssertNotNil(store.problem)
    }

    @MainActor func testInvalidSkillsRetryAfterFallsBackAndValidDirectivesRemainUsable() async {
        let now = Date(timeIntervalSince1970: 100)
        for header in [nil, "", "garbage", "-1", "NaN", "Infinity", "inf", "1e309", "1e300"] as [String?] {
            let store = SkillsStore(fetch: { _ in .status(429, retryAfter: header) }, clock: { now })
            await store.refresh(sort: .trending)
            XCTAssertEqual(store.retryAt, now.addingTimeInterval(900), "Invalid directive: \(header ?? "nil")")
        }
        for (header, expected) in [("0", now), ("60", now.addingTimeInterval(60)), ("600", now.addingTimeInterval(600)), ("Thu, 01 Jan 1970 00:20:00 GMT", Date(timeIntervalSince1970: 1200)), ("Thu, 01 Jan 1970 00:00:00 GMT", now)] {
            let store = SkillsStore(fetch: { _ in .status(429, retryAfter: header) }, clock: { now })
            await store.refresh(sort: .trending)
            XCTAssertEqual(store.retryAt, expected)
        }
    }
}

private actor ThirdQAGate {
    private var count = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            blocked = continuation; count += 1
            let ready = observers.filter { $0.0 <= count }
            observers.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForPauses(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { observers.append((target, $0)) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor ThirdQACounter {
    private var count = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func arrive() {
        count += 1
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
    func waitFor(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { observers.append((target, $0)) }
    }
}
