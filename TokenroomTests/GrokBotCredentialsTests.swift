import XCTest
@testable import Tokenroom

final class GrokBotCredentialsTests: XCTestCase {
    // OpenSSL AES-128-CBC vector, PBKDF2-HMAC-SHA1 / saltysalt / 1003 rounds.
    // Both the plaintext and password are invented fixtures.
    private let encrypted = "djEwL+PF0gBeypY11339V7VI43FYCzwQgJSOf6EJ+RmQj0Y="
    private let password = "fixture-storage-password"
    private var folders: [URL] = []

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    func testNativeActiveAccountWorksWithoutCursorAndDoesNotWriteItsLogin() throws {
        let file = try writeStore(active: "active-fixture")
        let original = try Data(contentsOf: file)
        let session = try GrokBotCredentials.read(file: file, password: { password }, cursor: {
            XCTFail("Native Grok Bot must not ask Cursor for a login")
            throw ProviderError.signedOut("fixture")
        })
        XCTAssertTrue(session.isNative)
        XCTAssertEqual(session.token, "placeholder-native-session")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testSignedOutOrMissingActiveAccountNeverUsesASavedAccountOrCursor() throws {
        for active: Any in [NSNull(), "missing-fixture"] {
            let file = try writeStore(active: active)
            XCTAssertThrowsError(try GrokBotCredentials.read(file: file, password: {
                XCTFail("Don't read the Keychain for a signed-out account")
                return password
            }, cursor: {
                XCTFail("Don't switch to Cursor's account")
                return "placeholder-cursor"
            })) { error in
                XCTAssertEqual(error as? ProviderError, .signedOut(Provider.grokBot.signInHint))
            }
        }
    }

    func testUnavailableNativeKeychainDoesNotFallThroughToCursor() throws {
        let file = try writeStore(active: "active-fixture")
        XCTAssertThrowsError(try GrokBotCredentials.read(file: file, password: { nil }, cursor: {
            XCTFail("An inaccessible native login isn't a missing login")
            return "placeholder-cursor"
        })) { error in
            XCTAssertEqual(error as? ProviderError, .expired(GrokBotCredentials.accessHint))
        }
    }

    func testAbsentNativeStoreRetainsLegacyCursorSupportWithGrokHints() throws {
        let missing = try folder().appendingPathComponent("missing.json")
        let session = try GrokBotCredentials.read(file: missing, password: { XCTFail(); return nil }, cursor: { "placeholder-cursor" })
        XCTAssertFalse(session.isNative)
        XCTAssertEqual(session.token, "placeholder-cursor")
        XCTAssertThrowsError(try GrokBotCredentials.read(file: missing, cursor: { throw ProviderError.signedOut(Provider.cursor.signInHint) })) {
            XCTAssertEqual($0 as? ProviderError, .signedOut(Provider.grokBot.signInHint))
        }
    }

    func testLegacyNativeStoreAndScopedActiveAccount() throws {
        let legacy = try JSONSerialization.data(withJSONObject: ["version": 1, "cursor-access-token": encrypted])
        XCTAssertEqual(try GrokBotCredentials.encryptedToken(from: legacy), encrypted)
        let scope = String(repeating: "a", count: 64)
        let file = try writeStore(active: scope, selected: scope, token: "scoped:v1:\(scope):\(encrypted)")
        XCTAssertEqual(try GrokBotCredentials.read(file: file, password: { password }).token, "placeholder-native-session")
        let mismatch = try writeStore(active: scope, selected: scope, token: "scoped:v1:\(String(repeating: "b", count: 64)):\(encrypted)")
        XCTAssertThrowsError(try GrokBotCredentials.read(file: mismatch, password: { XCTFail(); return password })) {
            XCTAssertEqual($0 as? ProviderError, .parse)
        }
    }

    func testMalformedOrUnknownNativeFormatsFailClosed() throws {
        for value: [String: Any] in [["version": 2, "cursor-access-token": encrypted], ["cursor-accounts": "broken", "cursor-access-token": encrypted]] {
            XCTAssertThrowsError(try GrokBotCredentials.encryptedToken(from: JSONSerialization.data(withJSONObject: value))) {
                XCTAssertEqual($0 as? ProviderError, .parse)
            }
        }
        XCTAssertEqual(GrokBotCredentials.decrypt(encrypted, password: password), "placeholder-native-session")
        XCTAssertNil(GrokBotCredentials.decrypt(encrypted, password: "wrong-fixture"))
        XCTAssertNil(GrokBotCredentials.decrypt("not-base64", password: password))
        XCTAssertNil(GrokBotCredentials.decrypt(Data("v11unsupported".utf8).base64EncodedString(), password: password))
        XCTAssertNil(GrokBotCredentials.decrypt(Data("v10short".utf8).base64EncodedString(), password: password))
    }

    func testAutomaticRefreshNeverPromptsForTheStorageKey() {
        XCTAssertNil(CredentialReaders.grokBotStoragePassword(access: { _ in .init(wasRead: true) }, read: { _, _ in
            XCTFail("No secret read before the ACL permits it")
            return .value("fixture")
        }))
        let allowed = CredentialReaders.ClaudeKeyAccess(partitions: ["apple-tool:"], hasPartitionList: true, wasRead: true)
        XCTAssertEqual(CredentialReaders.grokBotStoragePassword(access: { _ in allowed }, read: { service, timeout in
            XCTAssertEqual(service, "Grok Bot Safe Storage")
            XCTAssertEqual(timeout, 5)
            return .value("fixture")
        }), "fixture")
        XCTAssertEqual(CredentialReaders.grokBotStoragePassword(promptAllowed: true, access: { _ in XCTFail(); return .init() }, read: { _, timeout in
            XCTAssertEqual(timeout, 180, "Only an explicit Sign In waits for the user's dialog")
            return .value("fixture")
        }), "fixture")
    }

    func testClientRetriesTheNativeLoginAfterRenewalWithoutUsingCursor() async throws {
        let file = try writeStore(active: "active-fixture")
        let reads = Counter()
        stub { request in
            XCTAssertEqual(request.url?.host, "api2.cursor.sh")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer placeholder-native-session"
                ? (401, Data()) : (200, Data(#"{"usagePercent":12.5,"hasNonZeroIncludedLimit":true}"#.utf8))
        }
        let fixturePassword = password
        let client = GrokBotClient(readSession: { allowLegacyCursor in
            reads.increment()
            XCTAssertEqual(allowLegacyCursor, reads.count == 1)
            if reads.count == 1 { return try GrokBotCredentials.read(file: file, password: { fixturePassword }) }
            return .init(token: "placeholder-renewed-native", isNative: true)
        }, cursorAfterRefusal: { _ in XCTFail("Native sessions never retry as Cursor"); return nil })
        let result = await client.fetch()
        guard case .success(let snapshot) = result else { return XCTFail("Expected native usage") }
        XCTAssertEqual(snapshot.provider, .grokBot)
        XCTAssertEqual(snapshot.usedPercent, 12.5)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertTrue(GrokBotCredentials.wasRefused("placeholder-native-session"))
        XCTAssertFalse(GrokBotCredentials.wasRefused("placeholder-renewed-native"))
    }

    func testNativeRefusalDoesNotRetryTheSameTokenAnd429DoesNotReauthenticate() async {
        for status in [401, 429] {
            StubURLProtocol.reset()
            stub { _ in (status, Data()) }
            let reads = Counter()
            let client = GrokBotClient(readSession: { _ in
                reads.increment()
                return .init(token: "placeholder-refused-native", isNative: true)
            }, cursorAfterRefusal: { _ in XCTFail(); return nil })
            let result = await client.fetch()
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            if status == 401 { XCTAssertEqual(error, .expired(Provider.grokBot.expiredHint)) }
            else { guard case .rateLimited = error else { return XCTFail("Keep Retry-After") } }
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
            XCTAssertEqual(reads.count, status == 401 ? 2 : 1)
        }
    }

    func testNativeStoreDisappearingAfterRefusalDoesNotReadOrSendCursorCredentials() async throws {
        let file = try writeStore(active: "active-fixture")
        let fixturePassword = password
        let reads = Counter()
        stub { _ in (401, Data()) }
        let client = GrokBotClient(readSession: { allowLegacyCursor in
            reads.increment()
            if reads.count == 2 { try FileManager.default.removeItem(at: file) }
            return try GrokBotCredentials.read(file: file, password: { fixturePassword }, cursor: {
                XCTFail("A retry of a native account must never even read Cursor's credentials")
                return "placeholder-another-account"
            }, allowLegacyCursor: allowLegacyCursor)
        }, cursorAfterRefusal: { _ in XCTFail(); return nil })
        let result = await client.fetch()
        guard case .failure(let error) = result else { return XCTFail("Native sign-out must fail") }
        XCTAssertEqual(error, .signedOut(Provider.grokBot.signInHint))
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func writeStore(active: Any, selected: String = "active-fixture", token: String? = nil) throws -> URL {
        let accounts = try JSONSerialization.data(withJSONObject: ["active": active, "accounts": [selected: ["cursor-access-token": token ?? encrypted], "other-fixture": ["cursor-access-token": "must-not-be-read"]]])
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "cursor-accounts": String(decoding: accounts, as: UTF8.self)])
        let file = try folder().appendingPathComponent("sand-secrets.json")
        try data.write(to: file)
        return file
    }

    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }
}
