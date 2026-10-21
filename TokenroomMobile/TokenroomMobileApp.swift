import SwiftUI
import UserNotifications

// SceneBuilder cannot branch between scene types. Choose the app configuration before
// SwiftUI creates any scenes, so inert hosts never register a background task.
@main
enum TokenroomMobileEntry {
    @MainActor static func main() {
        if NewsRuntime.isInert() { InertTokenroomMobileApp.main() }
        else { TokenroomMobileApp.main() }
    }
}

struct TokenroomMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate

    var body: some Scene {
        MobileWindowScene(store: appDelegate.store, news: appDelegate.news)
            .backgroundTask(.appRefresh(MobileStore.backgroundTaskID)) {
                await appDelegate.store.backgroundRefresh()
                await appDelegate.news.refresh(preferences: appDelegate.store.alertPreferences)
            }
    }
}

private struct InertTokenroomMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate

    var body: some Scene {
        MobileWindowScene(store: appDelegate.store, news: appDelegate.news)
    }
}

private struct MobileWindowScene: Scene {
    let store: MobileStore
    let news: NewsStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store, news: news)
                .defaultAppStorage(store.allowsExternalEffects ? .standard : store.preferencesDefaults)
                .environment(\.mobileAllowsExternalEffects, store.allowsExternalEffects)
                .task {
                    // Also saves the push subscriptions, once iCloud answers. Not forced: when
                    // coming forward already started one, this is that refresh.
                    guard store.allowsExternalEffects else { return }
                    await store.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard store.allowsExternalEffects else { return }
                    switch phase {
                    case .active:
                        store.becameActive()
                        Task {
                            await store.refresh()
                            // What's due by News's hourly schedule, so its badge is current. With News on
                            // screen, its own 5-minute checks (`NewsView`) start as the app comes forward.
                            await news.refresh(preferences: store.alertPreferences)
                        }
                    case .background:
                        Task { await store.scheduleBackgroundRefresh() }
                    default:
                        break
                    }
                }
                .onChange(of: store.hasOnboarded, initial: true) { _, onboarded in
                    // Ask once the person has chosen how to use Tokenroom, not on first sight.
                    guard store.allowsExternalEffects, onboarded, !store.sampleMode else { return }
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                }
        }
    }
}
