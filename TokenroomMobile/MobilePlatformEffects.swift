import BackgroundTasks
import Foundation
import UIKit
import WidgetKit

@MainActor
struct MobilePlatformEffects {
    typealias Samples = [String: [String: [(date: Date, used: Double)]]]

    var setWatchConnectAvailable: @MainActor @Sendable (Bool) -> Void
    var sendToWatch: @MainActor @Sendable (ReadingCache) -> Void
    var reloadWidgets: @MainActor @Sendable () -> Void
    var applicationIsBackground: @MainActor @Sendable () -> Bool
    var updateLiveActivities: @MainActor @Sendable ([RelayProvider], AlertPreferences, Samples, Date) async -> Void
    var makeKeyFetchGate: @MainActor @Sendable (UserDefaults) -> KeyFetchGate
    var scheduleBackgroundRefresh: @MainActor @Sendable (Date) async throws -> Void
    var beginBackgroundWork: @MainActor @Sendable (String) -> @MainActor @Sendable () -> Void = { _ in {} }

    static let system = MobilePlatformEffects(
        setWatchConnectAvailable: { WatchLink.shared.connectAvailable = $0 },
        sendToWatch: { WatchLink.shared.send($0) },
        reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
        applicationIsBackground: { UIApplication.shared.applicationState == .background },
        updateLiveActivities: { providers, preferences, samples, now in
            await LiveActivities.update(with: providers, preferences: preferences, samples: samples, now: now)
        },
        makeKeyFetchGate: { KeyFetchGate(defaults: $0) },
        scheduleBackgroundRefresh: { now in
            let request = BGAppRefreshTaskRequest(identifier: MobileStore.backgroundTaskID)
            request.earliestBeginDate = now.addingTimeInterval(MobileStore.backgroundInterval)
            #if compiler(>=6.4)
            if #available(iOS 27.0, *) {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
            } else {
                try BGTaskScheduler.shared.submit(request)
            }
            #else
            try BGTaskScheduler.shared.submit(request)
            #endif
        },
        beginBackgroundWork: { name in
            let box = BackgroundTaskBox()
            box.id = UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { box.end() } }
            return { box.end() }
        }
    )

    static let inert = MobilePlatformEffects(
        setWatchConnectAvailable: { _ in }, sendToWatch: { _ in }, reloadWidgets: {},
        applicationIsBackground: { false }, updateLiveActivities: { _, _, _, _ in },
        makeKeyFetchGate: { KeyFetchGate(defaults: $0, lockDirectory: nil) },
        scheduleBackgroundRefresh: { _ in }
    )
}

@MainActor
private final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
