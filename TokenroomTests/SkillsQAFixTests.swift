import XCTest
@testable import Tokenroom

final class SkillsQAFixTests: XCTestCase {
    private static func body(_ name: String) -> Data {
        Data("{\"items\":[{\"ownerHandle\":\"owner\",\"slug\":\"tool\",\"displayName\":\"\(name)\"}]}".utf8)
    }
    func testFractionalBooleanAndInvalidNumericMetadataStayUnknown() throws {
        for stats in ["{\"downloads\":true,\"stars\":false}", "{\"downloads\":1.5,\"stars\":-1}", "{\"downloads\":1e100,\"stars\":\"12\"}"] {
            let data = Data("{\"items\":[{\"ownerHandle\":\"owner\",\"slug\":\"tool\",\"displayName\":\"Tool\",\"updatedAt\":true,\"stats\":\(stats)}]}".utf8)
            let item = try XCTUnwrap(SkillFeed.parse(data).listings.first)
            XCTAssertNil(item.downloads); XCTAssertNil(item.stars); XCTAssertNil(item.updatedAt)
        }
    }
    @MainActor func testOlderWaiterCannotReplaceNewerSameSortResult() async {
        let calls = LockedBox(0), clock = LockedBox(Date(timeIntervalSince1970: 100))
        let gate = QASkillsGate()
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            return .body(Self.body(calls.value == 1 ? "Older" : "Newer"))
        }, clock: { clock.value }, waitForAnswer: { task in
            let answer = await task.value
            if await gate.arrived() == 1 { await gate.pause() }
            return answer
        })
        let older = Task { await store.refresh(sort: .trending, force: true) }
        await gate.waitUntilPaused()
        clock.value = Date(timeIntervalSince1970: 200)
        await store.refresh(sort: .trending, force: true)
        clock.value = Date(timeIntervalSince1970: 300)
        await gate.release(); await older.value
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(store.listings.first?.name, "Newer")
        XCTAssertEqual(store.checkedAt, Date(timeIntervalSince1970: 200))
    }
    @MainActor func testOlderSuccessfulWaiterCannotClearNewerRetryAfter() async {
        let calls = LockedBox(0)
        let gate = QASkillsGate()
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            return calls.value == 1 ? .body(Self.body("Retained")) : .status(429, retryAfter: "600")
        }, clock: { Date(timeIntervalSince1970: 100) }, waitForAnswer: { task in
            let answer = await task.value
            if await gate.arrived() == 1 { await gate.pause() }
            return answer
        })
        let older = Task { await store.refresh(sort: .trending, force: true) }
        await gate.waitUntilPaused()
        await store.refresh(sort: .trending, force: true)
        await gate.release(); await older.value
        XCTAssertEqual(store.retryAt, Date(timeIntervalSince1970: 700))
        XCTAssertNotNil(store.problem)
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 2)
    }
    @MainActor func testSwitchingBackToFreshCacheKeepsItsLatestFailure() async {
        let calls = LockedBox(0)
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            return calls.value == 2 ? .status(500, retryAfter: nil) : .body(Self.body("Cached"))
        }, clock: { Date(timeIntervalSince1970: 100) })
        await store.refresh(sort: .trending)
        await store.refresh(sort: .trending, force: true)
        let failure = store.problem
        XCTAssertNotNil(failure)
        await store.refresh(sort: .downloads)
        await store.refresh(sort: .trending)
        XCTAssertEqual(store.problem, failure)
        XCTAssertEqual(store.listings.first?.name, "Cached")
        XCTAssertEqual(calls.value, 3)
    }
    @MainActor func testFreshCacheReentrySharesForcedRequestAndKeepsProgress() async {
        let calls = LockedBox(0), gate = QASkillsGate()
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            if calls.value == 2 { await gate.pause() }
            return .body(Self.body("Loaded"))
        }, clock: { Date(timeIntervalSince1970: 100) }, waitForAnswer: { task in
            _ = await gate.arrived()
            return await TimeLimit.run(8, otherwise: SkillsStore.Answer.unreachable) { await task.value }
        })
        await store.refresh(sort: .trending)
        let forced = Task { await store.refresh(sort: .trending, force: true) }
        await gate.waitUntilPaused()
        let reentry = Task { await store.refresh(sort: .trending) }
        await gate.waitForArrivals(3)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(calls.value, 2)
        await gate.release(); await forced.value; await reentry.value
        XCTAssertFalse(store.isRefreshing)
    }
    @MainActor func testCancellingOneWaiterDoesNotCancelAnotherLiveWaiter() async {
        let gate = QASkillsGate(), physicallyCancelled = LockedBox(false)
        let store = SkillsStore(fetch: { _ in
            await gate.pause()
            physicallyCancelled.value = Task.isCancelled
            return .body(Self.body("Shared"))
        }, waitForAnswer: { task in
            _ = await gate.arrived()
            return await TimeLimit.run(8, otherwise: SkillsStore.Answer.unreachable) { await task.value }
        })
        let owner = Task { await store.refresh(sort: .trending) }
        await gate.waitUntilPaused()
        let other = Task { await store.refresh(sort: .trending, force: true) }
        await gate.waitForArrivals(2)
        owner.cancel(); await owner.value
        XCTAssertTrue(store.isRefreshing)
        await gate.release(); await other.value
        XCTAssertFalse(physicallyCancelled.value)
        XCTAssertEqual(store.listings.first?.name, "Shared")
    }
    @MainActor func testCancelledLastWaiterCannotPublishNonCooperativeBody() async {
        let gate = QASkillsGate(), physical = LockedBox<Task<SkillsStore.Answer, Never>?>(nil)
        let store = SkillsStore(fetch: { _ in
            await gate.pause()
            return .body(Self.body("Cancelled"))
        }, limitAnswer: { _, task in
            physical.value = task
            _ = await gate.arrived()
            return await task.value
        })
        let reader = Task { await store.refresh(sort: .trending) }
        await gate.waitUntilPaused()
        await gate.waitForArrivals(1)
        // The fetch deliberately returns a body after its sole reader has cancelled.
        // Acknowledgments replace the old blocking MainActor semaphore schedule.
        reader.cancel(); await reader.value
        await gate.release()
        _ = await physical.value?.value
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertNil(store.checkedAt)
        XCTAssertFalse(store.isRefreshing)
    }
    @MainActor func testTimedOutWaiterKeepsPhysicalSlotAndLateRetryAfter() async {
        let gate = QASkillsGate(), calls = LockedBox(0)
        let store = SkillsStore(fetch: { _ in
            calls.value += 1
            await gate.pause()
            return .status(429, retryAfter: "600")
        }, clock: { Date(timeIntervalSince1970: 100) }, waitForAnswer: { task in
            if await gate.arrived() == 1 {
                await gate.waitUntilPaused() // This case expires an already-issued request.
                return .unreachable
            }
            return await task.value
        })
        await store.refresh(sort: .trending)
        await gate.waitUntilPaused()
        XCTAssertNotNil(store.problem)
        XCTAssertFalse(store.isRefreshing)
        let next = Task { await store.refresh(sort: .trending, force: true) }
        await gate.waitForArrivals(2)
        XCTAssertEqual(calls.value, 1)
        await gate.release(); await next.value
        XCTAssertEqual(store.retryAt, Date(timeIntervalSince1970: 700))
        await store.refresh(sort: .trending, force: true)
        XCTAssertEqual(calls.value, 1)
    }
}

private actor QASkillsGate {
    private var arrivals = 0
    private var arrivalObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var paused = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var gate: CheckedContinuation<Void, Never>?
    func arrived() -> Int {
        arrivals += 1
        let ready = arrivalObservers.filter { $0.0 <= arrivals }
        arrivalObservers.removeAll { $0.0 <= arrivals }
        ready.forEach { $0.1.resume() }
        return arrivals
    }
    func waitForArrivals(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { arrivalObservers.append((count, $0)) }
    }
    func pause() async {
        await withCheckedContinuation { continuation in
            gate = continuation; paused = true
            pauseObservers.forEach { $0.resume() }; pauseObservers = []
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }
    func release() { gate?.resume(); gate = nil }
}
