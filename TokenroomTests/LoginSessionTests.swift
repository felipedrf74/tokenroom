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

    func testAmbiguousRefreshResponsesDoNotTryTheLegacyEndpoint() async {
        for status in [200, 400, 401, 403, 429, 500, 503] {
            StubURLProtocol.reset()
            stub { request in
                request.url?.host == "current.example.invalid"
                    ? (status, Data("{}".utf8))
                    : (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new"}"#.utf8))
            }
            let outcome = await OAuthRefresh.post(
                urls: [URL(string: "https://current.example.invalid/token")!, URL(string: "https://legacy.example.invalid/token")!],
                body: Data("refresh_token=refresh-old".utf8), contentType: "application/x-www-form-urlencoded", headers: [:]
            )
            guard case .unavailable = outcome else { return XCTFail("\(status) must not be retried with the old refresh token") }
            XCTAssertEqual(grantRequests().count, 1, "\(status) does not establish that rotation did not occur")
        }
    }

    func testARefreshTimeoutDoesNotTryTheLegacyEndpoint() async {
        stub { _ in (200, Data(#"{"access_token":"access-new"}"#.utf8)) }
        StubURLProtocol.failure = URLError(.timedOut)
        let outcome = await OAuthRefresh.post(
            urls: [URL(string: "https://current.example.invalid/token")!, URL(string: "https://legacy.example.invalid/token")!],
            body: Data("refresh_token=refresh-old".utf8), contentType: "application/x-www-form-urlencoded", headers: [:]
        )
        guard case .unavailable = outcome else { return XCTFail("A lost response must not send the old token to another endpoint") }
        XCTAssertEqual(grantRequests().count, 1)
    }

    func testAnExplicitlyRemovedRefreshRouteCanTryTheLegacyEndpoint() async {
        for status in [404, 405, 410] {
            StubURLProtocol.reset()
            stub { request in
                request.url?.host == "current.example.invalid"
                    ? (status, Data())
                    : (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new"}"#.utf8))
            }
            let outcome = await OAuthRefresh.post(
                urls: [URL(string: "https://current.example.invalid/token")!, URL(string: "https://legacy.example.invalid/token")!],
                body: Data("refresh_token=refresh-old".utf8), contentType: "application/x-www-form-urlencoded", headers: [:]
            )
            guard case .grant = outcome else { return XCTFail("\(status) rejects the route before a grant") }
            XCTAssertEqual(grantRequests().count, 2)
        }
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
                ? (404, Data())
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

    /// An item found without its account can't be updated in place: exchanging its refresh token
    /// would use it up while Claude Code keeps the old one.
    func testAClaudeLoginWithoutItsAccountIsNotExchanged() async throws {
        let box = AuthBox(claudeJSON)
        let original = box.raw
        stub { _ in (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8)) }
        let session = LoginSession()
        do {
            _ = try await session.claude(now: now, persistsRecovery: false, load: {
                try CredentialReaders.parseClaudeAuth(box.raw, account: "", service: "svc")
            }, save: { updated in
                box.raw = updated.rawJSON
            })
            XCTFail("Expected an expired session")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.claude.expiredHint))
        }
        XCTAssertTrue(grantRequests().isEmpty, "The refresh token isn't spent")
        XCTAssertEqual(box.raw, original)
    }

    /// The account is checked before the exchange. A read after it that can't look the account up
    /// (the `security` tool busy past its limit, say) doesn't stop the grant going into that item,
    /// now or, when the write fails, from the saved grant on the next try. Never under another name.
    func testAClaudeGrantGoesToTheItemCheckedBeforeTheExchange() async throws {
        let box = AuthBox(claudeJSON)
        let reads = Tally()
        let writes = Writes()
        stub { _ in (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8)) }
        let load: @Sendable () throws -> CredentialReaders.ClaudeAuth = {
            // The two reads before the exchange find the account; every read after it can't.
            let account = reads.next() <= 2 ? "other.name" : ""
            return try CredentialReaders.parseClaudeAuth(box.raw, account: account, service: "svc")
        }

        let session = LoginSession()
        let auth = try await session.claude(now: now, persistsRecovery: false, load: load, save: { updated in
            writes.append(updated)
            box.raw = updated.rawJSON
        })
        XCTAssertEqual(auth.accessToken, "access-new")
        XCTAssertEqual(writes.items, ["svc|other.name"])
        XCTAssertEqual(grantRequests().count, 1)

        // The same, when the write fails: the saved grant goes into that item on the next try.
        let retryBox = AuthBox(claudeJSON)
        let retryReads = Tally()
        let retryWrites = Writes()
        let failsOnce = Tally()
        StubURLProtocol.requests = []
        let retryLoad: @Sendable () throws -> CredentialReaders.ClaudeAuth = {
            let account = retryReads.next() <= 2 ? "other.name" : ""
            return try CredentialReaders.parseClaudeAuth(retryBox.raw, account: account, service: "svc")
        }
        let retrySave: @Sendable (CredentialReaders.ClaudeAuth) throws -> Void = { updated in
            if failsOnce.next() == 1 { throw ProviderError.unreachable }
            retryWrites.append(updated)
            retryBox.raw = updated.rawJSON
        }
        let retrying = LoginSession()
        do {
            _ = try await retrying.claude(now: now, persistsRecovery: false, load: retryLoad, save: retrySave)
            XCTFail("Expected the first write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        let recovered = try await retrying.claude(now: now, persistsRecovery: false, load: retryLoad, save: retrySave)
        XCTAssertEqual(recovered.accessToken, "access-new")
        XCTAssertEqual(retryWrites.items, ["svc|other.name"])
        XCTAssertFalse(retryWrites.items.contains("svc|\(NSUserName())"))
        XCTAssertEqual(grantRequests().count, 1, "The saved grant is written without exchanging again")
    }

    /// After a grant, the login changed under it (Claude Code renewed meanwhile) and its account
    /// can't be read: the second try isn't sent, as the first wouldn't have been.
    func testASecondClaudeTryChecksTheAccountAgain() async throws {
        let reads = Tally()
        let original = claudeJSON
        let replaced = #"{"claudeAiOauth":{"accessToken":"cli-access","refreshToken":"refresh-cli","expiresAt":1}}"#
        stub { _ in (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8)) }
        let session = LoginSession()
        do {
            _ = try await session.claude(now: now, persistsRecovery: false, load: {
                reads.next() <= 2
                    ? try CredentialReaders.parseClaudeAuth(original, account: "other.name", service: "svc")
                    : try CredentialReaders.parseClaudeAuth(replaced, account: "", service: "svc")
            }, save: { _ in XCTFail("Nothing is written to a login whose account isn't known") })
            XCTFail("Expected an expired session")
        } catch {
            XCTAssertEqual(error as? ProviderError, .expired(Provider.claude.expiredHint))
        }
        XCTAssertEqual(grantRequests().count, 1)
        let secondTries = StubURLProtocol.requests.filter { requestBody($0).contains("refresh-cli") }
        XCTAssertTrue(secondTries.isEmpty, "refresh-cli is never sent")
    }

    /// Claude Code can keep more than one item. A grant for one stays saved while another is
    /// read first, goes into its own item, and the refresh token it replaced is never sent again.
    func testAClaudeGrantStaysWithItsItemWhenAnotherIsReadFirst() async throws {
        let items = ClaudeItems([
            "svc-a|acct-a": claudeJSON,
            "svc-b|acct-b": #"{"claudeAiOauth":{"accessToken":"b-access","refreshToken":"refresh-b","expiresAt":1800100000000}}"#,
        ], first: "svc-a|acct-a")
        let failsOnce = Tally()
        stub { _ in (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8)) }
        let session = LoginSession()
        let moment = now
        let renew: @Sendable () async throws -> CredentialReaders.ClaudeAuth = {
            try await session.claude(now: moment, persistsRecovery: false, load: {
                try items.first()
            }, loadItem: { service, account in
                try items.item(service: service, account: account)
            }, save: { updated in
                if failsOnce.next() == 1 { throw ProviderError.unreachable }
                items.write(updated)
            })
        }

        // A is read first and exchanged, and its write fails: the grant is kept.
        do {
            _ = try await renew()
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        // B is read first now. The grant still goes into A.
        items.setFirst("svc-b|acct-b")
        _ = try await renew()
        XCTAssertTrue(items.raw("svc-a|acct-a").contains("access-new"), items.raw("svc-a|acct-a"))
        XCTAssertTrue(items.raw("svc-a|acct-a").contains("refresh-new"))
        XCTAssertTrue(items.raw("svc-b|acct-b").contains("refresh-b"), "B is left as it was")
        // A is read first again, and is current: nothing is sent.
        items.setFirst("svc-a|acct-a")
        let renewed = try await renew()
        XCTAssertEqual(renewed.accessToken, "access-new")
        XCTAssertEqual(grantRequests().count, 1, "refresh-old is sent once")
    }

    /// A grant waits while its own item can't be read just now. An item that's there but won't be
    /// usable (here its secret is no longer a login) can't take the grant: it mustn't hold off
    /// renewing the login read first for good, and the refresh token it replaced is never sent again.
    func testAClaudeGrantDoesNotHoldOffAnotherLoginWhenItsItemWontBeUsable() async throws {
        let items = ClaudeItems([
            "svc-a|acct-a": claudeJSON,
            // Within a minute of expiry: it can't be used as it is.
            "svc-b|acct-b": #"{"claudeAiOauth":{"accessToken":"b-access","refreshToken":"refresh-old-b","expiresAt":1800000030000}}"#,
        ], first: "svc-a|acct-a")
        let notNow = Toggle()
        let failsOnce = Tally()
        stub { request in
            requestBody(request).contains("refresh-old-b")
                ? (200, Data(#"{"access_token":"b-new","refresh_token":"refresh-new-b","expires_in":28800}"#.utf8))
                : (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8))
        }
        let session = LoginSession()
        let moment = now
        let renew: @Sendable () async throws -> CredentialReaders.ClaudeAuth = {
            try await session.claude(now: moment, persistsRecovery: false, load: {
                try items.first()
            }, loadItem: { service, account in
                // The production read of one item, with the Keychain and the `security` tool faked.
                try CredentialReaders.claudeItem(
                    service: service,
                    account: account,
                    exists: { _, _ in true },
                    access: { _ in CredentialReaders.ClaudeKeyAccess(partitions: ["apple-tool:"], hasPartitionList: true) },
                    security: { service, account in
                        notNow.isOn ? .unavailable : .value(items.raw("\(service)|\(account ?? "")"))
                    }
                )
            }, save: { updated in
                if failsOnce.next() == 1 { throw ProviderError.unreachable }
                items.write(updated)
            })
        }
        func exchanged(_ refresh: String) -> Int {
            StubURLProtocol.requests.filter { requestBody($0).contains("\"refresh_token\":\"\(refresh)\"") }.count
        }

        // A is exchanged and its write fails: the grant is kept.
        do {
            _ = try await renew()
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        // B is read first, and A can't be read just now: the grant waits, and B isn't exchanged.
        items.setFirst("svc-b|acct-b")
        notNow.set(true)
        do {
            _ = try await renew()
            XCTFail("Expected to wait for A")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        XCTAssertEqual(exchanged("refresh-old-b"), 0)

        // A can be read, but Claude Code signed out of it: its secret isn't a login. B is renewed.
        notNow.set(false)
        items.set("svc-a|acct-a", raw: #"{"mcpOAuth":{"accessToken":"other"}}"#)
        let renewed = try await renew()
        XCTAssertEqual(renewed.accessToken, "b-new")
        XCTAssertTrue(items.raw("svc-b|acct-b").contains("refresh-new-b"), items.raw("svc-b|acct-b"))
        XCTAssertEqual(items.raw("svc-a|acct-a"), #"{"mcpOAuth":{"accessToken":"other"}}"#, "A is left as it is")
        XCTAssertEqual(exchanged("refresh-old-b"), 1)
        XCTAssertEqual(exchanged("refresh-old"), 1, "refresh-old is sent once")
    }

    /// An access list that stops trusting the `security` tool can trust it again (Keychain Access,
    /// or Claude Code's Always Allow) with the spent refresh token still in the item. Until Claude
    /// Code would have refreshed that item itself, the grant is kept and other logins wait; after
    /// that (the grant's own access-token expiry, plus the slack), it's dropped and they're renewed.
    func testAClaudeGrantWaitsForAnUntrustedItemOnlyWhileItCanStillRescueIt() async throws {
        let items = ClaudeItems([
            "svc-a|acct-a": claudeJSON,
            "svc-b|acct-b": #"{"claudeAiOauth":{"accessToken":"b-access","refreshToken":"refresh-old-b","expiresAt":1}}"#,
        ], first: "svc-a|acct-a")
        let untrusted = Toggle()
        let renew = untrustedItemRenewal(items: items, untrusted: untrusted)

        do {
            _ = try await renew(now)
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        // A's access list is reset, and B is read first. The grant (its access token lasts
        // 28800 seconds) can still rescue A: B waits.
        untrusted.set(true)
        items.setFirst("svc-b|acct-b")
        for offset: TimeInterval in [3600, 28800 + 30] {
            do {
                _ = try await renew(now.addingTimeInterval(offset))
                XCTFail("Expected B to wait at +\(offset) s")
            } catch {
                XCTAssertEqual(error as? ProviderError, .unreachable)
            }
        }
        XCTAssertEqual(exchangeCount("refresh-old-b"), 0)

        // Past it, plus the slack: the grant is dropped and B is renewed.
        let renewed = try await renew(now.addingTimeInterval(28800 + 61))
        XCTAssertEqual(renewed.accessToken, "b-new")
        XCTAssertTrue(items.raw("svc-b|acct-b").contains("refresh-new-b"), items.raw("svc-b|acct-b"))
        XCTAssertEqual(exchangeCount("refresh-old-b"), 1)
        XCTAssertEqual(exchangeCount("refresh-old"), 1, "refresh-old is sent once")
    }

    /// The case a kept grant is for: the item trusts the tool again with the spent refresh token
    /// still in it, and the grant goes into it.
    func testAClaudeGrantIsWrittenBackWhenItsItemTrustsTheToolAgain() async throws {
        let items = ClaudeItems([
            "svc-a|acct-a": claudeJSON,
            "svc-b|acct-b": #"{"claudeAiOauth":{"accessToken":"b-access","refreshToken":"refresh-old-b","expiresAt":1}}"#,
        ], first: "svc-a|acct-a")
        let untrusted = Toggle()
        let renew = untrustedItemRenewal(items: items, untrusted: untrusted)

        do {
            _ = try await renew(now)
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        untrusted.set(true)
        items.setFirst("svc-b|acct-b")
        do {
            _ = try await renew(now.addingTimeInterval(3600))
            XCTFail("Expected B to wait")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        // Always Allow puts the tool back on A's access list.
        untrusted.set(false)
        _ = try await renew(now.addingTimeInterval(7200))
        XCTAssertTrue(items.raw("svc-a|acct-a").contains("access-new"), items.raw("svc-a|acct-a"))
        XCTAssertTrue(items.raw("svc-a|acct-a").contains("refresh-new"))
        XCTAssertEqual(exchangeCount("refresh-old"), 1, "refresh-old is sent once")
        XCTAssertEqual(exchangeCount("refresh-old-b"), 0, "B wasn't exchanged while the grant could rescue A")
    }

    /// A grant whose item won't be usable (here its access list stopped trusting the `security`
    /// tool long enough ago) is still kept while the login read first has the refresh token it
    /// replaced: that token is spent, and exchanging it would send it again. Once that login moves
    /// on, it's renewed.
    func testAClaudeGrantIsKeptWhileTheLoginReadFirstHasTheTokenItReplaced() async throws {
        let items = ClaudeItems([
            "svc-a|acct-a": claudeJSON,
            // A copy of A's login.
            "svc-b|acct-b": #"{"claudeAiOauth":{"accessToken":"access-old","refreshToken":"refresh-old","expiresAt":1}}"#,
        ], first: "svc-a|acct-a")
        let untrusted = Toggle()
        let renew = untrustedItemRenewal(items: items, untrusted: untrusted)
        // Past the time the grant could rescue its item: its access token lasts 28800 seconds.
        let later = now.addingTimeInterval(28800 + 61)

        do {
            _ = try await renew(now)
            XCTFail("Expected the write to fail")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        // A no longer trusts the tool, and B, read first, still has the spent refresh token.
        untrusted.set(true)
        items.setFirst("svc-b|acct-b")
        do {
            _ = try await renew(later)
            XCTFail("Expected B to be left alone")
        } catch {
            XCTAssertEqual(error as? ProviderError, .unreachable)
        }
        XCTAssertEqual(exchangeCount("refresh-old"), 1, "refresh-old is sent once")
        XCTAssertTrue(items.raw("svc-b|acct-b").contains("\"refresh-old\""), "Nothing is written into B")

        // Claude Code signed in to B again: the grant is dropped, and B is renewed.
        items.set("svc-b|acct-b", raw: #"{"claudeAiOauth":{"accessToken":"b-access","refreshToken":"refresh-old-b","expiresAt":1}}"#)
        let renewed = try await renew(later)
        XCTAssertEqual(renewed.accessToken, "b-new")
        XCTAssertEqual(exchangeCount("refresh-old"), 1)
        XCTAssertEqual(exchangeCount("refresh-old-b"), 1)
    }

    /// Renews through the production read of one item, with the Keychain and the `security` tool
    /// faked: `svc-a`'s access list is read and doesn't trust the tool while `untrusted` is on.
    /// A's first write fails, and the token posts answer A's and B's refresh tokens.
    private func untrustedItemRenewal(
        items: ClaudeItems,
        untrusted: Toggle
    ) -> @Sendable (Date) async throws -> CredentialReaders.ClaudeAuth {
        let failsOnce = Tally()
        stub { request in
            requestBody(request).contains("refresh-old-b")
                ? (200, Data(#"{"access_token":"b-new","refresh_token":"refresh-new-b","expires_in":28800}"#.utf8))
                : (200, Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800}"#.utf8))
        }
        let session = LoginSession()
        return { moment in
            try await session.claude(now: moment, persistsRecovery: false, load: {
                try items.first()
            }, loadItem: { service, account in
                try CredentialReaders.claudeItem(
                    service: service,
                    account: account,
                    exists: { _, _ in true },
                    access: { service in
                        untrusted.isOn && service == "svc-a"
                            ? CredentialReaders.ClaudeKeyAccess(partitions: ["apple:"], hasPartitionList: true, wasRead: true)
                            : CredentialReaders.ClaudeKeyAccess(partitions: ["apple-tool:"], hasPartitionList: true, wasRead: true)
                    },
                    security: { service, account in .value(items.raw("\(service)|\(account ?? "")")) }
                )
            }, save: { updated in
                if failsOnce.next() == 1 { throw ProviderError.unreachable }
                items.write(updated)
            })
        }
    }

    /// Token posts that sent this refresh token.
    private func exchangeCount(_ refresh: String) -> Int {
        StubURLProtocol.requests.filter { requestBody($0).contains("\"refresh_token\":\"\(refresh)\"") }.count
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

    /// A login the in-place edit can't patch (here, no expiry to replace) is rewritten whole, and
    /// compactly, the way Claude Code writes its Keychain item.
    func testAClaudeLoginRewrittenWholeStaysCompact() throws {
        let raw = #"{"mcpOAuth":{"accessToken":"other"},"claudeAiOauth":{"accessToken":"access-old","refreshToken":"refresh-old"},"note":"keep me"}"#
        let patched = try XCTUnwrap(OAuthRefresh.patchClaude(
            raw: raw,
            accessToken: "access-new",
            refreshToken: "refresh-new",
            expiresAtMs: 1_800_028_800_000,
            previousAccess: "access-old",
            previousRefresh: "refresh-old",
            previousExpiresAtMs: nil
        ))
        XCTAssertFalse(patched.contains("\n"), patched)
        XCTAssertFalse(patched.contains("\": "), patched)
        let auth = try CredentialReaders.parseClaudeAuth(patched, account: "tester", service: "svc")
        XCTAssertEqual(auth.accessToken, "access-new")
        XCTAssertEqual(auth.refreshToken, "refresh-new")
        XCTAssertEqual(auth.expiresAtMs, 1_800_028_800_000)
        XCTAssertTrue(patched.contains(#""note":"keep me""#), patched)
        XCTAssertTrue(patched.contains(#""mcpOAuth":{"accessToken":"other"}"#), patched)
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
                ? (404, Data())
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

/// Counts calls: `next()` returns 1 the first time.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Claude Code's Keychain items, by `service|account`, and which one a read finds first.
private final class ClaudeItems: @unchecked Sendable {
    private let lock = NSLock()
    private var raws: [String: String]
    private var firstKey: String

    init(_ raws: [String: String], first: String) {
        self.raws = raws
        firstKey = first
    }

    func setFirst(_ key: String) {
        lock.withLock { firstKey = key }
    }

    func raw(_ key: String) -> String {
        lock.withLock { raws[key] ?? "" }
    }

    func first() throws -> CredentialReaders.ClaudeAuth {
        let (key, raw) = lock.withLock { (firstKey, raws[firstKey] ?? "") }
        let parts = key.split(separator: "|").map(String.init)
        return try CredentialReaders.parseClaudeAuth(raw, account: parts[1], service: parts[0])
    }

    func item(service: String, account: String) throws -> CredentialReaders.ClaudeAuth? {
        guard let raw = lock.withLock({ raws["\(service)|\(account)"] }) else { return nil }
        return try CredentialReaders.parseClaudeAuth(raw, account: account, service: service)
    }

    func write(_ auth: CredentialReaders.ClaudeAuth) {
        lock.withLock { raws["\(auth.service)|\(auth.account)"] = auth.rawJSON }
    }

    /// What another writer (Claude Code) leaves in an item.
    func set(_ key: String, raw: String) {
        lock.withLock { raws[key] = raw }
    }
}

private final class Toggle: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isOn: Bool { lock.withLock { on } }

    func set(_ value: Bool) {
        lock.withLock { on = value }
    }
}

/// Where each write went, as `service|account`.
private final class Writes: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []

    var items: [String] { lock.withLock { written } }

    func append(_ auth: CredentialReaders.ClaudeAuth) {
        lock.withLock { written.append("\(auth.service)|\(auth.account)") }
    }
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
