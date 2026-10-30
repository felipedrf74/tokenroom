import Security
import Synchronization
import XCTest
@testable import TokenroomMobile

/// Plans signed in to on this iPhone, through the store's real refresh pass: an in-memory
/// Keychain stands in for the sessions and canned answers for the vendors, so nothing here
/// touches this device's sign-ins or the network.
@MainActor
final class MobileSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600) // 2026-09-25 12:00 UTC
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func makeStore(defaults: UserDefaults, folder: URL, keychain: MemoryKeychain, vendor: Vendor,
                           keys: APIKeyStore = MobileFixtureKeychain().keys) -> MobileStore {
        MobileStore(
            defaults: defaults,
            containerIdentifier: nil,
            keys: keys,
            directory: folder, connectOnIPhone: true,
            notificationScheduler: { _ in },
            platformEffects: .inert, launchDefaults: defaults,
            sessions: keychain.store,
            sessionSend: { provider in { request in await vendor.respond(provider, request) } },
            sessionRenew: { _, _ in
                XCTFail("Sessions here don't need renewing")
                return .notDispatched
            }
        )
    }

    private func cursorSession(expiresIn: TimeInterval = 30 * 86_400) -> PhoneSession {
        PhoneSession(accessToken: "cursor-access", refreshToken: "cursor-refresh", expiresAt: now.addingTimeInterval(expiresIn),
                     tokenURL: PhoneSignIn.Cursor.tokenURL, clientID: PhoneSignIn.Cursor.clientID)
    }

    /// Keys whose save and removal succeed without storing anything: every read finds no key, so
    /// no key provider is called.
    private func acceptingKeys() -> APIKeyStore {
        APIKeyStore(servicePrefix: "app.tokenroom.tests.mobile-session.keys.", keychain: .init(
            copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecSuccess },
            update: { _, _ in errSecItemNotFound }, delete: { _ in errSecSuccess }))
    }

    // MARK: Reading

    func testACursorSignInReadsCursorAndGrokBotOnThisIPhone() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)

        await store.refresh(force: true, now: now)

        XCTAssertEqual(store.sessionProviders, [.cursor, .grokBot])
        XCTAssertEqual(Set(store.readings.filter { $0.origin == .thisPhone }.map(\.id)), ["cursor", "grokBot"])
        XCTAssertEqual(vendor.calls(.cursor), 1)
        XCTAssertEqual(vendor.calls(.grokBot), 1)
        XCTAssertEqual(vendor.authorizations, ["Bearer cursor-access"], "Both read with Cursor's one session")
        XCTAssertEqual(Set(vendor.urls), [PhoneSignIn.Cursor.usageURL, PhoneSignIn.Cursor.grokBotUsageURL])
        XCTAssertEqual(defaults.stringArray(forKey: MobileStore.Keys.sessionProviders), ["cursor", "grokBot"], "Widgets keep these readings")
        let saved = try XCTUnwrap(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName)))
        XCTAssertTrue(saved.items.contains { $0.provider.id == "grokBot" })
        XCTAssertFalse(try XCTUnwrap(store.reading(id: "cursor")).history.isEmpty, "In the history on the pass's clock, not pruned as a week old")

        // Within five minutes, nothing is called again.
        await store.refresh(force: true, now: now.addingTimeInterval(120))
        XCTAssertEqual(vendor.calls(.cursor), 1)
    }

    func testGrokBotNotOnTheCursorPlanStaysOutQuietlyUntilTheNextSignIn() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now, grokBotOnPlan: false)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)

        await store.refresh(force: true, now: now)
        XCTAssertEqual(store.sessionProviders, [.cursor])
        XCTAssertNil(store.reading(id: "grokBot"), "Neither shown nor listed as not connected")

        // Later the same day: not asked again.
        await store.refresh(force: true, now: now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(vendor.calls(.grokBot), 1)
        XCTAssertEqual(store.sessionProviders, [.cursor])

        // A new sign-in asks again at once, on the sign-in's clock: on the real one, a session
        // saved for this test's day would be long expired and sent for renewal.
        try await store.saveSession(cursorSession(), for: .grokBot, now: now.addingTimeInterval(3 * 3600 + 60))
        XCTAssertEqual(store.sessionProviders, [.cursor, .grokBot])
        for _ in 0..<200 where vendor.calls(.grokBot) < 2 || store.isRefreshing {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vendor.calls(.grokBot), 2)
        XCTAssertEqual(store.sessionProviders, [.cursor], "Still not on the plan: out quietly again")
    }

    func testSigningOutRemovesBothPlans() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        await store.refresh(force: true, now: now)

        try await store.removeSession(for: .grokBot)

        XCTAssertTrue(store.sessionProviders.isEmpty)
        XCTAssertNil(keychain.store.metadata(for: .cursor), "One sign-out ends Cursor's and Grok Bot's together")
        XCTAssertNil(store.reading(id: "cursor"))
        XCTAssertNil(store.reading(id: "grokBot"))
    }

    func testSigningOutOfOnePlanReadsTheOthersOnTheSignOutsClock() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let codex = PhoneSession(accessToken: "codex-access", refreshToken: "codex-refresh", expiresAt: now.addingTimeInterval(30 * 86_400),
                                 tokenURL: PhoneSignIn.Codex.tokenURL, clientID: PhoneSignIn.Codex.clientID)
        try keychain.store.save(codex, for: .openai, now: now)
        let vendor = Vendor(now: now)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        await store.refresh(force: true, now: now)
        XCTAssertEqual(store.sessionProviders, [.openai, .cursor, .grokBot])

        // Ten minutes on, Cursor is due again. On the real clock its session, dated from this
        // test's day, would be long expired and sent for renewal.
        try await store.removeSession(for: .openai, now: now.addingTimeInterval(600))

        XCTAssertEqual(store.sessionProviders, [.cursor, .grokBot])
        XCTAssertNil(keychain.store.metadata(for: .openai))
        XCTAssertNil(store.reading(id: "openai"))
        XCTAssertEqual(vendor.calls(.cursor), 2, "Read again by the sign-out's refresh")
    }

    func testARefreshAskedForDuringAnotherRunsOnItsOwnClock() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now, held: true)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        let start = now, later = now.addingTimeInterval(600)
        let first = Task { await store.refresh(force: true, now: start) }
        for _ in 0..<200 where vendor.calls(.cursor) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Ten minutes on, while the first pass waits on Cursor: queued behind it. On the real
        // clock, Cursor's session, dated from this test's day, would be long expired and sent
        // for renewal.
        let second = Task { await store.refresh(force: true, now: later) }
        for _ in 0..<10 {
            await Task.yield()
        }
        await vendor.release()
        await first.value
        await second.value

        XCTAssertEqual(vendor.calls(.cursor), 2, "Read again by the queued pass")
        XCTAssertFalse(store.isRefreshing)
    }

    func testSavingOrRemovingAKeyReadsPlansOnItsClock() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor, keys: acceptingKeys())
        await store.refresh(force: true, now: now)
        XCTAssertEqual(vendor.calls(.cursor), 1)

        // Ten minutes apart, Cursor is due again each time. On the real clock its session, dated
        // from this test's day, would be long expired and sent for renewal.
        try await store.saveKey("fixture-key", for: .openrouter, region: nil, now: now.addingTimeInterval(600))
        XCTAssertEqual(vendor.calls(.cursor), 2, "Read again by the saved key's refresh")
        try await store.removeKey(for: .openrouter, now: now.addingTimeInterval(1200))
        XCTAssertEqual(vendor.calls(.cursor), 3, "And by the removed key's")
    }

    func testAKeychainThatCantBeReadNowIsntASignOut() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now)
        let store = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        await store.refresh(force: true, now: now)

        keychain.locked = true
        await store.refresh(force: true, now: now.addingTimeInterval(600))

        XCTAssertEqual(store.sessionProviders, [.cursor, .grokBot], "Still listed, and still in the widgets' list")
        XCTAssertNotNil(store.reading(id: "cursor"))
        XCTAssertEqual(vendor.calls(.cursor), 1, "Not read while its session can't be")
    }

    func testAPlansRateLimitOutlastsARelaunch() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MemoryKeychain()
        try keychain.store.save(cursorSession(), for: .cursor, now: now)
        let vendor = Vendor(now: now, cursorRetryAfter: 2 * 3600)
        let first = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        await first.refresh(force: true, now: now)
        XCTAssertEqual(vendor.calls(.cursor), 1)

        // Relaunched ten minutes later: the wait Cursor asked for still holds.
        let relaunched = makeStore(defaults: defaults, folder: folder, keychain: keychain, vendor: vendor)
        await relaunched.refresh(force: true, now: now.addingTimeInterval(600))
        XCTAssertEqual(vendor.calls(.cursor), 1)
    }
}

