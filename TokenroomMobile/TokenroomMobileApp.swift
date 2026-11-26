import SwiftUI
import UserNotifications

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
                await appDelegate.backgroundRefresh()
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
                .environment(\.mobileShowsSampleData, store.sampleMode)
                .task {
                    guard store.allowsExternalEffects else { return }
                    await store.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard store.allowsExternalEffects else { return }
                    switch phase {
                    case .active:
                        store.becameActive()
                        Task {
                            await NewsLifecycle.cameForward(news: news, preferences: { store.alertPreferences }) {
                                await store.refresh()
                            }
                        }
                    case .background:
                        Task { await store.scheduleBackgroundRefresh() }
                    default:
                        break
                    }
                }
                .onChange(of: store.hasOnboarded, initial: true) { _, onboarded in
                    guard store.allowsExternalEffects, onboarded, !store.sampleMode else { return }
                    Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                }
        }
    }
}
