import CloudKit
import UIKit
import UserNotifications

/// Registers for CloudKit pushes and reads the relay when a Mac publishes new readings. Owns the
/// app's stores, so a silent push that launches the app in the background, with no window, still
/// has one to refresh.
@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var accountObserver: RelayAccountObserver?
    let store = MobileStore(containerIdentifier: LaunchEnvironment.isUnitTestHost ? nil : RelayAvailability.containerIdentifier)
    let news: NewsStore = {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "TokenroomSnapshotNews") {
            return NewsStore(directory: URL(fileURLWithPath: path).deletingLastPathComponent(), fetch: {
                .init(cache: $0.cache, newModels: [])
            })
        }
        #endif
        return NewsStore()
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard !LaunchEnvironment.isUnitTestHost else { return true }
        accountObserver = RelayAccountObserver(name: .CKAccountChanged) { [weak store] in
            PhoneCacheAccess.invalidate(in: AppGroup.defaults)
            Task { @MainActor in
                guard let store else { return }
                store.accountChanged()
                await store.refresh(force: true, includeKeys: UIApplication.shared.applicationState != .background)
            }
        }
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        WatchLink.shared.refreshReadings = { @MainActor [weak store] in
            guard let store else { return nil }
            await store.refresh(force: true)
            return store.watchReadings
        }
        WatchLink.shared.activate()
        return true
    }

    /// A silent push only means a Mac sent readings. iOS allows about 30 seconds; the answer goes
    /// back within 25 whatever iCloud does, and the refresh is cancelled then (its unfinished
    /// checks don't count). It says whether anything changed, which iOS weighs when it decides
    /// on later pushes.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let store = self.store
        let changed = await TimeLimit.run(25, otherwise: false) { await store.refreshForPush() }
        return changed ? .newData : .noData
    }

    /// Alerts show as banners while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
