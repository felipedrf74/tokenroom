import Foundation
import Security
import XCTest
@testable import Tokenroom

/// An in-memory Keychain: every query is recorded, any call can be made to fail, and no real
/// Keychain item is ever named.
final class FakeKeychain: @unchecked Sendable {
    enum Operation: Equatable { case copy, add, update, delete }

    struct Call {
        var operation: Operation
        var query: [String: Any]
        var attributes: [String: Any]?
    }

    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]
    private(set) var calls: [Call] = []
    /// Return a status to make that call fail without changing anything.
    var failure: (Operation, [String: Any]) -> OSStatus? = { _, _ in nil }

    private static let identity = [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup].map { $0 as String }

    private static func key(_ query: [String: Any]) -> String {
        identity.map { query[$0] as? String ?? "" }.joined(separator: "|")
    }

    var operations: KeychainOperations {
        KeychainOperations(
            copy: { self.copy($0) },
            add: { self.add($0) },
            update: { self.update($0, $1) },
            delete: { self.delete($0) }
        )
    }

    func item(service: String, account: String, group: String) -> [String: Any]? {
        lock.withLock { items[[service, account, group].joined(separator: "|")] }
    }

    func put(_ attributes: [String: Any]) {
        lock.withLock { items[Self.key(attributes)] = attributes }
    }

    var count: Int { lock.withLock { items.count } }

    func forgetCalls() { lock.withLock { calls = [] } }

    private func record(_ operation: Operation, _ query: [String: Any], _ attributes: [String: Any]? = nil) -> OSStatus? {
        lock.withLock { calls.append(Call(operation: operation, query: query, attributes: attributes)) }
        return failure(operation, query)
    }

    private func copy(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        if let status = record(.copy, query) { return (status, nil) }
        guard let item = lock.withLock({ items[Self.key(query)] }) else { return (errSecItemNotFound, nil) }
        if query[kSecReturnData as String] as? Bool == true, query[kSecReturnAttributes as String] == nil {
            return (errSecSuccess, item[kSecValueData as String] as CFTypeRef?)
        }
        return (errSecSuccess, item as CFDictionary)
    }

    private func add(_ attributes: [String: Any]) -> OSStatus {
        if let status = record(.add, attributes) { return status }
        return lock.withLock {
            let key = Self.key(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = attributes
            return errSecSuccess
        }
    }

    private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        if let status = record(.update, query, attributes) { return status }
        return lock.withLock {
            let key = Self.key(query)
            guard var item = items[key] else { return errSecItemNotFound }
            item.merge(attributes) { $1 }
            items[key] = item
            return errSecSuccess
        }
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        if let status = record(.delete, query) { return status }
        return lock.withLock { items.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

final class PhoneSessionTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { Self.now }
    let group = "ABCDE12345.app.tokenroom.ios"
    let sharedGroup = "ABCDE12345.app.tokenroom.shared"
    /// A fixture provider: the allowlist a test passes is the test's own, never production's.
    static let fixture = Provider.cursor
    var fixture: Provider { Self.fixture }

    private func makeStore(_ keychain: FakeKeychain) -> PhoneSessionStore {
        PhoneSessionStore(
            accessGroup: group,
            servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).session.",
            recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery",
            keychain: keychain.operations
        )
    }

    private func session(_ marker: String, expiresIn: TimeInterval) -> PhoneSession {
        Self.session(marker, expiresIn: expiresIn)
    }

    private static func session(_ marker: String, expiresIn: TimeInterval) -> PhoneSession {
        PhoneSession(
            accessToken: "access-\(marker)",
            refreshToken: "refresh-\(marker)",
            expiresAt: now.addingTimeInterval(expiresIn),
            tokenURL: URL(string: "https://example.invalid/token")!,
            clientID: "public-test-client"
        )
    }

    // MARK: Allowlist

    func testProductionAllowlistIsEmpty() {
        XCTAssertTrue(PhoneConnect.productionAllowlist.isEmpty)
    }

    func testTheClientRefusesEveryProviderOutsideTheAllowlistWithoutARequest() async {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try? store.save(session("old", expiresIn: 3600), for: .claude, now: now)
        let sends = Counter()
        for provider in Provider.allCases {
            let client = PhoneSessionClient(provider: provider, usageURL: URL(string: "https://example.invalid/usage")!, store: store) { _ in
                sends.increment()
                return .failure(.parse)
            }
            let result = await client.fetch(now: now)
            XCTAssertEqual(result, .failure(.signedOut(PhoneSessionClient.notAllowed)), provider.rawValue)
        }
        XCTAssertEqual(sends.count, 0, "No request is built while the allowlist is empty")
    }

    func testTheRefresherNeverPostsForAProviderOutsideTheAllowlist() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 30), for: .claude, now: now)
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store) { _, _ in
            posts.increment()
            return .unavailable
        }
        let outcome = await refresher.renewIfNeeded(.claude, now: now)
        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertEqual(posts.count, 0)
    }

    // MARK: Access group

    func testEverySessionQueryNamesTheAppIdentifierGroup() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let query = store.query(for: fixture)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group)
        XCTAssertNotEqual(query[kSecAttrAccessGroup as String] as? String, sharedGroup)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)

        try store.save(session("s", expiresIn: 3600), for: fixture, now: now)
        _ = store.session(for: fixture)
        _ = store.canReplace(fixture)
        _ = store.saveRecovery(session("n", expiresIn: 7200), for: fixture)
        _ = store.finishFromRecovery(for: fixture)
        store.markRejected(for: fixture, now: now)
        try store.remove(for: fixture)
        XCTAssertFalse(keychain.calls.isEmpty)
        for call in keychain.calls {
            XCTAssertEqual(call.query[kSecAttrAccessGroup as String] as? String, group, "\(call.operation) without the app-id group")
            XCTAssertEqual(call.query[kSecAttrSynchronizable as String] as? Bool, false)
        }
    }

    func testTheAccessGroupFailsClosed() {
        XCTAssertNil(PhoneSessionStore.accessGroup(plistValue: nil, sharedGroup: sharedGroup))
        XCTAssertNil(PhoneSessionStore.accessGroup(plistValue: "", sharedGroup: sharedGroup))
        XCTAssertNil(PhoneSessionStore.accessGroup(plistValue: "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)", sharedGroup: sharedGroup))
        XCTAssertNil(PhoneSessionStore.accessGroup(plistValue: "ABCDE12345.$(PRODUCT_BUNDLE_IDENTIFIER)", sharedGroup: sharedGroup))
        XCTAssertNil(PhoneSessionStore.accessGroup(plistValue: sharedGroup, sharedGroup: sharedGroup), "Never the widget-shared group")
        XCTAssertEqual(PhoneSessionStore.accessGroup(plistValue: group, sharedGroup: sharedGroup), group)
        XCTAssertEqual(PhoneSessionStore.accessGroup(plistValue: group, sharedGroup: nil), group)
    }

    func testAMissingOrUnfilledPlistValueWritesNothing() {
        let keychain = FakeKeychain()
        for value in [nil, "", "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)", sharedGroup] as [String?] {
            XCTAssertNil(PhoneSessionStore.make(plistValue: value, sharedGroup: sharedGroup, keychain: keychain.operations))
        }
        XCTAssertTrue(keychain.calls.isEmpty, "No store, so no Keychain call")
        XCTAssertNotNil(PhoneSessionStore.make(plistValue: group, sharedGroup: sharedGroup, keychain: keychain.operations))
    }

    // MARK: Items

    func testASessionAndItsMetadataAreSeparate() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        XCTAssertFalse(store.hasSession(for: fixture))
        try store.save(session("s", expiresIn: 3600), for: fixture, now: now)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-s")
        XCTAssertEqual(store.metadata(for: fixture), PhoneSessionMetadata(addedAt: now, state: .ready))
        let item = try XCTUnwrap(keychain.item(service: store.service(for: fixture), account: "default", group: group))
        let generic = String(decoding: try XCTUnwrap(item[kSecAttrGeneric as String] as? Data), as: UTF8.self)
        XCTAssertFalse(generic.contains("refresh-s"), "The metadata holds no token")
        XCTAssertFalse(generic.contains("access-s"))
    }

    func testARejectedRefreshClearsOnlyThatSession() throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("claude", expiresIn: 3600), for: .claude, now: now)
        try store.save(session("copilot", expiresIn: 3600), for: .copilot, now: now)
        // A pasted key, where `APIKeyStore` keeps it.
        keychain.put([
            kSecAttrService as String: "app.tokenroom.key.openrouter",
            kSecAttrAccount as String: "default",
            kSecAttrAccessGroup as String: sharedGroup,
            kSecValueData as String: Data("tr-key".utf8),
        ])
        store.markRejected(for: .claude, now: now.addingTimeInterval(60))

        XCTAssertNil(store.session(for: .claude))
        XCTAssertFalse(store.hasSession(for: .claude))
        XCTAssertEqual(store.metadata(for: .claude), PhoneSessionMetadata(addedAt: now, state: .rejected), "The item stays, with its date")
        let claude = try XCTUnwrap(keychain.item(service: store.service(for: .claude), account: "default", group: group))
        XCTAssertEqual(claude[kSecValueData as String] as? Data, PhoneSessionStore.rejectedMarker)
        XCTAssertEqual(store.session(for: .copilot)?.refreshToken, "refresh-copilot")
        XCTAssertNotNil(keychain.item(service: "app.tokenroom.key.openrouter", account: "default", group: sharedGroup))
        XCTAssertFalse(keychain.calls.contains { $0.operation == .delete }, "Nothing is deleted")
    }

    // MARK: Preflight

    func testAKeychainThatWontTakeAWriteStopsTheRefreshBeforeItsPosted() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 60), for: fixture, now: now)
        keychain.forgetCalls()
        keychain.failure = { operation, _ in operation == .update ? errSecInteractionNotAllowed : nil }
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in
            posts.increment()
            return .unavailable
        }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .preflightFailed)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-old")
        let updates = keychain.calls.filter { $0.operation == .update }
        XCTAssertFalse(updates.isEmpty)
        for call in updates {
            XCTAssertNil(call.attributes?[kSecValueData as String], "Preflight doesn't touch the token bytes")
        }
    }

    func testTheProbeIsDeletedEvenWhenItsAddFails() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        keychain.failure = { operation, query in
            operation == .add && query[kSecAttrAccount as String] as? String == PhoneSessionStore.probeAccount ? errSecInteractionNotAllowed : nil
        }
        XCTAssertFalse(store.canReplace(fixture))
        XCTAssertTrue(keychain.calls.contains { $0.operation == .delete && $0.query[kSecAttrAccount as String] as? String == PhoneSessionStore.probeAccount })
        keychain.failure = { _, _ in nil }
        XCTAssertTrue(store.canReplace(fixture))
        XCTAssertEqual(keychain.count, 0, "No probe is left behind")
        let probe = keychain.calls.first { $0.operation == .add }
        XCTAssertEqual(probe?.query[kSecValueData as String] as? Data, Data("ok".utf8), "The probe never holds a token")
    }

    func testAProbeThatCantBeDeletedMeansNo() {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        keychain.failure = { operation, _ in operation == .delete ? errSecInteractionNotAllowed : nil }
        XCTAssertFalse(store.canReplace(fixture))
    }

    // MARK: Renewal

    func testARenewalStoresTheNewGrantAndMarksItReady() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 120), for: fixture, now: now)
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, old in
            XCTAssertEqual(old.refreshToken, "refresh-old")
            XCTAssertEqual(store.metadata(for: Self.fixture)?.state, .exchanging, "Marked before the request")
            return .granted(Self.session("new", expiresIn: 3600))
        }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-new")
        XCTAssertEqual(store.metadata(for: fixture), PhoneSessionMetadata(addedAt: now, state: .ready))
        XCTAssertNil(store.takeRecovery(for: fixture), "The recovery item is deleted")
    }

    func testATokenNotNearExpiryIsNotRenewed() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: PhoneSessionRefresher.lead + 60), for: fixture, now: now)
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in
            posts.increment()
            return .unavailable
        }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .notDue)
        XCTAssertEqual(posts.count, 0)
    }

    func testAFailedRecoveryWriteIsRetriedWithoutPostingAgain() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 60), for: fixture, now: now)
        let posts = Counter()
        let recoveryWrites = Counter()
        var failingWrites = PhoneSessionRefresher.writeAttempts + 1
        keychain.failure = { operation, query in
            guard query[kSecAttrService as String] as? String == store.recoveryService, operation == .add || operation == .update else { return nil }
            if operation == .update { return nil }
            recoveryWrites.increment()
            if failingWrites > 0 {
                failingWrites -= 1
                return errSecInteractionNotAllowed
            }
            return nil
        }
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in
            posts.increment()
            return .granted(Self.session("new", expiresIn: 3600))
        }
        let first = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(first, .pendingWrite)
        XCTAssertEqual(recoveryWrites.count, PhoneSessionRefresher.writeAttempts, "The write was retried")
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-old")

        let second = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(second, .refreshed)
        XCTAssertEqual(posts.count, 1, "The grant in memory is written; the refresh token isn't sent again")
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-new")
        XCTAssertEqual(store.metadata(for: fixture)?.state, .ready)
    }

    func testARelaunchMidExchangeWithoutARecoveryItemIsRejectedWithoutPosting() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 60), for: fixture, now: now)
        XCTAssertTrue(store.setState(.exchanging, for: fixture))
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in
            posts.increment()
            return .granted(Self.session("new", expiresIn: 3600))
        }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(posts.count, 0, "The old refresh token may already be rotated")
        XCTAssertNil(store.session(for: fixture))
        XCTAssertEqual(store.metadata(for: fixture)?.state, .rejected)
    }

    func testARelaunchMidExchangeFinishesFromTheRecoveryItem() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 60), for: fixture, now: now)
        XCTAssertTrue(store.setState(.exchanging, for: fixture))
        XCTAssertTrue(store.saveRecovery(session("new", expiresIn: 3600), for: fixture))
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in
            posts.increment()
            return .unavailable
        }
        let outcome = await refresher.recover(fixture, now: now)
        XCTAssertEqual(outcome, .recovered)
        XCTAssertEqual(posts.count, 0)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-new")
        XCTAssertEqual(store.metadata(for: fixture)?.state, .ready)
        XCTAssertNil(store.takeRecovery(for: fixture))
    }

    func testAnUnreachableTokenHostLeavesTheSessionReady() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 90), for: fixture, now: now)
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in .unavailable }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(store.session(for: fixture)?.refreshToken, "refresh-old")
        XCTAssertEqual(store.metadata(for: fixture)?.state, .ready)
    }

    func testAnInvalidGrantMarksTheSessionRejected() async throws {
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(session("old", expiresIn: 90), for: fixture, now: now)
        let refresher = PhoneSessionRefresher(store: store, allowlist: [fixture]) { _, _ in .rejected }
        let outcome = await refresher.renewIfNeeded(fixture, now: now)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertNil(store.session(for: fixture))
        XCTAssertEqual(store.metadata(for: fixture)?.state, .rejected)
    }

    // MARK: Nothing secret leaves the store

    func testSessionMaterialNeverReachesARecord() async throws {
        let accessMarker = "TRSESSIONACCESSQ7"
        let refreshMarker = "TRSESSIONREFRESHQ7"
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        try store.save(PhoneSession(accessToken: accessMarker, refreshToken: refreshMarker, expiresAt: now.addingTimeInterval(3600),
                                    tokenURL: URL(string: "https://example.invalid/token")!, clientID: "public-test-client"),
                       for: fixture, now: now)
        let authorization = LockedBox<String?>(nil)
        let client = PhoneSessionClient(provider: fixture, usageURL: URL(string: "https://example.invalid/usage")!, store: store, allowlist: [fixture]) { request in
            authorization.value = request.value(forHTTPHeaderField: "Authorization")
            let window = QuotaWindow(id: "cycle", kind: .billingCycle, title: "This cycle", usedPercent: 40, resetsAt: Self.now.addingTimeInterval(86_400))
            return Result { try QuotaSnapshot.headlined(by: [window], provider: Self.fixture, fetchedAt: Self.now) }.mapError { _ in .parse }
        }
        let snapshot = try await client.fetch(now: now).get()
        XCTAssertEqual(authorization.value, "Bearer \(accessMarker)", "The session is used for the request")

        let history = await MainActor.run { () -> RelayHistory in
            let store = HistoryStore(directory: nil)
            store.record(snapshot)
            return store.relayHistory(for: [Self.fixture])
        }
        let provider = RelayProvider(provider: fixture, status: .live(snapshot), checkedAt: now)
        let envelope = RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [provider])
        let cache = ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: provider, source: "This iPhone", history: history.series)])
        var calm = provider, busy = provider
        calm.windows[0].used = 10
        busy.windows[0].used = 85
        let alerts = AlertRules.alerts(previous: calm, current: busy, preferences: AlertPreferences(), now: now)
        XCTAssertFalse(alerts.isEmpty)
        let events = alerts.map { [$0.id, $0.provider, $0.title, $0.body, $0.key, $0.shownKey].joined(separator: "|") }
        let cacheData = try RelayEnvelope.encoder.encode(cache)
        let payloads = [try envelope.encoded(), try history.encoded(), cacheData, try RelayEnvelope.encoder.encode(AlertPreferences())]
            .map { String(decoding: $0, as: UTF8.self) } + events
        for payload in payloads {
            XCTAssertFalse(payload.contains(accessMarker), "No access token")
            XCTAssertFalse(payload.contains(refreshMarker), "No refresh token")
            XCTAssertFalse(payload.contains("SESSION"), "No part of either")
            XCTAssertFalse(payload.contains("public-test-client"), "No client id")
            XCTAssertFalse(payload.localizedCaseInsensitiveContains("bearer"))
        }
        XCTAssertTrue(payloads[0].contains(Self.fixture.rawValue), "The reading itself is there")
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
