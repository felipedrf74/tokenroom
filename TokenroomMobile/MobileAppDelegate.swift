import CloudKit
import UIKit
import UserNotifications

@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var accountObserver: RelayAccountObserver?
    private var retiredSessions: RetiredSessionPurge?
    let store = MobileRuntime.store()
    let news = NewsRuntime.newsStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard store.allowsExternalEffects else { return true }
        retiredSessions = RetiredSessionPurge.system()
        retiredSessions?.start(protectedDataAvailable: application.isProtectedDataAvailable)
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

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let store = self.store
        guard store.allowsExternalEffects else { return .noData }
        let changed = await TimeLimit.run(25, otherwise: false) { await store.refreshForPush() }
        return changed ? .newData : .noData
    }

    func backgroundRefresh() async {
        let store = self.store
        await NewsLifecycle.backgroundRefresh(news: news, preferences: store.alertPreferences) {
            await store.backgroundRefresh()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
