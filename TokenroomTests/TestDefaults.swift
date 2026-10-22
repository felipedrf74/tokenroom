import Foundation

/// UserDefaults suites for tests. Each name carries a token for this run, so two runs at once
/// (Xcode and a terminal, say) never share a suite, and `remove` deletes the suite's file too,
/// so the token doesn't leave one behind per run.
enum TestDefaults {
    static let run = UUID().uuidString.prefix(8).lowercased()

    private static var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// A fresh, empty suite: `owner` names the test class, `index` tells its suites apart.
    static func make(owner: String, index: Int) -> (name: String, defaults: UserDefaults) {
        _ = sweep
        let name = "tokenroom.tests.\(owner).\(run).\(index)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        // The emptied suite is written out after a removal; flushed first, its file stays deleted.
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(name).plist"))
    }

    /// The preferences daemon can still write an emptied suite back after `remove`. Once a run,
    /// such files from earlier runs are deleted: only this helper's names, and only ones an hour
    /// old, so a run going on at the same time keeps its own.
    private static let sweep: Void = {
        let pattern = /^tokenroom\.tests\.[A-Za-z]+\.[0-9a-f]{8}\.[0-9]+\.plist$/
        let cutoff = Date().addingTimeInterval(-3600)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for name in names where name.wholeMatch(of: pattern) != nil && !name.contains(".\(run).") {
            let file = preferences.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }()
}
