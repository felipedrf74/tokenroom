import XCTest
@testable import Tokenroom

/// Renews placeholder logins in temporary files. Never the real CLI sessions, and never the login Keychain:
/// every call passes `persistsRecovery: false`.
final class LoginSessionTests: XCTestCase {
    private var folders: [URL] = []
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        CredentialReaders.clearRenewalRejection(.grok)
        CredentialReaders.clearRenewalRejection(.claude)
        CredentialReaders.clearRenewalRejection(.openai)
        for folder in folders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        folders = []
        super.tearDown()
    }

    func testNestedReplacementKeepsSurroundingText() {
        let text = "{\n  \"note\": \"key is access-old\",\n  \"wrapped\": {\"key\": \"access-old\"},\n  \"items\": [{\"key\": \"other\"}]\n}\n"
        let updated = JSONTextEdit.replaceValue(of: "key", equalTo: "\"access-old\"", with: "\"access-new\"", in: text)
        XCTAssertEqual(
            updated,
            "{\n  \"note\": \"key is access-old\",\n  \"wrapped\": {\"key\": \"access-new\"},\n  \"items\": [{\"key\": \"other\"}]\n}\n"
        )
        XCTAssertNil(JSONTextEdit.replaceValue(of: "key", equalTo: "\"missing\"", with: "\"x\"", in: text))
        XCTAssertNil(JSONTextEdit.literals(of: "key", in: "{\"key\":"))
    }

    func testRenewalDecisions() {
        XCTAssertNotNil(
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"],
            "LoginSession skips the real CLI login only when this is set"
        )
        XCTAssertTrue(OAuthRefresh.needsRefresh(expiresAt: now.addingTimeInterval(180), now: now, canRefresh: true))
        XCTAssertFalse(OAuthRefresh.needsRefresh(expiresAt: now.addingTimeInterval(181), now: now, canRefresh: true))
        XCTAssertFalse(OAuthRefresh.needsRefresh(expiresAt: now.addingTimeInterval(10), now: now, canRefresh: false))
        XCTAssertFalse(OAuthRefresh.needsRefresh(expiresAt: nil, now: now, canRefresh: true))
        XCTAssertFalse(OAuthRefresh.stillUsable(expiresAt: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(OAuthRefresh.stillUsable(expiresAt: now.addingTimeInterval(61), now: now))
        XCTAssertTrue(OAuthRefresh.stillUsable(expiresAt: nil, now: now))
        XCTAssertNil(OAuthRefresh.grokTokenURL(issuer: "https://accounts.example"))
        XCTAssertNil(OAuthRefresh.grokTokenURL(issuer: "http://auth.x.ai"))
        XCTAssertEqual(OAuthRefresh.grokTokenURL(issuer: "")?.absoluteString, "https://auth.x.ai/oauth2/token")
        XCTAssertEqual(OAuthRefresh.formEscape("refresh+old/a="), "refresh%2Bold%2Fa%3D")
        XCTAssertEqual(
            OAuthRefresh.timestamp(like: "2020-01-01T00:00:00.000000Z", date: Date(timeIntervalSince1970: 0.5)),
            "1970-01-01T00:00:00.500000Z"
        )
    }

    func testARefreshableGrokLoginCountsUntilTheGrantIsRejected() {
        let auth = CredentialReaders.GrokAuth(
            accessToken: "access-old",
            expiresAt: now.addingTimeInterval(-5),
            userID: nil,
            refreshToken: "refresh-old",
            clientID: "client-1",
            issuer: "https://auth.x.ai"
        )
        XCTAssertTrue(auth.countsAsUsableSession(now: now))
        CredentialReaders.noteRenewalRejected(.grok, refreshToken: "refresh-old")
        XCTAssertFalse(auth.countsAsUsableSession(now: now), "Sign In can start a real login once the refresh grant is dead")
        CredentialReaders.clearRenewalRejection(.grok)
        XCTAssertTrue(auth.countsAsUsableSession(now: now))

        var otherIssuer = auth
        otherIssuer.issuer = "https://accounts.example"
        XCTAssertFalse(otherIssuer.canRenew)
        XCTAssertFalse(otherIssuer.countsAsUsableSession(now: now))
    }

    func testAFreshGrokTokenIsNotRenewed() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2030-01-01T00:00:00.000000Z")
        let original = try String(contentsOf: file, encoding: .utf8)
        stub { _ in (500, Data()) }
        let session = LoginSession()
        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "access-old")
        XCTAssertTrue(grantRequests().isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testAnExpiredGrokLoginIsRenewedInPlace() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh+old/a=", expires: "2020-01-01T00:00:00.000000Z", mode: 0o600)
        stub { _ in
            (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":21600}"#.utf8))
        }
        let session = LoginSession()
        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "access-new")

        let request = try XCTUnwrap(grantRequests().first)
        XCTAssertEqual(request.url?.host, "auth.x.ai")
        XCTAssertEqual(request.url?.path, "/oauth2/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = bodyText(request)
        XCTAssertTrue(body.contains("grant_type=refresh_token"), body)
        XCTAssertTrue(body.contains("client_id=client-1"), body)
        XCTAssertTrue(body.contains("refresh_token=refresh%2Bold%2Fa%3D"), body)

        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"key\": \"access-new\""), saved)
        XCTAssertTrue(saved.contains("\"refresh_token\": \"refresh-new\""), saved)
        XCTAssertTrue(saved.contains("\"note\": \"keep me\""), saved)
        XCTAssertTrue(saved.contains("\"create_time\": \"2020-01-01T00:00:00.000000Z\""), saved)
        XCTAssertFalse(saved.contains("access-old"), saved)
        XCTAssertFalse(saved.contains("refresh+old"), saved)
        let expectedExpiry = OAuthRefresh.timestamp(like: "2020-01-01T00:00:00.000000Z", date: now.addingTimeInterval(21600))
        XCTAssertTrue(saved.contains(expectedExpiry), saved)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.uint16Value, 0o600)
    }

    func testARejectedGrokGrantLeavesTheFileAlone() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z")
        let original = try String(contentsOf: file, encoding: .utf8)
        stub { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let session = LoginSession()
        do {
            _ = try await session.grok(at: file, now: now, persistsRecovery: false)
            XCTFail("Expected an expired session")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.grok.expiredHint))
        }
        XCTAssertEqual(grantRequests().count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)

        StubURLProtocol.requests = []
        do {
            _ = try await session.grok(at: file, now: now, persistsRecovery: false)
            XCTFail("Expected the rejected grant to stay rejected")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.grok.expiredHint))
        }
        XCTAssertTrue(grantRequests().isEmpty, "A dead refresh token is not exchanged again")
    }

    func testAGrokLoginTheCLIReplacedIsNotOverwritten() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z")
        let replacement = grokJSON(access: "cli-access", refresh: "cli-refresh", expires: "2030-01-01T00:00:00.000000Z")
        stub { _ in
            try? Data(replacement.utf8).write(to: file)
            return (400, Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let session = LoginSession()
        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "cli-access")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), replacement)
    }

    func testASuccessfulGrantDoesNotClobberANewerCLILogin() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z")
        let replacement = grokJSON(access: "cli-access", refresh: "cli-refresh", expires: "2030-01-01T00:00:00.000000Z")
        stub { _ in
            try? Data(replacement.utf8).write(to: file)
            return (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":21600}"#.utf8))
        }
        let session = LoginSession()
        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "cli-access")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(saved, replacement)
        XCTAssertFalse(saved.contains("access-new"))
        XCTAssertFalse(saved.contains("refresh-new"))
    }

    func testAnotherGrokIssuerIsNotCalled() async throws {
        let file = try writeGrok(
            access: "access-old",
            refresh: "refresh-old",
            expires: "2020-01-01T00:00:00.000000Z",
            issuer: "https://accounts.example"
        )
        stub { _ in (200, Data(#"{"access_token":"access-new"}"#.utf8)) }
        let session = LoginSession()
        do {
            _ = try await session.grok(at: file, now: now, persistsRecovery: false)
            XCTFail("Expected an expired session")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.grok.expiredHint))
        }
        XCTAssertTrue(grantRequests().isEmpty)
    }

    func testAFailedWriteIsRetriedFromMemoryWithoutAnotherGrant() async throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("auth.json")
        try Data(grokJSON(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z").utf8).write(to: file)
        stub { _ in
            (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":21600}"#.utf8))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        let session = LoginSession()
        do {
            _ = try await session.grok(at: file, now: now, persistsRecovery: false)
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        XCTAssertEqual(grantRequests().count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "access-new")
        XCTAssertEqual(grantRequests().count, 1, "The saved grant is written back without exchanging it again")
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("refresh-new"), saved)
        XCTAssertTrue(saved.contains("\"note\": \"keep me\""), saved)
    }

    func testGrokRenewalKeepsAUsableTokenWhenTheNetworkFails() async throws {
        let file = try writeGrok(
            access: "access-old",
            refresh: "refresh-old",
            expires: OAuthRefresh.timestamp(like: "2020-01-01T00:00:00.000000Z", date: now.addingTimeInterval(120))
        )
        stub { _ in (500, Data()) }
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        let session = LoginSession()
        let auth = try await session.grok(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, "access-old")
    }

    func testAnExpiredGrokLoginWithoutANetworkIsUnreachable() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z")
        StubURLProtocol.failure = URLError(.notConnectedToInternet)
        stub { _ in (200, Data()) }
        let session = LoginSession()
        do {
            _ = try await session.grok(at: file, now: now, persistsRecovery: false)
            XCTFail("Expected an unreachable provider")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("access-old"), saved)
    }

    func testClaudeRenewalWritesTheNewTokensAndKeepsTheRest() async throws {
        let box = AuthBox(claudeJSON)
        stub { request in
            request.url?.host == "platform.claude.com"
                ? (500, Data())
                : (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8))
        }
        let session = LoginSession()
        let auth = try await session.claude(now: now, persistsRecovery: false, load: {
            try CredentialReaders.parseClaudeAuth(box.raw, account: "tester", service: "svc")
        }, save: { updated in
            box.raw = updated.rawJSON
        })
        XCTAssertEqual(auth.accessToken, "access-new")
        XCTAssertEqual(grantRequests().map { $0.url?.host }, ["platform.claude.com", "console.anthropic.com"])
        let request = try XCTUnwrap(grantRequests().last)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-app"), "cli")
        let body = bodyText(request)
        XCTAssertTrue(body.contains("\"grant_type\":\"refresh_token\""), body)
        XCTAssertTrue(body.contains(OAuthRefresh.claudeClientID), body)
        XCTAssertTrue(body.contains("refresh-old"), body)
        XCTAssertTrue(box.raw.contains("\"accessToken\": \"other\""), box.raw)
        XCTAssertTrue(box.raw.contains("access-new"), box.raw)
        XCTAssertTrue(box.raw.contains("refresh-new"), box.raw)
        XCTAssertTrue(box.raw.contains("\"note\": \"keep me\""), box.raw)
        XCTAssertTrue(box.raw.contains("1800028800000"), box.raw)
        XCTAssertFalse(box.raw.contains("access-old"), box.raw)
    }

    func testARejectedClaudeGrantDoesNotTryTheLegacyHost() async throws {
        let box = AuthBox(claudeJSON)
        let original = box.raw
        stub { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let session = LoginSession()
        do {
            _ = try await session.claude(now: now, persistsRecovery: false, load: {
                try CredentialReaders.parseClaudeAuth(box.raw, account: "tester", service: "svc")
            }, save: { updated in
                box.raw = updated.rawJSON
            })
            XCTFail("Expected an expired session")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.claude.expiredHint))
        }
        XCTAssertEqual(grantRequests().map { $0.url?.host }, ["platform.claude.com"])
        XCTAssertEqual(box.raw, original)
    }

    func testACurrentClaudeLoginIsReadWithoutAGrant() async throws {
        let raw = """
        {
          "mcpOAuth": {"accessToken": "other"},
          "claudeAiOauth": {"accessToken": "access-old", "refreshToken": "refresh-old", "expiresAt": 1800028800000},
          "note": "keep me"
        }
        """
        let box = AuthBox(raw)
        stub { _ in (500, Data()) }
        let session = LoginSession()
        let auth = try await session.claude(now: now, persistsRecovery: false, load: {
            try CredentialReaders.parseClaudeAuth(box.raw, account: "tester", service: "svc")
        }, save: { updated in
            box.raw = updated.rawJSON
        })
        XCTAssertEqual(auth.accessToken, "access-old")
        XCTAssertTrue(grantRequests().isEmpty)
        XCTAssertEqual(box.raw, raw)
    }

    func testPatchClaudeKeepsTheRestOfTheLogin() throws {
        let patched = try XCTUnwrap(OAuthRefresh.patchClaude(
            raw: claudeJSON,
            accessToken: "access-new",
            refreshToken: "refresh-new",
            expiresAtMs: 1_800_028_800_000,
            previousAccess: "access-old",
            previousRefresh: "refresh-old",
            previousExpiresAtMs: 1
        ))
        XCTAssertTrue(patched.contains("\"accessToken\": \"other\""), patched)
        XCTAssertTrue(patched.contains("access-new"), patched)
        XCTAssertTrue(patched.contains("refresh-new"), patched)
        XCTAssertTrue(patched.contains("\"note\": \"keep me\""), patched)
        XCTAssertTrue(patched.contains("1800028800000"), patched)
        XCTAssertFalse(patched.contains("access-old"), patched)
    }

    func testCodexRenewalLeavesTheAPIKeyAlone() async throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("auth.json")
        let expired = Self.jwt(expiringAt: now.addingTimeInterval(-3600))
        let raw = """
        {
          "OPENAI_API_KEY": "placeholder-key",
          "auth_mode": "chatgpt",
          "last_refresh": "2020-01-01T00:00:00.000000Z",
          "tokens": {
            "access_token": "\(expired)",
            "refresh_token": "refresh-old",
            "id_token": "id-old",
            "account_id": "acct"
          }
        }
        """
        try Data(raw.utf8).write(to: file)
        let fresh = Self.jwt(expiringAt: now.addingTimeInterval(86_400))
        stub { request in
            request.url?.host == "auth.openai.com"
                ? (500, Data())
                : (200, Data("""
                {"access_token":"\(fresh)","refresh_token":"refresh-new","id_token":"id-new","expires_in":86400}
                """.utf8))
        }
        let session = LoginSession()
        let auth = try await session.codex(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, fresh)
        XCTAssertEqual(auth.accountID, "acct")
        XCTAssertEqual(grantRequests().map { $0.url?.host }, ["auth.openai.com", "auth.api.openai.org"])
        let request = try XCTUnwrap(grantRequests().last)
        let body = bodyText(request)
        XCTAssertTrue(body.contains(OAuthRefresh.codexClientID), body)
        XCTAssertTrue(body.contains("refresh-old"), body)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"OPENAI_API_KEY\": \"placeholder-key\""), saved)
        XCTAssertTrue(saved.contains("\"account_id\": \"acct\""), saved)
        XCTAssertTrue(saved.contains("refresh-new"), saved)
        XCTAssertTrue(saved.contains("id-new"), saved)
        XCTAssertFalse(saved.contains("refresh-old"), saved)
        let expectedRefresh = OAuthRefresh.timestamp(like: "2020-01-01T00:00:00.000000Z", date: now)
        XCTAssertTrue(saved.contains(expectedRefresh), saved)
    }

    func testACurrentCodexTokenIsNotRenewed() async throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("auth.json")
        let access = Self.jwt(expiringAt: now.addingTimeInterval(2 * 3600))
        let raw = """
        {"OPENAI_API_KEY":"placeholder-key","tokens":{"access_token":"\(access)","refresh_token":"refresh-old","account_id":"acct"}}
        """
        try Data(raw.utf8).write(to: file)
        stub { _ in (500, Data()) }
        let session = LoginSession()
        let auth = try await session.codex(at: file, now: now, persistsRecovery: false)
        XCTAssertEqual(auth.accessToken, access)
        XCTAssertTrue(grantRequests().isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), raw)
    }

    func testOneGrokRenewalServesBothCallers() async throws {
        let file = try writeGrok(access: "access-old", refresh: "refresh-old", expires: "2020-01-01T00:00:00.000000Z")
        let hold = Hold()
        stub { _ in
            hold.mark()
            while hold.isHeld {
                Thread.sleep(forTimeInterval: 0.01)
            }
            return (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":21600}"#.utf8))
        }
        let session = LoginSession()
        let moment = now
        let first = Task { try await session.grok(at: file, now: moment, persistsRecovery: false) }
        for _ in 0..<100 {
            if hold.marked { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(hold.marked)
        let second = Task { try await session.grok(at: file, now: moment, persistsRecovery: false) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(grantRequests().count, 1)
        hold.release()
        let firstAuth = try await first.value
        let secondAuth = try await second.value
        XCTAssertEqual(firstAuth.accessToken, "access-new")
        XCTAssertEqual(secondAuth.accessToken, "access-new")
        XCTAssertEqual(grantRequests().count, 1)
    }

    private func writeGrok(access: String, refresh: String, expires: String, issuer: String? = nil, mode: NSNumber? = nil) throws -> URL {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("auth.json")
        try Data(grokJSON(access: access, refresh: refresh, expires: expires, issuer: issuer).utf8).write(to: file)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        return file
    }

    private func grokJSON(access: String, refresh: String, expires: String, issuer: String? = nil) -> String {
        let issuerLine = issuer.map { ",\n    \"oidc_issuer\": \"\($0)\"" } ?? ""
        return """
        {
          "https://auth.x.ai::account": {
            "key": "\(access)",
            "refresh_token": "\(refresh)",
            "expires_at": "\(expires)",
            "create_time": "2020-01-01T00:00:00.000000Z",
            "oidc_client_id": "client-1"\(issuerLine),
            "note": "keep me"
          }
        }
        """
    }

    private var claudeJSON: String {
        """
        {
          "mcpOAuth": {"accessToken": "other"},
          "claudeAiOauth": {"accessToken": "access-old", "refreshToken": "refresh-old", "expiresAt": 1},
          "note": "keep me"
        }
        """
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// Token posts from these tests. The running app shares the stub, so its usage calls are ignored,
    /// and a real refresh token is never answered with a grant.
    private func stub(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) {
        StubURLProtocol.handler = { request in
            if request.httpMethod == "POST", Self.tokenHost(request.url?.host), let data = request.httpBody {
                let body = String(decoding: data, as: UTF8.self)
                if !body.contains("refresh-old"), !body.contains("refresh%2Bold") {
                    return (503, Data())
                }
            }
            return handler(request)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
    }

    private func grantRequests() -> [URLRequest] {
        StubURLProtocol.requests.filter { request in
            let body = bodyText(request)
            return body.contains("refresh-old") || body.contains("refresh%2Bold")
        }
    }

    private static func tokenHost(_ host: String?) -> Bool {
        host == "auth.x.ai" || host == "platform.claude.com" || host == "console.anthropic.com"
            || host == "auth.openai.com" || host == "auth.api.openai.org"
    }

    private func bodyText(_ request: URLRequest) -> String {
        requestBody(request)
    }

    /// An unsigned JWT-shaped placeholder that carries only an expiry.
    private static func jwt(expiringAt date: Date) -> String {
        func part(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [part(#"{"alg":"none"}"#), part(#"{"exp":\#(Int(date.timeIntervalSince1970))}"#), "placeholder"].joined(separator: ".")
    }
}

private final class AuthBox: @unchecked Sendable {
    var raw: String
    init(_ raw: String) { self.raw = raw }
}

private func requestBody(_ request: URLRequest) -> String {
    if let body = request.httpBody {
        return String(decoding: body, as: UTF8.self)
    }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4096)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
}

private final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var held = true
    private var didMark = false

    var marked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didMark
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func mark() {
        lock.lock()
        didMark = true
        lock.unlock()
    }

    func release() {
        lock.lock()
        held = false
        lock.unlock()
    }
}
