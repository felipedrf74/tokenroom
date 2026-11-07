import CloudKit
import UIKit
import UserNotifications

/// Registers for CloudKit pushes and reads the relay when a Mac publishes new readings. Owns the
/// app's stores, so a silent push that launches the app in the background, with no window, still
/// has one to refresh.
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
        // A Claude session an earlier version kept goes, with no request (`RetiredSessionPurge`).
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

    /// A silent push only means a Mac sent readings. iOS allows about 30 seconds; the answer goes
    /// back within 25 whatever iCloud does, and the refresh is cancelled then (its unfinished
    /// checks don't count). It says whether anything changed, which iOS weighs when it decides
    /// on later pushes.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let store = self.store
        guard store.allowsExternalEffects else { return .noData }
        let changed = await TimeLimit.run(25, otherwise: false) { await store.refreshForPush() }
        return changed ? .newData : .noData
    }

    /// iOS's background refresh: usage and News at once, News within 20 seconds
    /// (`NewsLifecycle.backgroundRefresh`). When iOS ends the task, its cancellation reaches the
    /// News pass, and what that cut short isn't counted as failing.
    func backgroundRefresh() async {
        let store = self.store
        await NewsLifecycle.backgroundRefresh(news: news, preferences: store.alertPreferences) {
            await store.backgroundRefresh()
        }
    }

    /// Alerts show as banners while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
