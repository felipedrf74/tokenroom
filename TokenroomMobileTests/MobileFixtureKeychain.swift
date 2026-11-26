import Foundation
import Security
@testable import TokenroomMobile

final class MobileFixtureKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var copies = 0
    var copyCount: Int { lock.withLock { copies } }

    var keys: APIKeyStore {
        APIKeyStore(servicePrefix: "app.tokenroom.tests.mobile-fixture.", keychain: .init(
            copy: { _ in
                self.lock.withLock { self.copies += 1 }
                return (errSecItemNotFound, nil)
            },
            add: { _ in errSecInteractionNotAllowed },
            update: { _, _ in errSecInteractionNotAllowed },
            delete: { _ in errSecItemNotFound }
        ))
    }
}
