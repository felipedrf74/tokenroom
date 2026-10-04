import XCTest
import Synchronization
@testable import Tokenroom

final class WatchHandoffTimingTests: XCTestCase, @unchecked Sendable {
    func testTimedOutReplyDoesNotCancelPhoneCollection() async {
        let cancelled = Mutex(false)
        let completed = expectation(description: "The phone collection finishes after the reply stops waiting")
        let result = await WatchHandoff.collectForReply(budget: 0.02) {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .milliseconds(120))
                completed.fulfill()
                return nil
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }
        XCTAssertNil(result)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertFalse(cancelled.withLock { $0 }, "A Watch reply timeout cannot cancel a phone key/cloud collection")
    }
}
