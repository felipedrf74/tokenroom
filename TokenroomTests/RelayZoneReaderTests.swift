import XCTest
@testable import Tokenroom

final class RelayZoneReaderTests: XCTestCase {
    private typealias Reader = RelayZoneReader<String, Int, Int>
    private enum Failure: Error { case expired, unavailable }
    private actor Pages {
        var pages: [Result<Reader.Page, any Error>]
        var tokens: [Int?] = []
        init(_ pages: [Result<Reader.Page, any Error>]) { self.pages = pages }
        func fetch(_ token: Int?) throws -> Reader.Page {
            tokens.append(token)
            return try pages.removeFirst().get()
        }
    }
    private func reader(_ pages: Pages) -> Reader {
        Reader(fetch: { try await pages.fetch($0) }, recovery: {
            ($0 as? Failure) == .expired ? .retryFromStart : .fail
        })
    }

    func testDeltaReadsRetainUnchangedRecordsAndApplyDeletions() async throws {
        let pages = Pages([
            .success(.init(modifications: ["first": .success(10), "deleted": .success(20)], token: 1)),
            .success(.init(modifications: ["added": .success(30)], deletions: ["deleted"], token: 2)),
        ])
        let reader = reader(pages)
        let first = try await reader.contents()
        let second = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(first, ["first": 10, "deleted": 20])
        XCTAssertEqual(second, ["first": 10, "added": 30])
        XCTAssertNil(tokens[0])
        XCTAssertEqual(tokens[1], 1, "Later refreshes request deltas, not all retained alerts")
    }

