import XCTest
@testable import Tokenroom

final class KeyFetchConcurrencyTests: XCTestCase {
    func testAProviderWithoutSpacingCannotStartTwoChecksTogether() {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = KeyFetchGate(defaults: defaults)
        let widget = KeyFetchGate(defaults: defaults)
        let first = app.claim(.openrouter)
        XCTAssertNotNil(first)
        XCTAssertNil(widget.claim(.openrouter), "The widget must wait for the phone's active check")
        first?.finish()
        let next = widget.claim(.openrouter)
        XCTAssertNotNil(next)
        next?.finish()
    }

    func testCancellationCannotEraseANewerClaimAtTheSameTimestamp() throws {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(gate.claim(.openrouter, at: now))
        first.finish()
        let second = try XCTUnwrap(gate.claim(.openrouter, at: now))
        defer { second.finish() }
        gate.restoreAttempt(first)
        XCTAssertEqual(gate.lastAttempt(.openrouter), now)
        gate.restoreAttempt(second)
        XCTAssertEqual(gate.lastAttempt(.openrouter), now, "The second claim captured the first attempt atomically")
    }

    func testAResetFencesACancelledAttemptAndItsLate429() throws {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        gate.recordAttempt(.openrouter, at: now.addingTimeInterval(-600))
        let claim = try XCTUnwrap(gate.claim(.openrouter, at: now))
        defer { claim.finish() }
        gate.reset(.openrouter)
        gate.restoreAttempt(claim)
        gate.block(.openrouter, until: now.addingTimeInterval(600), matching: claim)
        XCTAssertNil(gate.lastAttempt(.openrouter))
        XCTAssertNil(gate.blockedUntil(.openrouter))
        XCTAssertNil(gate.claim(.openrouter, at: now), "Changing a key does not overlap its old physical check")
    }

    func testCancellationRestoresTheAttemptCapturedByTheClaim() throws {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = now.addingTimeInterval(-600)
        gate.recordAttempt(.openrouter, at: previous)
        let claim = try XCTUnwrap(gate.claim(.openrouter, at: now))
        defer { claim.finish() }
        gate.restoreAttempt(claim)
        XCTAssertEqual(gate.lastAttempt(.openrouter), previous)
    }

    func testTimeoutKeepsTheClaimUntilTheActualWorkerStops() async throws {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let claim = try XCTUnwrap(gate.claim(.openrouter))
        let entered = expectation(description: "Worker started")
        let finished = expectation(description: "Physical work finished and released lease")
        let held = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let client = HeldFetch(entered: entered, held: held)
        let caller = Task {
            await client.fetchWithinBudget(0.1, onWorkFinished: { result in gate.complete(claim, result: result); finished.fulfill() })
        }
        await fulfillment(of: [entered], timeout: 2)
        let result = await caller.value
        XCTAssertEqual(result, .failure(.unreachable))
        XCTAssertNil(gate.claim(.openrouter), "Returning the timeout is not physical completion")
        held.value?.resume()
        await fulfillment(of: [finished], timeout: 2)
        let next = gate.claim(.openrouter)
        XCTAssertNotNil(next)
        next?.finish()
    }

    func testLate429StillBlocksAfterTheCallerWasCancelled() async throws {
        let name = "tokenroom.tests.fetch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = KeyFetchGate(defaults: defaults)
        let now = Date.now
        let claim = try XCTUnwrap(gate.claim(.openrouter, at: now))
        let entered = expectation(description: "Worker started")
        let finished = expectation(description: "Late 429 persisted before releasing lease")
        let held = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let until = now.addingTimeInterval(600)
        let client = HeldFetch(entered: entered, held: held, result: .failure(.rateLimited(until: until)))
        let caller = Task {
            await client.fetchWithinBudget(0.1, onWorkFinished: { result in gate.complete(claim, result: result); finished.fulfill() })
        }
        await fulfillment(of: [entered], timeout: 2)
        caller.cancel()
        let answer = await caller.value
        XCTAssertEqual(answer, .failure(.unreachable))
        gate.restoreAttempt(claim)
        XCTAssertNil(gate.lastAttempt(.openrouter))
        held.value?.resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(gate.blockedUntil(.openrouter), until)
        XCTAssertNil(gate.claim(.openrouter, at: now.addingTimeInterval(1)))
    }
}

private struct HeldFetch: ProviderClient {
    let provider = Provider.openrouter
    let entered: XCTestExpectation
    let held: LockedBox<CheckedContinuation<Void, Never>?>
    var result: Result<QuotaSnapshot, ProviderError> = .failure(.parse)

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        await withCheckedContinuation { continuation in
            held.value = continuation
            entered.fulfill()
        }
        return result
    }
}
