import XCTest
@testable import Tokenroom

final class SkillFeedTests: XCTestCase {
    /// Called from the main actor, as `SkillsStore` does, the body is still read off it.
    @MainActor func testADownloadKeepsEveryByteQuicklyAndStopsPastTheLimit() async throws {
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (200, body) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://clawhub.ai/api/v1/skills")!)

        let started = ContinuousClock.now
        let answer = await SkillsStore.download(request, session: session)
        let elapsed = ContinuousClock.now - started
        guard case .body(let data) = answer else { return XCTFail("Expected the body, got \(answer)") }
        XCTAssertEqual(data, body, "Every byte, across buffer boundaries")
        XCTAssertLessThan(elapsed, .seconds(1), "A main-actor hop per byte took seconds for this size")

        StubURLProtocol.handler = { _ in (200, Data(count: SkillFeed.sizeLimit + 1)) }
        guard case .unreachable = await SkillsStore.download(request, session: session) else { return XCTFail("Past the size limit") }
    }

    @MainActor func testCancelledPhysicalRequestStillRecordsLateRetryAfter() async {
        let response = LockedBox<CheckedContinuation<SkillsStore.Answer, Never>?>(nil)
        let calls = LockedBox(0)
        let now = Date(timeIntervalSince1970: 100)
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            if calls.value > 1 { return .body(Self.body) }
            return await withCheckedContinuation { response.value = $0 }
        }, clock: { now })
        let owner = Task { await store.refresh(sort: .trending) }
        for _ in 0..<1000 { if response.value != nil { break }; await Task.yield() }
        guard let physical = response.value else { XCTFail("Fetch never started"); owner.cancel(); return }
        owner.cancel(); await owner.value
        // Another waiter must share the physical request while it is still ending.
        let next = Task { await store.refresh(sort: .trending, force: true) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(calls.value, 1)
        physical.resume(returning: .status(429, retryAfter: "600"))
        await next.value
        for _ in 0..<100 { await Task.yield() }
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(store.retryAt, Date(timeIntervalSince1970: 700))
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(store.listings.isEmpty)
    }
    static let body = Data("""
    {"items":[
      {"ownerHandle":"alice","slug":"search","displayName":"Search","summary":"Search public pages","updatedAt":1791600000000,"latestVersion":{"version":"1.0"},"stats":{"downloads":30,"stars":2}},
      {"ownerHandle":"bob","slug":"search","displayName":"Other search","stats":{"downloads":-1,"stars":1e100}},
      {"slug":"missing-owner","displayName":"Missing"},
      {"ownerHandle":"../bad","slug":"x","displayName":"Invalid"}
    ],"nextCursor":"more"}
    """.utf8)

    func testOwnerQualifiedIdentityAndShortPageRetainOrder() throws {
        let page = try SkillFeed.parse(Self.body)
        XCTAssertEqual(page.listings.map(\.id), ["alice/search", "bob/search"])
        XCTAssertEqual(page.cursor, "more")
        XCTAssertEqual(page.listings[0].canonicalURL.absoluteString, "https://clawhub.ai/alice/skills/search")
        XCTAssertEqual(page.listings[0].downloads, 30)
        XCTAssertEqual(page.listings[0].version, "1.0")
    }
    func testMissingAndInvalidFieldsStayUnknown() throws {
        let page = try SkillFeed.parse(Self.body)
        XCTAssertNil(page.listings[1].downloads)
        XCTAssertNil(page.listings[1].stars)
        XCTAssertNil(page.listings[1].version)
        XCTAssertNil(page.listings[1].updatedAt)
        XCTAssertEqual(page.listings[1].requirements, [])
    }
    func testOversizedOrInvalidSchemaIsRejected() {
        XCTAssertThrowsError(try SkillFeed.parse(Data(repeating: 32, count: 2 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try SkillFeed.parse(Data("{\"data\":[]}".utf8)))
        XCTAssertThrowsError(try SkillFeed.parse(Data("{\"items\":[12]}".utf8)))
    }
    func testDeclaredPlatformsAndInvalidDates() throws {
        let body = Data("{\"items\":[{\"ownerHandle\":\"owner\",\"slug\":\"tool\",\"displayName\":\"Tool\",\"updatedAt\":1e100,\"metadata\":{\"os\":[\"macos\"],\"systems\":[\"aarch64-darwin\"]}}]}".utf8)
        let item = try XCTUnwrap(SkillFeed.parse(body).listings.first)
        XCTAssertNil(item.updatedAt)
        XCTAssertEqual(item.requirements, ["os: macos", "systems: aarch64-darwin"])
    }
    @MainActor func testServerRetryAfterPreventsManualHammering() async {
        let calls = LockedBox(0)
        let now = Date(timeIntervalSince1970: 100)
        let store = SkillsStore(fetch: { request in
            calls.value += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(request.url!.absoluteString.contains("nonSuspiciousOnly=true"))
            return .status(429, retryAfter: "60")
        }, clock: { now })
        await store.refresh(sort: .trending)
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(store.retryAt, Date(timeIntervalSince1970: 160))
        XCTAssertNotNil(store.problem)
    }
    @MainActor func testCoalescingAndStaleSortCannotReplaceSelection() async {
        let calls = LockedBox<[String]>([])
        let store = SkillsStore(fetch: { request in
            let sort = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "sort" }!.value!
            calls.value.append(sort)
            if sort == "trending" { try? await Task.sleep(for: .milliseconds(80)) }
            return .body(Self.body)
        })
        let first = Task { await store.refresh(sort: .trending) }
        await Task.yield()
        let same = Task { await store.refresh(sort: .trending) }
        try? await Task.sleep(for: .milliseconds(10))
        await store.refresh(sort: .newest)
        await first.value; await same.value
        XCTAssertEqual(calls.value.filter { $0 == "trending" }.count, 1)
        XCTAssertEqual(store.sort, .newest)
        XCTAssertEqual(store.listings.count, 2)
        XCTAssertFalse(store.isRefreshing)
    }
    @MainActor func testCancellationDoesNotPublishResult() async {
        let store = SkillsStore(fetch: { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return .body(Self.body)
        })
        let task = Task { await store.refresh(sort: .trending) }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel(); await task.value
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertNil(store.checkedAt)
    }
}