    func testRecordFailureDoesNotAdvanceCursorOrReplaceCompleteSnapshot() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["kept": .failure(Failure.unavailable)], token: 2)),
            .success(.init(modifications: ["new": .success(20)], token: 3)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        do { _ = try await reader.contents(); XCTFail("A partial record failure must be visible") }
        catch { XCTAssertTrue(error is Failure) }
        let recovered = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(recovered, ["kept": 10, "new": 20])
        XCTAssertEqual(tokens[2], 1, "Retry begins at the last fully committed snapshot")
    }

    func testPageFailureRollsBackEveryPageInThatRead() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["partial": .success(20)], token: 2, moreComing: true)),
            .failure(Failure.unavailable),
            .success(.init(modifications: [:], token: 3)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        do { _ = try await reader.contents(); XCTFail("The second page failed") } catch {}
        let recovered = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(recovered, ["kept": 10])
        XCTAssertEqual(tokens[2], 2)
        XCTAssertEqual(tokens[3], 1)
    }

    func testExpiredCursorRebuildsWithoutResurrectingDeletedRecords() async throws {
        let pages = Pages([
            .success(.init(modifications: ["removed": .success(10)], token: 1)),
            .failure(Failure.expired),
            .success(.init(modifications: ["current": .success(20)], token: 2)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        let fresh = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(fresh, ["current": 20])
        XCTAssertNil(tokens[2])
    }

    func testNewAccountScopeNeverJoinsThePreviousAccountsSnapshot() async throws {
        let pages = Pages([
            .success(.init(modifications: ["old-account": .success(10)], token: 1)),
            .success(.init(modifications: ["new-account": .success(20)], token: 2)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents(scope: UUID())
        let fresh = try await reader.contents(scope: UUID())
        let tokens = await pages.tokens
        XCTAssertEqual(fresh, ["new-account": 20])
        XCTAssertNil(tokens[1], "The new scope always begins at the start, even before an async observer runs")
    }

    func testAccountInvalidationStartsWithAnEmptySnapshotAndNoCursor() async throws {
        let pages = Pages([
            .success(.init(modifications: ["old-account": .success(10)], token: 1)),
            .success(.init(modifications: ["new-account": .success(20)], token: 2)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        await reader.invalidate()
        let fresh = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(fresh, ["new-account": 20])
        XCTAssertNil(tokens[1])
    }

    /// The first fetch deliberately ignores cancellation until released, like a suspended
    /// CloudKit operation. Later requests must not remain attached to it or accept its result.
    private actor SuspendedPages {
        private var first: CheckedContinuation<Reader.Page, Never>?
        private var started: [CheckedContinuation<Void, Never>] = []
        private(set) var tokens: [Int?] = []

        func fetch(_ token: Int?) async -> Reader.Page {
            tokens.append(token)
            if tokens.count == 1 {
                return await withCheckedContinuation { continuation in
                    first = continuation
                    let waiting = started
                    started = []
                    for waiter in waiting { waiter.resume() }
                }
            }
            return .init(modifications: tokens.count == 2 ? ["current": .success(20)] : [:], token: tokens.count)
        }

        func waitUntilFirstFetch() async {
            if first != nil { return }
            await withCheckedContinuation { started.append($0) }
        }

        func releaseFirst() {
            first?.resume(returning: .init(modifications: ["late": .success(10)], token: 100))
            first = nil
        }
    }

    func testCancelledHungReadAllowsANewFetchBeforeTheOldOneReturns() async throws {
        let pages = SuspendedPages()
        let reader = Reader(fetch: { await pages.fetch($0) }, recovery: { _ in .fail })
        let first = Task { try await reader.contents() }
        await pages.waitUntilFirstFetch()
        first.cancel()

        let recovered = expectation(description: "New read completed while the old fetch remains suspended")
        let second = Task {
            defer { recovered.fulfill() }
            return try await reader.contents()
        }
        await fulfillment(of: [recovered], timeout: 1)
        // Release after checking recovery, so even a regression finishes with failed assertions
        // rather than leaving the test permanently suspended.
        await pages.releaseFirst()
        let secondResult = try await second.value
        let tokens = await pages.tokens
        XCTAssertEqual(secondResult, ["current": 20])
        XCTAssertEqual(tokens.count, 2, "A canceled, suspended fetch cannot hold the next read")
        XCTAssertNil(tokens[1])
        do { _ = try await first.value; XCTFail("The abandoned read must reject its late result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOldLateCompletionCannotReplaceTheNewSnapshotOrCursor() async throws {
        let pages = SuspendedPages()
        let reader = Reader(fetch: { await pages.fetch($0) }, recovery: { _ in .fail })
        let first = Task { try await reader.contents() }
        await pages.waitUntilFirstFetch()
        first.cancel()
        let recovered = expectation(description: "New generation committed before the old fetch finishes")
        let second = Task {
            defer { recovered.fulfill() }
            return try await reader.contents()
        }
        await fulfillment(of: [recovered], timeout: 1)
        await pages.releaseFirst()
        _ = try await second.value
        do { _ = try await first.value; XCTFail("The old generation must not commit") } catch {}

        let current = try await reader.contents()
        let tokens = await pages.tokens
        XCTAssertEqual(current, ["current": 20], "The canceled page cannot add old records")
        XCTAssertEqual(tokens[2], 2, "The next delta must use the new read's cursor, not the late cursor")
    }

    func testConcurrentCallersCoalesceIntoOneFetch() async throws {
        let pages = SuspendedPages()
        let reader = Reader(fetch: { await pages.fetch($0) }, recovery: { _ in .fail })
        let first = Task { try await reader.contents() }
        await pages.waitUntilFirstFetch()
        let joined = expectation(description: "Second caller entered contents")
        let second = Task {
            joined.fulfill()
            return try await reader.contents()
        }
        await fulfillment(of: [joined], timeout: 1)
        // Give the second task the actor turn to enter while the first fetch is suspended.
        for _ in 0..<20 { await Task.yield() }
        await pages.releaseFirst()

        let firstResult = try await first.value
        let secondResult = try await second.value
        let tokens = await pages.tokens
        XCTAssertEqual(firstResult, ["late": 10])
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(tokens.count, 1, "Concurrent readers share one active CloudKit fetch")
    }
}
