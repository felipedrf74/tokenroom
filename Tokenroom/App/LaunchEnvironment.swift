import Foundation

/// How this process was launched. The unit tests run inside Tokenroom.app, and the app's own
/// checks would read this Mac's real logins (Claude's Keychain item included), renew them, and
/// publish to iCloud while the tests run. As a test host the app does none of that.
enum LaunchEnvironment {
    static let isUnitTestHost = isUnitTestHost(ProcessInfo.processInfo.environment)

    /// XCTest sets these in the host's environment before the app finishes launching.
    static func isUnitTestHost(_ environment: [String: String]) -> Bool {
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains {
            environment[$0]?.isEmpty == false
        }
    }
}
