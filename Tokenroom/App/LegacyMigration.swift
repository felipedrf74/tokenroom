import AppKit
import Foundation

enum LegacyMigration {
    static let migratedKey = "migratedFromHeadroom"
    static let dismissedNoticeKey = "dismissedHeadroomNotice"
    private static let settingKeys = [
        AppSettings.Keys.enabled,
        AppSettings.Keys.refreshMinutes,
        AppSettings.Keys.menuStyle,
    ]

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDefaults: UserDefaults? = UserDefaults(suiteName: TokenroomIdentity.legacyBundleID),
        supportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        if let legacyDefaults, defaults.object(forKey: AppSettings.Keys.enabled) == nil {
            for key in settingKeys {
                if let value = legacyDefaults.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }

        guard let supportDirectory else { return }
        let fileManager = FileManager.default
        let legacyCache = supportDirectory
            .appendingPathComponent(TokenroomIdentity.legacyCacheFolderName, isDirectory: true)
            .appendingPathComponent("snapshots.json")
        let folder = supportDirectory.appendingPathComponent(TokenroomIdentity.cacheFolderName, isDirectory: true)
        let cache = folder.appendingPathComponent("snapshots.json")
        if fileManager.fileExists(atPath: legacyCache.path), !fileManager.fileExists(atPath: cache.path) {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.copyItem(at: legacyCache, to: cache)
        }
    }

    static func shouldShowNotice(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: dismissedNoticeKey) else { return false }
        return isLegacyAppRunning || legacyAppURL != nil
    }

    static func dismissNotice(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedNoticeKey)
    }

    static var isLegacyAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: TokenroomIdentity.legacyBundleID).isEmpty
    }

    static var legacyAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: TokenroomIdentity.legacyBundleID)
    }

    static func quitLegacyApp() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: TokenroomIdentity.legacyBundleID) {
            app.terminate()
        }
    }
}
