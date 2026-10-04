import Security
import XCTest
@testable import Tokenroom

final class APIKeyPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(_ keychain: FakeKeychain, protected: Bool = false) -> APIKeyStore {
        APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).", keychain: keychain.operations, usesDataProtection: protected)
    }

    func testAFailedReplacementPreservesThePreviousKeyAndMetadata() throws {
        for protected in [false, true] {
            let keychain = FakeKeychain()
            let store = makeStore(keychain, protected: protected)
            try store.save("placeholder-original", for: .moonshot, region: "China", warning: "Previous warning", now: now)
            let metadata = store.metadata(for: .moonshot)
            keychain.forgetCalls()
            keychain.failure = { operation, _ in operation == .update ? errSecInteractionNotAllowed : nil }
            XCTAssertThrowsError(try store.save("placeholder-replacement", for: .moonshot, region: "Global", now: now.addingTimeInterval(60))) {
                XCTAssertEqual($0 as? APIKeyStore.KeyError, .keychain(errSecInteractionNotAllowed))
            }
            XCTAssertEqual(store.key(for: .moonshot), "placeholder-original")
            XCTAssertEqual(store.metadata(for: .moonshot), metadata)
            XCTAssertFalse(keychain.calls.contains { $0.operation == .delete }, "A failed save must never remove a working key")
            XCTAssertFalse(keychain.calls.contains { $0.operation == .add }, "A failed update is not a missing item")
        }
    }

    func testAReplacementUpdatesKeyAndMetadataInOneWrite() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save("placeholder-original", for: .copilot, region: "Pro", warning: "Old warning", now: now)
        keychain.forgetCalls()
        try store.save("placeholder-replacement", for: .copilot, region: "Max", now: now.addingTimeInterval(60))
        XCTAssertEqual(keychain.calls.map(\.operation), [.update])
        XCTAssertEqual(store.key(for: .copilot), "placeholder-replacement")
        let metadata = try XCTUnwrap(store.metadata(for: .copilot))
        XCTAssertEqual(metadata.region, "Max")
        XCTAssertEqual(metadata.addedAt, now.addingTimeInterval(60))
        XCTAssertNil(metadata.warning)
        XCTAssertEqual(keychain.count, 1)
    }

    func testAFailedFirstSaveDoesNotDeleteOrCreateAnything() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        keychain.failure = { operation, _ in operation == .add ? errSecInteractionNotAllowed : nil }
        XCTAssertThrowsError(try store.save("placeholder-new", for: .deepseek, now: now))
        XCTAssertEqual(keychain.calls.map(\.operation), [.update, .add])
        XCTAssertEqual(keychain.count, 0)
    }

    func testAFirstSaveRacingAnotherAddStillSavesTheRequestedRevision() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let inserted = Counter()
        keychain.failure = { operation, query in
            guard operation == .add, inserted.count == 0 else { return nil }
            inserted.increment()
            keychain.put(query)
            return errSecDuplicateItem
        }
        try store.save("placeholder-new", for: .copilot, region: "Max", now: now)
        XCTAssertEqual(keychain.calls.map(\.operation), [.update, .add, .update])
        XCTAssertEqual(store.key(for: .copilot), "placeholder-new")
        XCTAssertEqual(store.metadata(for: .copilot)?.region, "Max")
    }

    func testAFailedLegacyCopyKeepsTheOnlyExistingKey() throws {
        let keychain = LegacyAPIKeychain()
        keychain.failProtectedAdd = true
        let store = APIKeyStore(servicePrefix: "app.tokenroom.tests.legacy.", keychain: keychain.operations, usesDataProtection: true)
        XCTAssertEqual(store.key(for: .openrouter), "placeholder-legacy")
        XCTAssertNotNil(keychain.legacy)
        XCTAssertNil(keychain.protected)
        XCTAssertEqual(keychain.deletes, 0, "Restoring after failed migration cannot be guaranteed; don't delete first")
    }

    func testALegacyCopyIsDurableBeforeItBecomesThePreferredKey() throws {
        let keychain = LegacyAPIKeychain()
        let store = APIKeyStore(servicePrefix: "app.tokenroom.tests.legacy.", keychain: keychain.operations, usesDataProtection: true)
        XCTAssertEqual(store.key(for: .openrouter), "placeholder-legacy")
        XCTAssertNotNil(keychain.protected)
        XCTAssertNotNil(keychain.legacy, "An ambiguous legacy delete can remove the protected copy too")
        try store.save("placeholder-new", for: .openrouter, now: now)
        XCTAssertEqual(store.key(for: .openrouter), "placeholder-new")
        XCTAssertEqual(keychain.deletes, 0)
        try store.remove(for: .openrouter)
        XCTAssertNil(keychain.protected)
        XCTAssertNil(keychain.legacy, "An intentional Remove clears both copies")
    }

    func testALegacyDeleteFailureCannotReportSuccessfulRemoval() throws {
        let keychain = LegacyAPIKeychain()
        let store = APIKeyStore(servicePrefix: "app.tokenroom.tests.legacy.", keychain: keychain.operations, usesDataProtection: true)
        _ = store.key(for: .openrouter)
        keychain.failLegacyDelete = true
        XCTAssertThrowsError(try store.remove(for: .openrouter)) {
            XCTAssertEqual($0 as? APIKeyStore.KeyError, .keychain(errSecInteractionNotAllowed))
        }
        XCTAssertNil(keychain.protected)
        XCTAssertNotNil(keychain.legacy, "The retained old key means Remove must show an error")
    }
}

