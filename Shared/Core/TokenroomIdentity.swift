import Foundation

enum TokenroomIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.tokenroom.mac"
    static let cacheFolderName = "Tokenroom"
    static let repositoryURL = URL(string: "https://github.com/felipedrf74/tokenroom")!
    static let privacyURL = URL(string: "https://github.com/felipedrf74/tokenroom/blob/main/PRIVACY.md")!

    static let legacyBundleID = "app.headroom.mac"
    static let legacyCacheFolderName = "Headroom"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String {
        "Tokenroom/\(version) (+\(repositoryURL.absoluteString))"
    }
}
