import Foundation

enum TestDefaults {
    static let run = UUID().uuidString.prefix(8).lowercased()

    private static var preferences: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    static func make(owner: String, index: Int) -> (name: String, defaults: UserDefaults) {
        _ = sweep
        let name = "tokenroom.tests.\(owner).\(run).\(index)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (name, defaults)
    }

    static func remove(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(name).plist"))
    }

    private static let sweep: Void = {
        let patterns = [
            #/^tokenroom\.tests\.[A-Za-z]+\.[0-9a-f]{8}\.[0-9]+\.plist$/#,
            #/^(?:app\.)?tokenroom\.tests\.(?:[A-Za-z0-9-]+\.)*[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\.plist$/#,
        ]
        let cutoff = Date().addingTimeInterval(-3600)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for name in names where patterns.contains(where: { name.wholeMatch(of: $0) != nil }) && !name.contains(".\(run).") {
            let file = preferences.appendingPathComponent(name)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }()
}