/// Reproduces macOS's ambiguous legacy query: without the protection flag, a query can match
/// either location, and a delete can remove both. Only placeholder data is held in memory.
private final class LegacyAPIKeychain: @unchecked Sendable {
    private let lock = NSLock()
    var legacy: [String: Any]? = [kSecValueData as String: Data("placeholder-legacy".utf8)]
    var protected: [String: Any]?
    var failProtectedAdd = false
    var failLegacyDelete = false
    var deletes = 0

    private func wantsProtected(_ query: [String: Any]) -> Bool {
        query[kSecUseDataProtectionKeychain as String] as? Bool == true
    }

    var operations: KeychainOperations {
        KeychainOperations(
            copy: { query in
                self.lock.withLock {
                    guard let item = self.wantsProtected(query) ? self.protected : (self.protected ?? self.legacy) else { return (errSecItemNotFound, nil) }
                    if query[kSecReturnData as String] as? Bool == true, query[kSecReturnAttributes as String] == nil {
                        return (errSecSuccess, item[kSecValueData as String] as CFTypeRef?)
                    }
                    return (errSecSuccess, item as CFDictionary)
                }
            },
            add: { attributes in
                self.lock.withLock {
                    if self.wantsProtected(attributes) {
                        if self.failProtectedAdd { return errSecInteractionNotAllowed }
                        guard self.protected == nil else { return errSecDuplicateItem }
                        self.protected = attributes
                    } else {
                        guard self.legacy == nil else { return errSecDuplicateItem }
                        self.legacy = attributes
                    }
                    return errSecSuccess
                }
            },
            update: { query, attributes in
                self.lock.withLock {
                    if self.wantsProtected(query) {
                        guard var item = self.protected else { return errSecItemNotFound }
                        item.merge(attributes) { $1 }
                        self.protected = item
                    } else {
                        guard var item = self.legacy else { return errSecItemNotFound }
                        item.merge(attributes) { $1 }
                        self.legacy = item
                    }
                    return errSecSuccess
                }
            },
            delete: { query in
                self.lock.withLock {
                    self.deletes += 1
                    if !self.wantsProtected(query), self.failLegacyDelete { return errSecInteractionNotAllowed }
                    self.protected = nil
                    if !self.wantsProtected(query) { self.legacy = nil }
                    return errSecSuccess
                }
            }
        )
    }
}
