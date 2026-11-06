import Foundation
import Security
import SwiftUI

/// Only app-owned test/snapshot roots select this composition. Injected store tests and
/// ordinary sample mode retain the production initializer's behavior.
@MainActor enum MobileRuntime {
    static func store(launchDefaults: UserDefaults = .standard,
                      isUnitTestHost: Bool = LaunchEnvironment.isUnitTestHost,
                      inertDefaults: UserDefaults? = nil) -> MobileStore {
        guard NewsRuntime.isInert(launchDefaults: launchDefaults, isUnitTestHost: isUnitTestHost) else { return MobileStore() }
        return MobileStore(defaults: inertDefaults ?? NewsRuntime.isolatedDefaults,
                           containerIdentifier: nil,
                           keys: APIKeyStore(servicePrefix: "app.tokenroom.inert-host.", keychain: .init(
                               copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecInteractionNotAllowed },
                               update: { _, _ in errSecInteractionNotAllowed }, delete: { _ in errSecItemNotFound })),
                           directory: nil, connectOnIPhone: showsConnect(launchDefaults),
                           notificationScheduler: { _ in }, allowsExternalEffects: false,
                           launchDefaults: launchDefaults)
    }
}

extension MobileRuntime {
    /// `-TokenroomSnapshotConnect YES`: an inert snapshot still shows the plan screens and choices
    /// a real user gets. Nothing in them works without a store that can reach out.
    private static func showsConnect(_ launchDefaults: UserDefaults) -> Bool {
        #if DEBUG
        launchDefaults.bool(forKey: "TokenroomSnapshotConnect")
        #else
        false
        #endif
    }
}

private struct MobileExternalEffectsKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var mobileAllowsExternalEffects: Bool {
        get { self[MobileExternalEffectsKey.self] }
        set { self[MobileExternalEffectsKey.self] = newValue }
    }
}
