import Foundation
import XCTest
@testable import Tokenroom

final class PhoneSignInTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { Self.now }

    private static func http(_ status: Int, _ url: URL = URL(string: "https://example.invalid")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    private static func form(_ request: URLRequest) -> [String: String] {
        let text = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            fields[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return fields
    }

    /// A JWT with these claims and no signature check: the shape vendors send.
    private static func jwt(_ claims: [String: Any]) -> String {
        let payload = PhoneSignIn.base64URL(Self.json(claims))
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }

    // MARK: PKCE

    func testTheChallengeIsS256OfTheVerifier() {
        // RFC 7636, appendix B.
        let pkce = PhoneSignIn.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomTokensAreURLSafeAndLongEnough() {
        let a = PhoneSignIn.randomToken(), b = PhoneSignIn.randomToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 43)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    // MARK: Claude

    func testClaudesSignInPageAsksOnlyToReadTheProfile() throws {
        let pkce = PhoneSignIn.PKCE(verifier: "verifier", state: "state-1")
        let url = PhoneSignIn.claudeAuthorizeURL(pkce)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(items["scope"], "user:profile")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code"], "true")
        XCTAssertEqual(items["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertNil(items["code_verifier"], "The verifier never leaves the iPhone before the exchange")
    }

    func testAPastedClaudeCodeIsReadInEveryShapeThePageGives() {
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "  abc123#state-1\n", state: "state-1"), .code("abc123"))
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "abc123", state: "state-1"), .code("abc123"))
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "abc123#state-2", state: "state-1"), .otherSignIn)
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "https://platform.claude.com/oauth/code/callback?code=abc123&state=state-1", state: "state-1"), .code("abc123"))
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "https://platform.claude.com/oauth/code/callback?code=abc123&state=nope", state: "state-1"), .otherSignIn)
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "   ", state: "state-1"), .empty)
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "#state-1", state: "state-1"), .empty)
        XCTAssertEqual(PhoneSignIn.claudeCode(fromPasted: "two words", state: "state-1"), .empty)
    }

    func testClaudesExchangeSendsTheVerifierAndState() {
        let pkce = PhoneSignIn.PKCE(verifier: "verifier", state: "state-1")
        let request = PhoneSignIn.claudeExchangeRequest(code: "abc123", pkce: pkce)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let fields = Self.body(request)
        XCTAssertEqual(fields["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(fields["code"] as? String, "abc123")
        XCTAssertEqual(fields["code_verifier"] as? String, "verifier")
        XCTAssertEqual(fields["state"] as? String, "state-1")
        XCTAssertEqual(fields["redirect_uri"] as? String, PhoneSignIn.Claude.redirectURL.absoluteString)
        XCTAssertNil(fields["client_secret"], "A public client: no secret")
    }

    func testClaudeFinishesWithASessionThatHoldsNoIdentity() async throws {
        let sent = LockedBox<[URLRequest]>([])
        let client = PhoneSignInClient(send: { request in
            sent.value.append(request)
            let answer: [String: Any] = [
                "access_token": "sk-ant-oat-TRACCESS", "refresh_token": "sk-ant-ort-TRREFRESH", "expires_in": 28_800,
                "account": ["uuid": "acct-uuid-TR", "email_address": "person@example.com"],
                "organization": ["uuid": "org-uuid-TR", "name": "Person's Org"],
            ]
            return (Self.json(answer), Self.http(200))
        }, sleep: { _ in })
        let pkce = PhoneSignIn.PKCE(verifier: "verifier", state: "state-1")
        let session = try await client.finishClaude(pasted: "abc123#state-1", pkce: pkce, now: now)
        XCTAssertEqual(session.accessToken, "sk-ant-oat-TRACCESS")
        XCTAssertEqual(session.refreshToken, "sk-ant-ort-TRREFRESH")
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(28_800))
        XCTAssertEqual(session.clientID, PhoneSignIn.Claude.clientID)
        let stored = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
        for identity in ["person@example.com", "acct-uuid-TR", "org-uuid-TR", "Person's Org"] {
            XCTAssertFalse(stored.contains(identity), identity)
        }
        XCTAssertEqual(sent.value.count, 1)
        // A code from another sign-in is refused before anything is sent.
        await XCTAssertThrowsFailure(.otherSignIn) { _ = try await client.finishClaude(pasted: "abc#other", pkce: pkce, now: Self.now) }
        XCTAssertEqual(sent.value.count, 1)
    }

    func testASignInWithoutARefreshTokenIsntKept() async {
        let client = PhoneSignInClient(send: { _ in (Self.json(["access_token": "only-access"]), Self.http(200)) }, sleep: { _ in })
        await XCTAssertThrowsFailure(.noRenewal) {
            _ = try await client.finishClaude(pasted: "abc", pkce: .random(), now: Self.now)
        }
        let refused = PhoneSignInClient(send: { _ in (Self.json(["error": "invalid_grant"]), Self.http(400)) }, sleep: { _ in })
        await XCTAssertThrowsFailure(.refused) {
            _ = try await refused.finishClaude(pasted: "abc", pkce: .random(), now: Self.now)
        }
    }

    // MARK: Device codes

    func testCodexsCodeIsReadAndShownOnOpenAIsPage() throws {
        let data = Self.json(["device_auth_id": "dev-1", "user_code": "ABCD-1234", "interval": "5"])
        let code = try XCTUnwrap(PhoneSignIn.deviceCode(from: data, provider: .openai, now: now))
        XCTAssertEqual(code.userCode, "ABCD-1234")
        XCTAssertEqual(code.interval, 5)
        XCTAssertEqual(code.verificationURL.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(code.expiresAt, now.addingTimeInterval(15 * 60))
        let dated = Self.json(["device_auth_id": "dev-1", "user_code": "ABCD-1234", "interval": "5", "expires_at": "2027-01-15T08:10:00Z"])
        XCTAssertEqual(PhoneSignIn.deviceCode(from: dated, provider: .openai, now: now)?.expiresAt, JSONFlex.parseISO("2027-01-15T08:10:00Z"))
        // The older field name still reads.
        XCTAssertNotNil(PhoneSignIn.deviceCode(from: Self.json(["device_auth_id": "dev-1", "usercode": "ABCD-1234"]), provider: .openai, now: now))
        XCTAssertNil(PhoneSignIn.deviceCode(from: Self.json(["user_code": "ABCD-1234"]), provider: .openai, now: now))
        XCTAssertNil(PhoneSignIn.deviceCode(from: Self.json(["device_auth_id": "dev-1", "user_code": "AB\u{1B}[0m"]), provider: .openai, now: now))
    }

    func testGroksCodeMustOpenAnXAIPage() throws {
        let good = Self.json(["device_code": "dc-1", "user_code": "WXYZ-9876", "verification_uri": "https://accounts.x.ai/oauth2/device",
                         "verification_uri_complete": "https://accounts.x.ai/oauth2/device?user_code=WXYZ-9876", "expires_in": 60, "interval": 5])
        let code = try XCTUnwrap(PhoneSignIn.deviceCode(from: good, provider: .grok, now: now))
        XCTAssertEqual(code.verificationURL.absoluteString, "https://accounts.x.ai/oauth2/device?user_code=WXYZ-9876")
        XCTAssertEqual(code.expiresAt, now.addingTimeInterval(10 * 60), "A short lifetime gets RFC 8628's floor")
        let elsewhere = Self.json(["device_code": "dc-1", "user_code": "WXYZ-9876", "verification_uri": "https://x.ai.example.com/device"])
        XCTAssertNil(PhoneSignIn.deviceCode(from: elsewhere, provider: .grok, now: now))
        let plain = Self.json(["device_code": "dc-1", "user_code": "WXYZ-9876", "verification_uri": "http://accounts.x.ai/device"])
        XCTAssertNil(PhoneSignIn.deviceCode(from: plain, provider: .grok, now: now))
    }

    func testGrokAsksForTheBuildProxyAndARefreshTokenOnly() throws {
        let request = try XCTUnwrap(PhoneSignIn.deviceCodeRequest(for: .grok))
        let fields = Self.form(request)
        XCTAssertEqual(fields["client_id"], PhoneSignIn.Grok.clientID)
        XCTAssertEqual(fields["scope"], "openid offline_access grok-cli:access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(PhoneSignIn.deviceCodeRequest(for: .claude), "Claude pastes a code instead")
        XCTAssertNil(PhoneSignIn.deviceCodeRequest(for: .cursor), "Cursor's sign-in is made on the iPhone")
    }

    func testPollAnswers() {
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .openai, status: 403, data: Data()), .pending)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .openai, status: 404, data: Data()), .pending)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .openai, status: 500, data: Data()), .failed)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .openai, status: 200, data: Self.json(["authorization_code": "ac", "code_verifier": "cv", "code_challenge": "cc"])),
                       .authorized(code: "ac", verifier: "cv"))
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .openai, status: 200, data: Self.json(["authorization_code": "ac"])), .failed)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grok, status: 400, data: Self.json(["error": "authorization_pending"])), .pending)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grok, status: 400, data: Self.json(["error": "slow_down"])), .slowDown)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grok, status: 400, data: Self.json(["error": "access_denied"])), .denied)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grok, status: 400, data: Self.json(["error": "expired_token"])), .expired)
        let tokens = Self.json(["access_token": "a", "refresh_token": "r"])
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grok, status: 200, data: tokens), .granted(tokens))
    }

    func testCodexWaitsForApprovalThenExchangesTheCode() async throws {
        let sleeps = LockedBox<[TimeInterval]>([])
        let polls = Counter()
        let exchanged = LockedBox<URLRequest?>(nil)
        let access = Self.jwt(["exp": 1_800_003_600, "https://api.openai.com/auth": ["chatgpt_account_id": "ws-TR"]])
        let client = PhoneSignInClient(send: { request in
            if request.url == PhoneSignIn.Codex.pollURL {
                polls.increment()
                return polls.count < 3 ? (Data(), Self.http(403)) : (Self.json(["authorization_code": "ac", "code_verifier": "cv"]), Self.http(200))
            }
            exchanged.value = request
            return (Self.json(["id_token": "idt", "access_token": access, "refresh_token": "rt"]), Self.http(200))
        }, sleep: { sleeps.value.append($0) })
        let code = PhoneSignIn.DeviceCode(provider: .openai, userCode: "ABCD-1234", verificationURL: PhoneSignIn.Codex.verificationURL,
                                          interval: 5, expiresAt: now.addingTimeInterval(900), handle: "dev-1")
        let session = try await client.waitForApproval(code, clock: { Self.now })
        XCTAssertEqual(polls.count, 3)
        XCTAssertEqual(sleeps.value, [5, 5, 5])
        XCTAssertEqual(session.refreshToken, "rt")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_800_003_600), "From the access token's exp when the answer has none")
        let fields = Self.form(try XCTUnwrap(exchanged.value))
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["code"], "ac")
        XCTAssertEqual(fields["code_verifier"], "cv")
        XCTAssertEqual(fields["redirect_uri"], "https://auth.openai.com/deviceauth/callback")
        XCTAssertEqual(fields["client_id"], PhoneSignIn.Codex.clientID)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("idt"), "The id token isn't kept")
    }

    func testGrokSlowsDownWhenAskedAndStopsAtExpiry() async throws {
        let sleeps = LockedBox<[TimeInterval]>([])
        let answers = LockedBox<[String]>(["slow_down", "authorization_pending"])
        let client = PhoneSignInClient(send: { _ in
            if let next = answers.value.first {
                answers.value.removeFirst()
                return (Self.json(["error": next]), Self.http(400))
            }
            return (Self.json(["access_token": "a", "refresh_token": "r", "expires_in": 21_600]), Self.http(200))
        }, sleep: { sleeps.value.append($0) })
        let code = PhoneSignIn.DeviceCode(provider: .grok, userCode: "WXYZ-9876", verificationURL: URL(string: "https://accounts.x.ai/oauth2/device")!,
                                          interval: 5, expiresAt: now.addingTimeInterval(600), handle: "dc-1")
        let session = try await client.waitForApproval(code, clock: { Self.now })
        XCTAssertEqual(sleeps.value, [5, 10, 10])
        XCTAssertEqual(session.tokenURL, PhoneSignIn.Grok.tokenURL)
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(21_600))

        let late = Date(timeIntervalSince1970: 1_900_000_000)
        await XCTAssertThrowsFailure(.expired) { _ = try await client.waitForApproval(code, clock: { late }) }
        let denied = PhoneSignInClient(send: { _ in (Self.json(["error": "access_denied"]), Self.http(400)) }, sleep: { _ in })
        await XCTAssertThrowsFailure(.denied) { _ = try await denied.waitForApproval(code, clock: { Self.now }) }
    }

    func testCodexSaysWhenItIsntOfferingACodeSignIn() async {
        let client = PhoneSignInClient(send: { _ in (Data(), Self.http(404)) }, sleep: { _ in })
        await XCTAssertThrowsFailure(.notOffered) { _ = try await client.startDeviceCode(for: .openai, now: Self.now) }
    }

    // MARK: Renewal

    func testARenewalWithoutARefreshTokenKeepsTheOneSent() {
        let previous = PhoneSession(accessToken: "old", refreshToken: "keep-me", expiresAt: now, tokenURL: PhoneSignIn.Grok.tokenURL, clientID: PhoneSignIn.Grok.clientID)
        let grant = PhoneSignIn.refreshAnswer(provider: .grok, status: 200, data: Self.json(["access_token": "new", "expires_in": 3600]), previous: previous, now: now)
        guard case .granted(let session) = grant else { return XCTFail("\(grant)") }
        XCTAssertEqual(session.accessToken, "new")
        XCTAssertEqual(session.refreshToken, "keep-me")
        XCTAssertEqual(session.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(PhoneSignIn.refreshAnswer(provider: .grok, status: 400, data: Self.json(["error": "invalid_grant"]), previous: previous, now: now), .rejected)
        XCTAssertEqual(PhoneSignIn.refreshAnswer(provider: .grok, status: 503, data: Data(), previous: previous, now: now), .unavailable, "Unclear: never resent")
        // Any answer means the request reached the host, which may have rotated the token.
        for status in [400, 401, 403, 408, 429] {
            XCTAssertEqual(PhoneSignIn.refreshAnswer(provider: .grok, status: status, data: Data(), previous: previous, now: now), .unavailable, "\(status)")
        }
    }

    func testClaudeTriesItsSecondHostOnlyWhenTheFirstNeverGotTheRequest() async {
        let hosts = LockedBox<[String]>([])
        let client = PhoneSignInClient(send: { request in
            hosts.value.append(request.url?.host ?? "")
            if request.url?.host == "platform.claude.com" { throw URLError(.cannotConnectToHost) }
            return (Self.json(["access_token": "new", "refresh_token": "rotated"]), Self.http(200))
        }, sleep: { _ in })
        let session = PhoneSession(accessToken: "old", refreshToken: "rt", expiresAt: now, tokenURL: PhoneSignIn.Claude.tokenURLs[0], clientID: PhoneSignIn.Claude.clientID)
        let grant = await client.renew(.claude, session, now: now)
        XCTAssertEqual(hosts.value, ["platform.claude.com", "console.anthropic.com"])
        guard case .granted(let renewed) = grant else { return XCTFail("\(grant)") }
        XCTAssertEqual(renewed.refreshToken, "rotated")
        // A host that may have got the request (it answered 503, or timed out) isn't followed by
        // another: the refresh token might have rotated there.
        for timesOut in [false, true] {
            hosts.value = []
            let unclear = PhoneSignInClient(send: { request in
                hosts.value.append(request.url?.host ?? "")
                if timesOut { throw URLError(.timedOut) }
                return (Data(), Self.http(503))
            }, sleep: { _ in })
            let outcome = await unclear.renew(.claude, session, now: now)
            XCTAssertEqual(outcome, .unavailable)
            XCTAssertEqual(hosts.value, ["platform.claude.com"])
        }
        let offline = PhoneSignInClient(send: { _ in throw URLError(.notConnectedToInternet) }, sleep: { _ in })
        let notSent = await offline.renew(.claude, session, now: now)
        XCTAssertEqual(notSent, .notDispatched)
        let requests = PhoneSignIn.refreshRequests(for: session, provider: .claude)
        XCTAssertEqual(Self.body(requests[0])["grant_type"] as? String, "refresh_token")
        let grok = PhoneSignIn.refreshRequests(for: PhoneSession(accessToken: "a", refreshToken: "r", expiresAt: nil, tokenURL: PhoneSignIn.Grok.tokenURL, clientID: "c"), provider: .grok)
        XCTAssertEqual(Self.form(grok[0]), ["grant_type": "refresh_token", "refresh_token": "r", "client_id": "c"])
    }

    // MARK: Cursor and Grok Bot

    func testCursorsSignInPageCarriesOnlyTheChallenge() throws {
        let code = PhoneSignIn.cursorLogin(now: now)
        let items = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: code.verificationURL, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(code.verificationURL.host, "cursor.com")
        XCTAssertEqual(code.verificationURL.path, "/loginDeepControl")
        XCTAssertEqual(items["challenge"], PhoneSignIn.PKCE(verifier: code.verifier, state: "").challenge)
        XCTAssertEqual(items["uuid"], code.handle)
        XCTAssertEqual(items["mode"], "login")
        XCTAssertNil(items["verifier"], "The verifier only goes with polling, from this iPhone")
        XCTAssertTrue(code.userCode.isEmpty, "Nothing to type: the person just signs in")
        XCTAssertEqual(code.expiresAt, now.addingTimeInterval(PhoneSignIn.Cursor.loginLifetime))
        let poll = PhoneSignIn.pollRequest(code)
        XCTAssertEqual(poll.httpMethod, "GET")
        let pollItems = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: try XCTUnwrap(poll.url), resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(pollItems, ["uuid": code.handle, "verifier": code.verifier])
        XCTAssertNotEqual(PhoneSignIn.cursorLogin(now: now).handle, code.handle)
    }

    func testCursorsPollAnswers() {
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .cursor, status: 404, data: Data()), .pending)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .cursor, status: 200, data: Self.json(["authId": "auth0|x"])), .pending)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .cursor, status: 403, data: Self.json(["error": "policy"])), .denied)
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .grokBot, status: 500, data: Data()), .failed)
        let tokens = Self.json(["accessToken": "a", "refreshToken": "r", "authId": "auth0|person"])
        XCTAssertEqual(PhoneSignIn.pollAnswer(provider: .cursor, status: 200, data: tokens), .granted(tokens))
    }

    func testOneCursorSignInCoversGrokBot() async throws {
        XCTAssertEqual(PhoneSignIn.sessionOwner(for: .grokBot), .cursor)
        XCTAssertEqual(PhoneSignIn.sessionOwner(for: .cursor), .cursor)
        XCTAssertEqual(PhoneSignIn.sharingSession(with: .grokBot), [.cursor, .grokBot])
        XCTAssertEqual(PhoneSignIn.sharingSession(with: .claude), [.claude])
        let access = Self.jwt(["exp": 1_805_000_000, "sub": "auth0|person"])
        let client = PhoneSignInClient(send: { _ in (Self.json(["accessToken": access, "refreshToken": "r", "authId": "auth0|person"]), Self.http(200)) }, sleep: { _ in })
        let code = try await client.startDeviceCode(for: .grokBot, now: now)
        XCTAssertEqual(code.provider, .cursor, "Grok Bot signs in with Cursor")
        let session = try await client.waitForApproval(code, clock: { Self.now })
        XCTAssertEqual(session.clientID, PhoneSignIn.Cursor.clientID)
        XCTAssertEqual(session.tokenURL, PhoneSignIn.Cursor.tokenURL)
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_805_000_000))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("person\"") , "The account id isn't kept")
    }

    func testCursorRenewsWithItsAccessTokenAndCanAskToSignOut() {
        let previous = PhoneSession(accessToken: "old", refreshToken: "old", expiresAt: now, tokenURL: PhoneSignIn.Cursor.tokenURL, clientID: PhoneSignIn.Cursor.clientID)
        let request = PhoneSignIn.refreshRequests(for: previous, provider: .grokBot)
        XCTAssertEqual(request.map(\.url), [PhoneSignIn.Cursor.tokenURL])
        XCTAssertEqual(Self.body(request[0])["client_id"] as? String, PhoneSignIn.Cursor.clientID)
        let grant = PhoneSignIn.refreshAnswer(provider: .cursor, status: 200, data: Self.json(["access_token": "new"]), previous: previous, now: now)
        guard case .granted(let renewed) = grant else { return XCTFail("\(grant)") }
        XCTAssertEqual(renewed.accessToken, "new")
        XCTAssertEqual(renewed.refreshToken, "new", "As Cursor's own app keeps it")
        XCTAssertEqual(PhoneSignIn.refreshAnswer(provider: .cursor, status: 200, data: Self.json(["shouldLogout": true, "access_token": "x"]), previous: previous, now: now), .rejected)
    }

    func testCursorAndGrokBotReadTheirOwnDashboards() throws {
        let cursor = try XCTUnwrap(PhoneSignIn.usageRequest(provider: .cursor, accessToken: "tok"))
        XCTAssertEqual(cursor.url, PhoneSignIn.Cursor.usageURL)
        XCTAssertEqual(cursor.httpMethod, "POST")
        XCTAssertEqual(cursor.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(cursor.httpBody, Data("{}".utf8))
        let bot = try XCTUnwrap(PhoneSignIn.usageRequest(provider: .grokBot, accessToken: "tok"))
        XCTAssertEqual(bot.url, PhoneSignIn.Cursor.grokBotUsageURL)
        let notOnPlan = Self.json(["hasNonZeroIncludedLimit": false])
        XCTAssertThrowsError(try PhoneSignIn.snapshot(provider: .grokBot, from: notOnPlan, fetchedAt: now)) { error in
            guard case .notEntitled = error as? ProviderError else { return XCTFail("\(error)") }
        }
    }

    func testGrokBotReadsWithCursorsSessionAndRenewsIt() async throws {
        let keychain = FakeKeychain()
        let store = PhoneSessionStore(accessGroup: "ABCDE12345.app.tokenroom.ios", servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).",
                                      recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery", keychain: keychain.operations)
        try store.save(PhoneSession(accessToken: "cursor-old", refreshToken: "cursor-old", expiresAt: now.addingTimeInterval(30),
                                    tokenURL: PhoneSignIn.Cursor.tokenURL, clientID: PhoneSignIn.Cursor.clientID), for: .cursor, now: now)
        let renewed = LockedBox<[Provider]>([])
        let refresher = PhoneSessionRefresher(store: store) { provider, old in
            renewed.value.append(provider)
            var session = old
            session.accessToken = "cursor-new"
            session.expiresAt = Self.now.addingTimeInterval(86_400)
            return .granted(session)
        }
        let sent = LockedBox<String?>(nil)
        let client = PhoneSessionClient(provider: .grokBot, store: store) { request in
            sent.value = request.value(forHTTPHeaderField: "Authorization")
            return .failure(.parse)
        }
        _ = await PhoneSessionReader(client: client, refresher: refresher).read(now: now)
        XCTAssertEqual(renewed.value, [.cursor], "Grok Bot renews Cursor's session, the one it reads with")
        XCTAssertEqual(sent.value, "Bearer cursor-new")
        XCTAssertNil(store.metadata(for: .grokBot), "No second copy under Grok Bot")
    }

    // MARK: Unclear renewals

    func testARenewalAnsweredUnclearlyIsNeverSentAgain() async throws {
        let keychain = FakeKeychain()
        let store = PhoneSessionStore(accessGroup: "ABCDE12345.app.tokenroom.ios", servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).",
                                      recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery", keychain: keychain.operations)
        try store.save(PhoneSession(accessToken: "a", refreshToken: "maybe-rotated", expiresAt: now.addingTimeInterval(30),
                                    tokenURL: PhoneSignIn.Cursor.tokenURL, clientID: PhoneSignIn.Cursor.clientID), for: .cursor, now: now)
        let posts = Counter()
        let client = PhoneSignInClient(send: { _ in
            posts.increment()
            return (Data(), Self.http(429))
        }, sleep: { _ in })
        let refresher = PhoneSessionRefresher(store: store) { provider, session in await client.renew(provider, session) }
        // Cursor's and Grok Bot's readers both renew Cursor's session in the same pass.
        let first = await refresher.renewIfNeeded(.cursor, now: now)
        let second = await refresher.renewIfNeeded(.cursor, now: now, force: true)
        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .rejected, "No recovered grant: the session asks for a new sign-in")
        XCTAssertEqual(posts.count, 1, "The refresh token went out once")
        let usage = PhoneSessionClient(provider: .grokBot, store: store) { _ in
            XCTFail("No usage call with a session that isn't ready")
            return .failure(.parse)
        }
        let read = await usage.fetch(now: now)
        XCTAssertEqual(read, .failure(.signedOut(PhoneSessionClient.needsSignIn)))
    }

    func testANewSignInDropsAnOldRenewalsGrant() async throws {
        let keychain = FakeKeychain()
        let store = PhoneSessionStore(accessGroup: "ABCDE12345.app.tokenroom.ios", servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).",
                                      recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery", keychain: keychain.operations)
        let old = PhoneSession(accessToken: "old-account", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(3600),
                               tokenURL: PhoneSignIn.Claude.tokenURLs[0], clientID: PhoneSignIn.Claude.clientID)
        try store.save(old, for: .claude, now: now)
        // A renewal's grant reached the recovery item, but the session item never took it.
        XCTAssertTrue(store.saveRecovery(old, for: .claude))
        let refresher = PhoneSessionRefresher(store: store) { _, _ in .unavailable }
        let fresh = PhoneSession(accessToken: "new-account", refreshToken: "new-refresh", expiresAt: now.addingTimeInterval(3600),
                                 tokenURL: PhoneSignIn.Claude.tokenURLs[0], clientID: PhoneSignIn.Claude.clientID)
        try await refresher.replace(.claude, with: fresh, now: now)
        XCTAssertNil(store.takeRecovery(for: .claude))
        // Even if a later renewal of the new session stalls, nothing brings the old one back.
        XCTAssertTrue(store.setState(.exchanging, for: .claude))
        let outcome = await refresher.recover(.claude, now: now)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertNotEqual(store.session(for: .claude)?.accessToken, "old-account")
    }

    // MARK: Which plans are read

    func testARecheckOfAPlanNotOnItsSignInsPlanKeepsItsSpacing() {
        let signedIn: [Provider] = [.cursor, .grokBot]
        let dayAgo = now.addingTimeInterval(-(PhoneSignIn.notOnPlanRecheck + 60))
        // Within the day: Grok Bot stays out, Cursor is read.
        let early = PhoneSignIn.plansToRead(signedIn: signedIn, notOnPlan: [.grokBot: now.addingTimeInterval(-3600)], now: now) { _ in false }
        XCTAssertEqual(early.listed, [.cursor])
        XCTAssertEqual(early.due, [.cursor])
        XCTAssertTrue(early.rechecks.isEmpty)
        // A day on: asked again, when nothing holds it off.
        let due = PhoneSignIn.plansToRead(signedIn: signedIn, notOnPlan: [.grokBot: dayAgo], now: now) { _ in false }
        XCTAssertEqual(due.listed, [.cursor, .grokBot])
        XCTAssertEqual(due.due, [.cursor, .grokBot])
        XCTAssertEqual(due.rechecks, [.grokBot])
        // A day on but held off (a Retry-After, the five-minute spacing): neither listed nor read.
        let held = PhoneSignIn.plansToRead(signedIn: signedIn, notOnPlan: [.grokBot: dayAgo], now: now) { $0 == .grokBot }
        XCTAssertEqual(held.listed, [.cursor])
        XCTAssertEqual(held.due, [.cursor])
        XCTAssertTrue(held.rechecks.isEmpty)
        // Held-off plans that are on the plan stay listed, just not read.
        let spaced = PhoneSignIn.plansToRead(signedIn: signedIn, notOnPlan: [:], now: now) { $0 == .cursor }
        XCTAssertEqual(spaced.listed, [.cursor, .grokBot])
        XCTAssertEqual(spaced.due, [.grokBot])
    }

    // MARK: Signing out during a renewal

    func testSigningOutWaitsForARenewalAndItCantComeBack() async throws {
        let keychain = FakeKeychain()
        let store = PhoneSessionStore(accessGroup: "ABCDE12345.app.tokenroom.ios", servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).",
                                      recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery", keychain: keychain.operations)
        try store.save(PhoneSession(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(30),
                                    tokenURL: PhoneSignIn.Claude.tokenURLs[0], clientID: PhoneSignIn.Claude.clientID), for: .claude, now: now)
        let posted = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let refresher = PhoneSessionRefresher(store: store) { _, old in
            posted.continuation.yield()
            for await _ in release.stream { break }
            var session = old
            session.accessToken = "renewed"
            return .granted(session)
        }
        let renewal = Task { await refresher.renewIfNeeded(.claude, now: Self.now) }
        for await _ in posted.stream { break }
        // Sign out while the token host is still answering.
        let signOut = Task { try await refresher.replace(.claude, with: nil, now: Self.now) }
        release.continuation.yield()
        _ = await renewal.value
        try await signOut.value
        XCTAssertNil(store.metadata(for: .claude), "The renewal landed first; signing out removed it")
        let after = await refresher.renewIfNeeded(.claude, now: Self.now)
        XCTAssertEqual(after, .noSession)
    }

    func testCodexRetriesTheExchangeAfterADroppedConnection() async throws {
        let exchanges = Counter()
        let client = PhoneSignInClient(send: { request in
            if request.url == PhoneSignIn.Codex.pollURL {
                return (Self.json(["authorization_code": "ac", "code_verifier": "cv"]), Self.http(200))
            }
            exchanges.increment()
            if exchanges.count == 1 { throw URLError(.networkConnectionLost) }
            return (Self.json(["access_token": "a", "refresh_token": "r", "expires_in": 3600]), Self.http(200))
        }, sleep: { _ in })
        let code = PhoneSignIn.DeviceCode(provider: .openai, userCode: "ABCD-1234", verificationURL: PhoneSignIn.Codex.verificationURL,
                                          interval: 5, expiresAt: now.addingTimeInterval(900), handle: "dev-1")
        let session = try await client.waitForApproval(code, clock: { Self.now })
        XCTAssertEqual(exchanges.count, 2)
        XCTAssertEqual(session.refreshToken, "r")
    }

    func testGrokNamesTheTeamATokenWasIssuedTo() {
        XCTAssertEqual(PhoneSignIn.grokUser(Self.jwt(["sub": "user-1"])), "user-1")
        XCTAssertEqual(PhoneSignIn.grokUser(Self.jwt(["sub": "user-1", "principal_type": "User", "principal_id": "user-1"])), "user-1")
        XCTAssertEqual(PhoneSignIn.grokUser(Self.jwt(["sub": "user-1", "principal_type": "Team", "principal_id": "team-9"])), "team-9")
        XCTAssertEqual(PhoneSignIn.grokUser(Self.jwt(["principalType": "Organization", "principalId": "org-3"])), "org-3")
        XCTAssertNil(PhoneSignIn.grokUser("opaque"))
    }

    // MARK: Usage

    func testUsageRequestsCarryWhatEachVendorNeedsAndNothingStored() throws {
        let claude = try XCTUnwrap(PhoneSignIn.usageRequest(provider: .claude, accessToken: "tok"))
        XCTAssertEqual(claude.url, PhoneSignIn.Claude.usageURL)
        XCTAssertEqual(claude.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let codexToken = Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "ws-TR"]])
        let codex = try XCTUnwrap(PhoneSignIn.usageRequest(provider: .openai, accessToken: codexToken))
        XCTAssertEqual(codex.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "ws-TR", "Read from the token as it's sent")
        XCTAssertNil(try XCTUnwrap(PhoneSignIn.usageRequest(provider: .openai, accessToken: "opaque")).value(forHTTPHeaderField: "ChatGPT-Account-ID"))

        let grok = try XCTUnwrap(PhoneSignIn.usageRequest(provider: .grok, accessToken: Self.jwt(["sub": "user-TR"])))
        XCTAssertEqual(grok.value(forHTTPHeaderField: "x-userid"), "user-TR")
        XCTAssertEqual(grok.url, PhoneSignIn.Grok.usageURL)
        XCTAssertNil(PhoneSignIn.usageRequest(provider: .devin, accessToken: "tok"))
    }

    func testTheReaderRenewsOnceWhenTheTokenIsTurnedDown() async throws {
        let keychain = FakeKeychain()
        let store = PhoneSessionStore(accessGroup: "ABCDE12345.app.tokenroom.ios", servicePrefix: "app.tokenroom.tests.\(UUID().uuidString).",
                                      recoveryService: "app.tokenroom.tests.\(UUID().uuidString).recovery", keychain: keychain.operations)
        try store.save(PhoneSession(accessToken: "ended-early", refreshToken: "rt", expiresAt: now.addingTimeInterval(8 * 3600),
                                    tokenURL: PhoneSignIn.Claude.tokenURLs[0], clientID: PhoneSignIn.Claude.clientID), for: .claude, now: now)
        let posts = Counter()
        let refresher = PhoneSessionRefresher(store: store) { _, old in
            posts.increment()
            var renewed = old
            renewed.accessToken = "fresh"
            return .granted(renewed)
        }
        let tokens = LockedBox<[String]>([])
        let client = PhoneSessionClient(provider: .claude, store: store) { request in
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            tokens.value.append(token)
            guard token == "Bearer fresh" else { return .failure(.expired("Session expired. Sign in with claude login again.")) }
            let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 30, resetsAt: Self.now.addingTimeInterval(86_400))
            return Result { try QuotaSnapshot.headlined(by: [window], provider: .claude, fetchedAt: Self.now) }.mapError { _ in .parse }
        }
        let result = await PhoneSessionReader(client: client, refresher: refresher).read(now: now)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(tokens.value, ["Bearer ended-early", "Bearer fresh"])
        XCTAssertEqual(posts.count, 1)

        // Still turned down after a renewal: the phone's own words, not the CLI's.
        let stubborn = PhoneSessionClient(provider: .claude, store: store) { _ in .failure(.expired("Session expired. Sign in with claude login again.")) }
        let refused = await PhoneSessionReader(client: stubborn, refresher: refresher).read(now: now)
        XCTAssertEqual(refused, .failure(.expired(PhoneSessionClient.needsSignIn)))
    }
}

/// Asserts `work` throws this `PhoneSignInClient.Failure`.
func XCTAssertThrowsFailure(_ expected: PhoneSignInClient.Failure, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async {
    do {
        try await work()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let failure as PhoneSignInClient.Failure {
        XCTAssertEqual(failure, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}
