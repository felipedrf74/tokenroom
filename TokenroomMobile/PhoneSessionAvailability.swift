import Foundation
import UIKit

/// Where a phone session may be kept on this iPhone: its own application identifier, read from
/// `TokenroomApplicationIdentifier` in Info.plist (`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`),
/// the way `RelayAvailability` reads the iCloud container. Nil when the build left it missing,
/// empty, or unfilled, or when it is the group widgets share for pasted keys: then no
/// `PhoneSessionStore` is made. Never logged.
enum PhoneSessionAvailability {
    static let infoKey = "TokenroomApplicationIdentifier"

    static var accessGroup: String? {
        PhoneSessionStore.accessGroup(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }

    /// The store, or nil when the access group can't be trusted: then no plan can be signed in to
    /// on this iPhone (`MobileStore.sessions` is nil, and Settings › Plans offers no Sign In).
    static func store() -> PhoneSessionStore? {
        PhoneSessionStore.make(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }
}

/// Deletes the sessions of plans this iPhone no longer signs in to (Claude), once a launch,
/// whatever the connect flag says (`PhoneSessionStore.purgeRetired`: Keychain deletes only, no
/// request). The items need the iPhone unlocked once since it started, so a launch before that (a
/// background push) waits for protected data instead of failing: it tries once when that arrives,
/// and an item still left is tried on the next launch, never in a loop.
@MainActor
final class RetiredSessionPurge {
    typealias Purge = @Sendable () async -> Void

    private let center: NotificationCenter
    private let purge: Purge
    private var observer: NSObjectProtocol?
    private(set) var hasRun = false

    init(center: NotificationCenter = .default, purge: @escaping Purge) {
        self.center = center
        self.purge = purge
    }

    /// The app's own: the iPhone app's session store, off the main thread.
    static func system() -> RetiredSessionPurge? {
        guard let store = PhoneSessionAvailability.store() else { return nil }
        return RetiredSessionPurge { await BlockingIO.run { _ = store.purgeRetired() } }
    }

    /// Runs now when protected data is available, else when it becomes so. Once a launch.
    func start(protectedDataAvailable: Bool) {
        guard !hasRun, observer == nil else { return }
        guard protectedDataAvailable else {
            observer = center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.run() }
            }
            return
        }
        run()
    }

    private func run() {
        guard !hasRun else { return }
        hasRun = true
        if let observer {
            center.removeObserver(observer)
            self.observer = nil
        }
        let purge = purge
        Task { await purge() }
    }
}
