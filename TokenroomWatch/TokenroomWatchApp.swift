import SwiftUI
import CloudKit

@main
struct TokenroomWatchApp: App {
    @State private var store = WatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TimelineView(.periodic(from: .now, by: 60)) { tick in
                WatchRootView(store: store, date: tick.date)
            }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in store.accountChanged() }
                .task {
                    await store.refresh(force: true)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task { await store.refresh() }
                    case .background:
                        store.scheduleBackgroundRefresh()
                    default:
                        break
                    }
                }
        }
        .backgroundTask(.appRefresh(WatchStore.backgroundTaskID)) {
            // The next one first, so a refresh that runs out of time doesn't end them.
            await store.scheduleBackgroundRefresh()
            await store.refresh(force: true)
        }
        .backgroundTask(.watchConnectivity) {
            await store.receiveBackgroundHandoff()
        }
    }
}