// MARK: Stand-ins

/// Canned vendor answers, counting what was asked. `held` keeps every answer back, each counted
/// as it's asked, until `release`.
private final class Vendor: Sendable {
    private struct Log {
        var calls: [Provider: Int] = [:]
        var authorizations: Set<String> = []
        var urls: [URL] = []
    }

    private let log = Mutex(Log())
    private let gate: Gate?
    let now: Date
    let grokBotOnPlan: Bool
    let cursorRetryAfter: TimeInterval?

    init(now: Date, grokBotOnPlan: Bool = true, cursorRetryAfter: TimeInterval? = nil, held: Bool = false) {
        self.now = now
        self.grokBotOnPlan = grokBotOnPlan
        self.cursorRetryAfter = cursorRetryAfter
        gate = held ? Gate() : nil
    }

    func calls(_ provider: Provider) -> Int { log.withLock { $0.calls[provider] ?? 0 } }
    var authorizations: Set<String> { log.withLock { $0.authorizations } }
    var urls: [URL] { log.withLock { $0.urls } }

    func release() async {
        await gate?.open()
    }

    func respond(_ provider: Provider, _ request: URLRequest) async -> Result<QuotaSnapshot, ProviderError> {
        let result = answer(provider, request)
        await gate?.wait()
        return result
    }

