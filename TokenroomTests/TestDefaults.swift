import Foundation

/// UserDefaults suites for tests. Each name carries a token for this run, so two runs at once
/// (Xcode and a terminal, say) never share a suite, and `remove` deletes the suite's file too,
/// so the token doesn't leave one behind per run.
enum TestDefaults {
    static let run = UUID().uuidString.prefix(8).lowercased()

    /// A fresh, empty suite: `owner` names the test class, `index` tells its suites apart.
    static func make(owner: String, index: Int) -> (name: String, defaults: UserDefaults) {
        let name = "tokenroom.tests.\(owner).\(run).\(index)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        // The emptied suite is written out after a removal; flushed first, its file stays deleted.
        CFPreferencesAppSynchronize(name as CFString)
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }
}
