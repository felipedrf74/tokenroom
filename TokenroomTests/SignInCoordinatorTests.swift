import XCTest
@testable import Tokenroom

final class SignInCoordinatorTests: XCTestCase {
    @MainActor
    func testACancelledCredentialCheckCannotCompleteASignIn() async throws {
        let reader = SignInReadProbe()
        let coordinator = SignInCoordinator(readStamp: { _ in "fixture-stamp" }, readUsable: { _ in await reader.read() })
        var connected: [Provider] = []
        coordinator.onConnected = { connected.append($0) }
        let attempt = try XCTUnwrap(coordinator.signIn(.cursor))
        await reader.waitUntilStarted()
        XCTAssertEqual(coordinator.phase, .running(.cursor))
        coordinator.cancel()
        await reader.release()
        await attempt.value
        XCTAssertTrue(connected.isEmpty, "A credential read that ignores cancellation cannot announce success")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    @MainActor
    func testAnOldCheckCannotClearANewerProvidersSignIn() async throws {
        let oldReader = SignInReadProbe()
        let newReader = SignInReadProbe()
        let coordinator = SignInCoordinator(
            readStamp: { _ in "fixture-stamp" },
            readUsable: { provider in provider == .cursor ? await oldReader.read() : await newReader.read() }
        )
        var connected: [Provider] = []
        coordinator.onConnected = { connected.append($0) }
        let oldAttempt = try XCTUnwrap(coordinator.signIn(.cursor))
        await oldReader.waitUntilStarted()
        let newAttempt = try XCTUnwrap(coordinator.signIn(.grokBot))
        await newReader.waitUntilStarted()
        await oldReader.release()
        await oldAttempt.value
        XCTAssertTrue(connected.isEmpty)
        XCTAssertEqual(coordinator.phase, .running(.grokBot), "The cancelled attempt must not erase the current phase")
        await newReader.release()
        await newAttempt.value
        XCTAssertEqual(connected, [.grokBot])
        XCTAssertEqual(coordinator.phase, .idle)
    }

    @MainActor
    func testCancellationDuringTheStampDoesNotStartAnotherCredentialRead() async throws {
        let stampReader = SignInReadProbe()
        let usableCalls = Counter()
        let coordinator = SignInCoordinator(
            readStamp: { _ in _ = await stampReader.read(); return "fixture-stamp" },
            readUsable: { _ in usableCalls.increment(); return true }
        )
        let attempt = try XCTUnwrap(coordinator.signIn(.cursor))
        await stampReader.waitUntilStarted()
        coordinator.cancel()
        await stampReader.release()
        await attempt.value
        XCTAssertEqual(usableCalls.count, 0, "Don't begin more credential work after cancellation")
        XCTAssertEqual(coordinator.phase, .idle)
    }
}

/// Deliberately ignores cancellation, like a credential read already running in BlockingIO.
private actor SignInReadProbe {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var readWaiter: CheckedContinuation<Void, Never>?

    func read() async -> Bool {
        await withCheckedContinuation { continuation in
            readWaiter = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
        return true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        readWaiter?.resume()
        readWaiter = nil
    }
}