    func answer(_ provider: Provider, _ request: URLRequest) -> Result<QuotaSnapshot, ProviderError> {
        log.withLock { log in
            log.calls[provider, default: 0] += 1
            log.authorizations.insert(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if let url = request.url, !log.urls.contains(url) { log.urls.append(url) }
        }
        if provider == .cursor, let wait = cursorRetryAfter {
            return .failure(.rateLimited(until: now.addingTimeInterval(wait)))
        }
        if provider == .grokBot, !grokBotOnPlan {
            return .failure(.notEntitled("Grok Bot isn't on this Cursor plan."))
        }
        let window = QuotaWindow(id: "cycle", kind: .billingCycle, title: "This cycle", usedPercent: 40, resetsAt: now.addingTimeInterval(10 * 86_400))
        return Result { try QuotaSnapshot.headlined(by: [window], provider: provider, fetchedAt: now) }.mapError { _ in .parse }
    }
}

/// Shut until opened, then open for good.
private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// An in-memory Keychain for phone sessions. `locked` makes every read fail as a locked device's
/// would.
private final class MemoryKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]
    private var isLocked = false

    var locked: Bool {
        get { lock.withLock { isLocked } }
        set { lock.withLock { isLocked = newValue } }
    }

    private static func key(_ query: [String: Any]) -> String {
        [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup].map { query[$0 as String] as? String ?? "" }.joined(separator: "|")
    }

    var store: PhoneSessionStore {
        PhoneSessionStore(
            accessGroup: "ABCDE12345.app.tokenroom.ios",
            servicePrefix: "app.tokenroom.tests.mobile-session.",
            recoveryService: "app.tokenroom.tests.mobile-session.recovery",
            keychain: KeychainOperations(
                copy: { query in
                    self.lock.withLock {
                        if self.isLocked { return (errSecInteractionNotAllowed, nil) }
                        guard let item = self.items[Self.key(query)] else { return (errSecItemNotFound, nil) }
                        if query[kSecReturnData as String] as? Bool == true, query[kSecReturnAttributes as String] == nil {
                            return (errSecSuccess, item[kSecValueData as String] as CFTypeRef?)
                        }
                        return (errSecSuccess, item as CFDictionary)
                    }
                },
                add: { attributes in
                    self.lock.withLock {
                        let key = Self.key(attributes)
                        guard self.items[key] == nil else { return errSecDuplicateItem }
                        self.items[key] = attributes
                        return errSecSuccess
                    }
                },
                update: { query, attributes in
                    self.lock.withLock {
                        let key = Self.key(query)
                        guard var item = self.items[key] else { return errSecItemNotFound }
                        item.merge(attributes) { $1 }
                        self.items[key] = item
                        return errSecSuccess
                    }
                },
                delete: { query in
                    self.lock.withLock { self.items.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess }
                }
            )
        )
    }
}
