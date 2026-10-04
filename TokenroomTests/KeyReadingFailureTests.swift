import XCTest
@testable import Tokenroom

final class KeyReadingFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)
    private func reading(age: TimeInterval = 60) -> RelayProvider {
        RelayProvider(id: "openrouter", name: "OpenRouter", shortName: "OpenRouter", monogram: "OR", tint: "#000000",
                      state: "live", checkedAt: now.addingTimeInterval(-age), primaryWindowID: "balance",
                      windows: [.init(id: "balance", kind: "pool", title: "Balance", used: 42)])
    }

    func testFailedWidgetCheckRetainsMeasurementWithoutRefreshingSuccessfulCheck() {
        let saved = reading()
        for failure in [ProviderError.unreachable, .parse, .rateLimited(until: now.addingTimeInterval(60))] {
            let shown = saved.retainingAfterFailure(failure, at: now)
            XCTAssertFalse(shown.isLive)
            XCTAssertEqual(shown.windows, saved.windows)
            XCTAssertEqual(shown.checkedAt, saved.checkedAt)
            XCTAssertEqual(shown.fetchedAt, saved.fetchedAt)
        }
    }

    func testRejectedKeyIsExpiredAndRetainsAtMostADayOfMeasurements() {
        XCTAssertEqual(reading().retainingAfterFailure(.expired("Session expired."), at: now).state, "expired")
        XCTAssertEqual(reading().retainingAfterFailure(.expired("Session expired."), at: now).windows.count, 1)
        XCTAssertTrue(reading(age: 86_401).retainingAfterFailure(.expired("Session expired."), at: now).windows.isEmpty)
        XCTAssertTrue(reading().retainingAfterFailure(.signedOut("Add a key."), at: now).windows.isEmpty)
        XCTAssertTrue(reading().retainingAfterFailure(.notEntitled("No plan."), at: now).windows.isEmpty)
    }

    func testDelayedFailureCannotDowngradeANewerSuccessfulReading() {
        let newest = reading(age: -1)
        XCTAssertEqual(newest.retainingAfterFailure(.unreachable, at: now), newest)
    }
}
