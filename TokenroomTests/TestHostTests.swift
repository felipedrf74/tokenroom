import Foundation
import XCTest
@testable import Tokenroom

final class TestHostTests: XCTestCase {
    func testTheTestHostDoesNotCollect() {
        XCTAssertTrue(LaunchEnvironment.isUnitTestHost, "These tests run in a host that reads no real login")
        XCTAssertTrue(LaunchEnvironment.isUnitTestHost(["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        XCTAssertTrue(LaunchEnvironment.isUnitTestHost(["XCTestSessionIdentifier": "abc"]))
        XCTAssertFalse(LaunchEnvironment.isUnitTestHost([:]))
        XCTAssertFalse(LaunchEnvironment.isUnitTestHost(["XCTestConfigurationFilePath": ""]))
    }
}
