import Foundation
import UIKit

enum PhoneSessionAvailability {
    static let infoKey = "TokenroomApplicationIdentifier"

    static var accessGroup: String? {
        PhoneSessionStore.accessGroup(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }

    static func store() -> PhoneSessionStore? {
        PhoneSessionStore.make(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }
}

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

    static func system() -> RetiredSessionPurge? {
        guard let store = PhoneSessionAvailability.store() else { return nil }
        return RetiredSessionPurge { await BlockingIO.run { _ = store.purgeRetired() } }
    }

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
