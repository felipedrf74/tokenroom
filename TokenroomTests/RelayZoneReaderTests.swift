import XCTest
@testable import Tokenroom

final class RelayZoneReaderTests: XCTestCase {
    private typealias Reader = RelayZoneReader<String, Int, Int>
    private typealias RetryResults = [String: Result<Int?, any Error>]
    private enum Failure: Error { case expired, unavailable, rejectedRecord }
    private actor Pages {
        var pages: [Result<Reader.Page, any Error>]
        var tokens: [Int?] = []
        var retries: [Result<RetryResults, any Error>]
        var retriedIDs: [[String]] = []
        init(_ pages: [Result<Reader.Page, any Error>], retries: [Result<RetryResults, any Error>] = []) {
            self.pages = pages
            self.retries = retries
        }
        func fetch(_ token: Int?) throws -> Reader.Page {
            tokens.append(token)
            return try pages.removeFirst().get()
        }

        func retry(_ ids: [String]) throws -> RetryResults {
            retriedIDs.append(ids)
            return try retries.removeFirst().get()
        }
    }
    private func reader(_ pages: Pages, retryingRecords: Bool = false) -> Reader {
        let retry: (@Sendable ([String]) async throws -> RetryResults)?
        if retryingRecords { retry = { try await pages.retry($0) } }
        else { retry = nil }
        return Reader(fetch: { try await pages.fetch($0) }, recovery: {
            ($0 as? Failure) == .expired ? .retryFromStart : .fail
        }, retry: retry)
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

    /// The blocked record stays in the delta until its cursor is accepted. Repeating a failed
    /// cursor must not indefinitely hide a successful sibling that arrived on the same page.
    private actor StickyRecordPages {
        private(set) var tokens: [Int?] = []
        private(set) var retriedIDs: [[String]] = []

        func fetch(_ token: Int?) -> Reader.Page {
            tokens.append(token)
            if token == nil { return .init(modifications: ["kept": .success(10)], token: 1) }
            if token == 1 {
                return .init(modifications: ["kept": .failure(Failure.unavailable), "sibling": .success(20)], token: 2)
            }
            return .init(modifications: ["sibling": .success(30)], token: (token ?? 0) + 1)
        }

        func retry(_ ids: [String]) -> RetryResults {
            retriedIDs.append(ids)
            if retriedIDs.count == 1 { return ["kept": .failure(Failure.unavailable)] }
            return ["kept": .success(40)]
        }
    }

    func testStickyPerRecordFailureMustNotHideASiblingForever() async throws {
        let pages = StickyRecordPages()
        let reader = Reader(fetch: { await pages.fetch($0) }, recovery: { _ in .fail },
                            retry: { await pages.retry($0) })
        _ = try await reader.contents()

        let first = try? await reader.contents()
        XCTAssertEqual(first, ["sibling": 20], "A successful sibling must commit while the failed ID stays absent")
        let next = try? await reader.contents()
        XCTAssertEqual(next, ["sibling": 30], "A failed retry cannot pin later refreshes or restore a quarantined record")
        let recovered = try? await reader.contents()
        XCTAssertEqual(recovered, ["kept": 40, "sibling": 30], "A later successful ID retry reintroduces that record")
        _ = try? await reader.contents()
        let tokens = await pages.tokens
        let retries = await pages.retriedIDs
        XCTAssertEqual(tokens, [nil, 1, 2, 3, 4], "The accepted sibling page advances the delta cursor")
        XCTAssertEqual(retries, [["kept"], ["kept"]], "The quarantined ID is retried after its old delta was accepted")
    }

    func testQuarantinedIDRetriesWithoutAnotherDeltaAndEventuallyRecovers() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10), "blocked": .success(5)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: [:], token: 3)),
            .success(.init(modifications: [:], token: 4)),
            .success(.init(modifications: [:], token: 5)),
        ], retries: [
            .success(["blocked": .failure(Failure.rejectedRecord)]),
            .success(["blocked": .success(40)]),
        ])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        let partial = try await reader.contents()
        XCTAssertEqual(partial, ["kept": 10, "sibling": 20])
        let waiting = try await reader.contents()
        XCTAssertEqual(waiting, partial, "An individual retry failure keeps the ID absent and retains healthy siblings")
        let recovered = try await reader.contents()
        XCTAssertEqual(recovered, ["kept": 10, "blocked": 40, "sibling": 20])
        _ = try await reader.contents()
        let retries = await pages.retriedIDs
        let tokens = await pages.tokens
        XCTAssertEqual(retries, [["blocked"], ["blocked"]], "The ID is retried despite empty zone deltas, then leaves quarantine")
        XCTAssertEqual(tokens, [nil, 1, 2, 3, 4])
    }

    func testRepeatedQuarantinedOnlyPageFailureStillAdvances() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord)], token: 3)),
            .success(.init(modifications: ["next": .success(30)], token: 4)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        _ = try await reader.contents()
        let repeated = try await reader.contents()
        XCTAssertEqual(repeated, ["kept": 10, "sibling": 20])
        let next = try await reader.contents()
        XCTAssertEqual(next, ["kept": 10, "sibling": 20, "next": 30])
        let tokens = await pages.tokens
        XCTAssertEqual(tokens, [nil, 1, 2, 3])
    }

    func testZoneDeletionRemovesAQuarantinedIDWithoutRetryingIt() async throws {
        let pages = Pages([
            .success(.init(modifications: ["blocked": .success(5)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: [:], deletions: ["blocked"], token: 3)),
            .success(.init(modifications: [:], token: 4)),
        ])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        _ = try await reader.contents()
        let deleted = try await reader.contents()
        XCTAssertEqual(deleted, ["sibling": 20])
        let later = try await reader.contents()
        XCTAssertEqual(later, deleted)
        let retries = await pages.retriedIDs
        XCTAssertTrue(retries.isEmpty, "A confirmed zone deletion must clear the quarantined retry")
    }

    func testMissingQuarantinedRetryStopsRetryingWithoutReintroducingTheRecord() async throws {
        let pages = Pages([
            .success(.init(modifications: ["blocked": .success(5)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: [:], token: 3)),
            .success(.init(modifications: [:], token: 4)),
        ], retries: [.success(["blocked": .success(nil)])])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        _ = try await reader.contents()
        let deleted = try await reader.contents()
        XCTAssertEqual(deleted, ["sibling": 20])
        _ = try await reader.contents()
        let retries = await pages.retriedIDs
        XCTAssertEqual(retries, [["blocked"]])
    }

    func testSuccessfulLaterDeltaResolvesQuarantineBeforeTheIDRetry() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: ["blocked": .success(40)], token: 3)),
            .success(.init(modifications: [:], token: 4)),
        ])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        _ = try await reader.contents()
        let recovered = try await reader.contents()
        XCTAssertEqual(recovered, ["kept": 10, "sibling": 20, "blocked": 40])
        _ = try await reader.contents()
        let retries = await pages.retriedIDs
        XCTAssertTrue(retries.isEmpty, "The delta already resolved this ID; retrying it could replace it with an older fetch")
    }

    func testMixedPaginatedReadCanCommitASiblingAfterTheFailedRecordPage() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord)], token: 2, moreComing: true)),
            .success(.init(modifications: ["sibling": .success(20)], token: 3)),
        ])
        let reader = reader(pages)
        _ = try await reader.contents()
        let complete = try await reader.contents()
        XCTAssertEqual(complete, ["kept": 10, "sibling": 20])
        let tokens = await pages.tokens
        XCTAssertEqual(tokens, [nil, 1, 2])
    }

    func testPageOperationFailureRollsBackMixedChangesAndNewQuarantine() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "partial": .success(20)], token: 2, moreComing: true)),
            .failure(Failure.unavailable),
            .success(.init(modifications: [:], token: 3)),
        ])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        do { _ = try await reader.contents(); XCTFail("The failed page operation must remain visible") }
        catch { XCTAssertEqual(error as? Failure, .unavailable) }
        let retained = try await reader.contents()
        XCTAssertEqual(retained, ["kept": 10])
        let tokens = await pages.tokens
        let retries = await pages.retriedIDs
        XCTAssertEqual(tokens, [nil, 1, 2, 1])
        XCTAssertTrue(retries.isEmpty, "A rolled-back page must not leave a new ID quarantined")
    }

    func testRetryOperationFailureRollsBackUnrelatedDeltaAndKeepsQuarantine() async throws {
        let pages = Pages([
            .success(.init(modifications: ["kept": .success(10), "blocked": .success(5)], token: 1)),
            .success(.init(modifications: ["blocked": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
            .success(.init(modifications: ["partial": .success(30)], token: 3)),
            .success(.init(modifications: [:], token: 4)),
        ], retries: [.failure(Failure.unavailable), .success(["blocked": .success(40)])])
        let reader = reader(pages, retryingRecords: true)
        _ = try await reader.contents()
        _ = try await reader.contents()
        do { _ = try await reader.contents(); XCTFail("The failed retry operation must remain visible") }
        catch { XCTAssertEqual(error as? Failure, .unavailable) }
        let recovered = try await reader.contents()
        XCTAssertEqual(recovered, ["kept": 10, "blocked": 40, "sibling": 20])
        let tokens = await pages.tokens
        let retries = await pages.retriedIDs
        XCTAssertEqual(tokens, [nil, 1, 2, 2], "The failed retry operation cannot commit the staged zone cursor")
        XCTAssertEqual(retries, [["blocked"], ["blocked"]], "An operation failure cannot discard quarantine")
    }

    func testEstablishedQuarantineRetryCanProgressPastANewFailedOnlyPage() async throws {
        for recoveredValue in [40, nil] as [Int?] {
            let pages = Pages([
                .success(.init(modifications: ["a": .success(10)], token: 1)),
                .success(.init(modifications: ["a": .failure(Failure.rejectedRecord), "sibling": .success(20)], token: 2)),
                .success(.init(modifications: ["b": .failure(Failure.rejectedRecord)], token: 3)),
                .success(.init(modifications: [:], token: 4)),
            ], retries: [
                .success(["a": .success(recoveredValue)]),
                .success(["b": .failure(Failure.rejectedRecord)]),
            ])
            let reader = reader(pages, retryingRecords: true)
            _ = try await reader.contents()
            _ = try await reader.contents()
            let recovered = try await reader.contents()
            var expected = ["sibling": 20]
            if let recoveredValue { expected["a"] = recoveredValue }
            XCTAssertEqual(recovered, expected, "An established retry success or confirmed deletion must progress past newly failed b")
            let next = try await reader.contents()
            XCTAssertEqual(next, expected, "Newly quarantined b stays absent while its retry fails")
            let tokens = await pages.tokens
            let retries = await pages.retriedIDs
            XCTAssertEqual(tokens, [nil, 1, 2, 3])
            XCTAssertEqual(retries, [["a"], ["b"]])
        }
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
