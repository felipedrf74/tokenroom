import Foundation

enum LaunchEnvironment {
    static let isUnitTestHost = isUnitTestHost(ProcessInfo.processInfo.environment)

    static func isUnitTestHost(_ environment: [String: String]) -> Bool {
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains {
            environment[$0]?.isEmpty == false
        }
    }
}
