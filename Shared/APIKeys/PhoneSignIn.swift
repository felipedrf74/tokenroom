import CryptoKit
import Foundation

/// The plans this iPhone signs in to by itself, with the vendor's own sign-in page: Claude (sign
/// in in Safari, then paste the code the page shows), Codex and Grok Build (approve a short code
/// on the vendor's page while Tokenroom waits), and Cursor and Grok Bot (sign in on Cursor's page,
/// which takes a Grok or X account too, while Tokenroom waits). Grok Bot runs on the Cursor
/// account, so one Cursor sign-in reads both (`sessionOwner`). The session that comes back is
/// Tokenroom's own, kept in `PhoneSessionStore`; it isn't a copy of a CLI's or an app's login,
/// and nothing here reads one.
///
/// These are the same public clients, token hosts, and usage endpoints the Mac reads through each
/// tool's login (`OAuthRefresh`, `ClaudeClient`, `OpenAIClient`, `GrokClient`, `CursorClient`,
/// `GrokBotClient`). None of them is documented for other apps, so any of them can change or be
/// refused without notice.
///
/// Pure: requests in, answers parsed. `PhoneSignInClient` sends them.
enum PhoneSignIn {
    /// How a provider's sign-in goes.
    enum Method: Sendable, Equatable {
        /// Sign in on the vendor's page in Safari, then paste the code it shows.
        case pasteCode
        /// Approve a short code, or just sign in, on the vendor's page while Tokenroom waits.
        case deviceCode
    }

    /// The plans the iPhone signs in to, in the order the connect screen lists them.
    static let providers: [Provider] = [.claude, .openai, .grok, .cursor, .grokBot]

    /// Whose session a plan reads with: Grok Bot runs on the Cursor account, so it uses Cursor's.
    /// A session is kept once, under its owner.
    static func sessionOwner(for provider: Provider) -> Provider {
        provider == .grokBot ? .cursor : provider
    }

    /// Whose page the person signs in on: "Claude", "OpenAI", "xAI", "Cursor".
    static func vendorName(for provider: Provider) -> String {
        switch sessionOwner(for: provider) {
        case .claude: "Claude"
        case .openai: "OpenAI"
        case .grok: "xAI"
        case .cursor: "Cursor"
        default: provider.displayName
        }
    }

    /// What the sign-in is for, as the plan is called: "Codex" for OpenAI's.
    static func planName(for provider: Provider) -> String {
        provider == .openai ? "Codex" : provider.displayName
    }

    /// The plans one sign-in covers: a provider and every plan sharing its session.
    static func sharingSession(with provider: Provider) -> [Provider] {
        let owner = sessionOwner(for: provider)
        return providers.filter { sessionOwner(for: $0) == owner }
    }

    /// How often to ask whether a code was approved, when the vendor doesn't say.
    static let defaultPollInterval: TimeInterval = 5

    /// How long a plan found not to be on its sign-in's plan (Grok Bot without it on the Cursor
    /// plan) stays out before it's asked about again.
    static let notOnPlanRecheck: TimeInterval = 24 * 3600

    /// Which signed-in plans to list, and which to read now. One left out as not on its
    /// sign-in's plan stays out until `notOnPlanRecheck` has passed, and is then read again only
    /// when its own spacing and waits allow (`isHeldOff`), like any other: a recheck that keeps
    /// failing never turns into a call on every refresh.
    static func plansToRead(signedIn: [Provider], notOnPlan: [Provider: Date], now: Date, isHeldOff: (Provider) -> Bool) -> (listed: [Provider], due: [Provider], rechecks: Set<Provider>) {
        let rechecks = Set(signedIn.filter { provider in
            guard let since = notOnPlan[provider] else { return false }
            return !(0..<notOnPlanRecheck).contains(now.timeIntervalSince(since)) && !isHeldOff(provider)
        })
        let listed = signedIn.filter { notOnPlan[$0] == nil || rechecks.contains($0) }
        let due = listed.filter { rechecks.contains($0) || !isHeldOff($0) }
        return (listed, due, rechecks)
    }

    /// The least time between two readings of one plan from the iPhone: these endpoints aren't
    /// documented for other apps, so coming back to the app doesn't call them every minute.
    static let minimumInterval: TimeInterval = 5 * 60

    static func method(for provider: Provider) -> Method? {
        switch provider {
        case .claude: .pasteCode
        case .openai, .grok, .cursor, .grokBot: .deviceCode
        default: nil
        }
    }

    // MARK: Vendors

    enum Claude {
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
        /// The page that shows the code to paste. It has to match on the exchange.
        static let redirectURL = URL(string: "https://platform.claude.com/oauth/code/callback")!
        static let tokenURLs = [
            URL(string: "https://platform.claude.com/v1/oauth/token")!,
            URL(string: "https://console.anthropic.com/v1/oauth/token")!,
        ]
        /// Reading plan usage needs only the profile scope: no inference, no API keys.
        static let scope = "user:profile"
        static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        /// What the Mac sends when it can't tell Claude Code's version.
        static let userAgent = "claude-cli (external, cli)"
    }

    enum Codex {
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let issuer = URL(string: "https://auth.openai.com")!
        static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        static let pollURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
        static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
        /// Where the device flow's authorization code says it was sent, for the exchange.
        static let redirectURL = URL(string: "https://auth.openai.com/deviceauth/callback")!
        static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
        static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        /// How long OpenAI keeps a code open, when its answer has no `expires_at`.
        static let codeLifetime: TimeInterval = 15 * 60
    }

    enum Grok {
        static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
        static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
        static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
        /// `grok-cli:access` lets the token read the Build proxy; `offline_access` brings a
        /// refresh token. No conversations, workspaces, profile, or email.
        static let scope = "openid offline_access grok-cli:access"
        static let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
        /// How long to wait for a code when the answer leaves `expires_in` out.
        static let defaultLifetime: TimeInterval = 10 * 60
    }

    enum Cursor {
        /// Cursor's sign-in page for its apps; it offers Cursor, Grok, and X accounts.
        static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
        static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
        static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
        static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
        static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        static let grokBotUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
        /// How long a sign-in page stays worth waiting for. Cursor doesn't say; its app waits
        /// as long as it's open.
        static let loginLifetime: TimeInterval = 10 * 60
        static let pollInterval: TimeInterval = 2
    }

    // MARK: PKCE

    /// A code verifier, its S256 challenge, and the state echoed back with the code. Kept in
    /// memory for one sign-in only.
    struct PKCE: Sendable, Equatable {
        var verifier: String
        var challenge: String
        var state: String

        init(verifier: String, state: String) {
            self.verifier = verifier
            self.state = state
            challenge = PhoneSignIn.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        static func random() -> PKCE {
            PKCE(verifier: PhoneSignIn.randomToken(), state: PhoneSignIn.randomToken())
        }
    }

    /// 32 random bytes, base64url: 43 characters, inside PKCE's 43–128.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Claude: paste the code

    /// Claude's sign-in page, which ends on a page showing a code to paste back.
    static func claudeAuthorizeURL(_ pkce: PKCE) -> URL {
        var components = URLComponents(url: Claude.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Claude.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Claude.redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: Claude.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    enum PastedCode: Equatable, Sendable {
        case code(String)
        case empty
        /// The state after `#` belongs to another sign-in (an older page, another device).
        case otherSignIn
    }

    /// The code from what was pasted: `code#state` as the page shows it, the code alone, or the
    /// page's own address with `code` and `state` in its query.
    static func claudeCode(fromPasted text: String, state: String) -> PastedCode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), components.scheme == "https",
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            let pastedState = components.queryItems?.first { $0.name == "state" }?.value
            if let pastedState, !pastedState.isEmpty, pastedState != state { return .otherSignIn }
            return .code(code)
        }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let code = parts.first?.trimmingCharacters(in: .whitespaces), !code.isEmpty, !code.contains(" ") else { return .empty }
        if parts.count == 2, !parts[1].isEmpty, parts[1] != state { return .otherSignIn }
        return .code(code)
    }

    static func claudeExchangeRequest(code: String, pkce: PKCE) -> URLRequest {
        jsonRequest(Claude.tokenURLs[0], [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Claude.redirectURL.absoluteString,
            "client_id": Claude.clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ], headers: claudeHeaders)
    }

    private static let claudeHeaders = ["User-Agent": Claude.userAgent, "x-app": "cli"]

    // MARK: Codex and Grok Build: approve a code

    /// A code waiting to be approved on the vendor's page. Lives in memory for one sign-in.
    struct DeviceCode: Sendable, Equatable {
        var provider: Provider
        /// What the person types, or checks, on the vendor's page.
        var userCode: String
        /// The vendor's page, with the code filled in where the vendor allows it.
        var verificationURL: URL
        var interval: TimeInterval
        var expiresAt: Date
        /// What polling sends back: Codex's `device_auth_id`, Grok's `device_code`, Cursor's
        /// sign-in id.
        var handle: String
        /// Cursor's PKCE verifier, sent with each poll. Empty for the others.
        var verifier = ""
    }

    /// Cursor's sign-in: made here, not asked for. The page gets the S256 challenge; polling
    /// sends the verifier, so only this iPhone can collect the session. No code to type: the
    /// person just signs in.
    static func cursorLogin(now: Date) -> DeviceCode {
        let pkce = PKCE.random()
        let id = UUID().uuidString.lowercased()
        var components = URLComponents(url: Cursor.loginURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "challenge", value: pkce.challenge),
            URLQueryItem(name: "uuid", value: id),
            URLQueryItem(name: "mode", value: "login"),
        ]
        return DeviceCode(
            provider: .cursor,
            userCode: "",
            verificationURL: components.url!,
            interval: Cursor.pollInterval,
            expiresAt: now.addingTimeInterval(Cursor.loginLifetime),
            handle: id,
            verifier: pkce.verifier
        )
    }

    static func deviceCodeRequest(for provider: Provider) -> URLRequest? {
        switch provider {
        case .openai:
            jsonRequest(Codex.userCodeURL, ["client_id": Codex.clientID])
        case .grok:
            formRequest(Grok.deviceCodeURL, [("client_id", Grok.clientID), ("scope", Grok.scope)])
        default:
            nil
        }
    }

    /// The code to show, or nil when the answer is missing a field or names a page off the
    /// vendor's own host (the user code is shown as typed, so only letters, digits, and dashes).
    static func deviceCode(from data: Data, provider: Provider, now: Date) -> DeviceCode? {
        guard let object = try? JSONFlex.object(from: data) else { return nil }
        let userCode = JSONFlex.string(object["user_code"]) ?? JSONFlex.string(object["usercode"]) ?? ""
        guard !userCode.isEmpty, userCode.count <= 32,
              userCode.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        let interval = JSONFlex.number(object["interval"]).map { max($0, 1) }
        switch provider {
        case .openai:
            guard let handle = JSONFlex.string(object["device_auth_id"]), !handle.isEmpty else { return nil }
            return DeviceCode(
                provider: provider,
                userCode: userCode,
                verificationURL: Codex.verificationURL,
                interval: interval ?? defaultPollInterval,
                expiresAt: JSONFlex.date(object["expires_at"]).flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(Codex.codeLifetime),
                handle: handle
            )
        case .grok:
            guard let handle = JSONFlex.string(object["device_code"]), !handle.isEmpty else { return nil }
            let page = (JSONFlex.string(object["verification_uri_complete"]) ?? JSONFlex.string(object["verification_uri"]))
                .flatMap(URL.init(string:))
            guard let page, isVendorPage(page, provider: provider) else { return nil }
            let lifetime = JSONFlex.number(object["expires_in"]).flatMap { $0 > 0 ? $0 : nil } ?? Grok.defaultLifetime
            return DeviceCode(
                provider: provider,
                userCode: userCode,
                verificationURL: page,
                interval: interval ?? defaultPollInterval,
                expiresAt: now.addingTimeInterval(lifetime),
                handle: handle
            )
        default:
            return nil
        }
    }

    /// An https page on the vendor's own domain.
    static func isVendorPage(_ url: URL, provider: Provider) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let domains: [String] = switch provider {
        case .openai: ["openai.com", "chatgpt.com"]
        case .grok: ["x.ai", "grok.com"]
        case .claude: ["claude.ai", "claude.com", "anthropic.com"]
        case .cursor, .grokBot: ["cursor.com", "cursor.sh"]
        default: []
        }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func pollRequest(_ code: DeviceCode) -> URLRequest {
        switch code.provider {
        case .cursor, .grokBot:
            var components = URLComponents(url: Cursor.pollURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "uuid", value: code.handle), URLQueryItem(name: "verifier", value: code.verifier)]
            return TokenroomHTTP.request(components.url!, token: nil)
        case .grok:
            return formRequest(Grok.tokenURL, [("grant_type", Grok.deviceGrant), ("device_code", code.handle), ("client_id", Grok.clientID)])
        default:
            return jsonRequest(Codex.pollURL, ["device_auth_id": code.handle, "user_code": code.userCode])
        }
    }

    enum PollAnswer: Equatable, Sendable {
        /// Not approved yet: ask again after the interval.
        case pending
        /// Ask less often (RFC 8628 `slow_down`).
        case slowDown
        /// Codex: an authorization code, and the verifier OpenAI made for it, to exchange.
        case authorized(code: String, verifier: String)
        /// Grok and Cursor: the token answer itself.
        case granted(Data)
        case denied
        /// Cursor: the person's organization doesn't allow this sign-in.
        case blockedByPolicy
        case expired
        case failed
    }

    static func pollAnswer(provider: Provider, status: Int, data: Data) -> PollAnswer {
        let object = try? JSONFlex.object(from: data)
        // A busy or failing server while the person signs in: ask less often, don't give up.
        if status == 429 || (500..<600).contains(status) { return .slowDown }
        if provider == .cursor || provider == .grokBot {
            // 404 until the person has signed in; 403 when their organization doesn't allow it.
            switch status {
            case 200..<300:
                let ready = [object?["accessToken"], object?["refreshToken"]].allSatisfy { (JSONFlex.string($0) ?? "").isEmpty == false }
                return ready ? .granted(data) : .pending
            case 404: return .pending
            case 403: return .blockedByPolicy
            default: return .failed
            }
        }
        if provider == .openai {
            if (200..<300).contains(status) {
                guard let code = JSONFlex.string(object?["authorization_code"]), !code.isEmpty,
                      let verifier = JSONFlex.string(object?["code_verifier"]), !verifier.isEmpty
                else { return .failed }
                return .authorized(code: code, verifier: verifier)
            }
            // OpenAI answers 403 or 404 until the code is approved.
            return status == 403 || status == 404 ? .pending : .failed
        }
        if (200..<300).contains(status) {
            return JSONFlex.string(object?["access_token"]).map { $0.isEmpty ? .failed : .granted(data) } ?? .failed
        }
        switch JSONFlex.string(object?["error"]) {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": return .denied
        case "expired_token": return .expired
        default: return .failed
        }
    }

    static func codexExchangeRequest(code: String, verifier: String) -> URLRequest {
        formRequest(Codex.tokenURL, [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Codex.redirectURL.absoluteString),
            ("client_id", Codex.clientID),
            ("code_verifier", verifier),
        ])
    }

    // MARK: Sessions

    static func clientID(for provider: Provider) -> String? {
        switch sessionOwner(for: provider) {
        case .claude: Claude.clientID
        case .openai: Codex.clientID
        case .grok: Grok.clientID
        case .cursor: Cursor.clientID
        default: nil
        }
    }

    static func tokenURLs(for provider: Provider) -> [URL] {
        switch sessionOwner(for: provider) {
        case .claude: Claude.tokenURLs
        case .openai: [Codex.tokenURL]
        case .grok: [Grok.tokenURL]
        case .cursor: [Cursor.tokenURL]
        default: []
        }
    }

    /// A new sign-in's session: the access and refresh tokens and when the access token expires.
    /// Everything else in the answer (id token, account, organization, email) is dropped. Nil
    /// without a refresh token: a session that can't be renewed isn't kept.
    static func session(fromGrant data: Data, provider: Provider, now: Date) -> PhoneSession? {
        guard let clientID = clientID(for: provider), let tokenURL = tokenURLs(for: provider).first,
              let tokens = tokens(from: data, now: now),
              let refresh = tokens.refresh
        else { return nil }
        return PhoneSession(accessToken: tokens.access, refreshToken: refresh, expiresAt: tokens.expiresAt, tokenURL: tokenURL, clientID: clientID)
    }

    /// Requests that renew `session`, to try in order: the token host it was issued by first.
    static func refreshRequests(for session: PhoneSession, provider: Provider) -> [URLRequest] {
        var urls = [session.tokenURL]
        urls += tokenURLs(for: provider).filter { $0 != session.tokenURL }
        return urls.map { url in
            switch provider {
            case .grok:
                formRequest(url, [("grant_type", "refresh_token"), ("refresh_token", session.refreshToken), ("client_id", session.clientID)])
            case .claude:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID], headers: claudeHeaders)
            case .cursor, .grokBot:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID])
            default:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID])
            }
        }
    }

    /// What a token host said to a renewal. A grant without a refresh token keeps the one sent:
    /// hosts that don't rotate it may leave it out. Cursor renews with its access token, so a new
    /// one becomes the refresh token too, as Cursor's own app keeps it; its `shouldLogout` is a
    /// refusal. Any other OAuth error answer (a 4xx whose body names an `error`, RFC 6749 §5.2)
    /// issued no token, so nothing was rotated and the refresh token is still good
    /// (`notDispatched`). Anything else after the request reached the host (a 429, a 5xx, a 4xx
    /// without an OAuth error, a success without tokens) is unclear (`unavailable`): the session
    /// then waits for a new sign-in rather than send the old refresh token again. A request that
    /// never left the phone is `notDispatched` too (`PhoneSignInClient.renew`).
    static func refreshAnswer(provider: Provider, status: Int, data: Data, previous: PhoneSession, now: Date) -> PhoneSessionRefresher.Grant {
        let object = try? JSONFlex.object(from: data)
        if (object?["shouldLogout"] as? Bool) == true { return .rejected }
        if (200..<300).contains(status), let tokens = tokens(from: data, now: now) {
            var session = previous
            session.accessToken = tokens.access
            let rotated = sessionOwner(for: provider) == .cursor ? tokens.access : previous.refreshToken
            session.refreshToken = tokens.refresh ?? rotated
            session.expiresAt = tokens.expiresAt
            return .granted(session)
        }
        let error = object.flatMap { JSONFlex.string($0["error"]) }
        if error == "invalid_grant" { return .rejected }
        if let error, !error.isEmpty, (400..<500).contains(status), status != 429 { return .notDispatched }
        return .unavailable
    }

    /// Access and refresh tokens, in OAuth's names or Cursor's (`accessToken`, `refreshToken`).
    private static func tokens(from data: Data, now: Date) -> (access: String, refresh: String?, expiresAt: Date?)? {
        guard let object = try? JSONFlex.object(from: data),
              let access = JSONFlex.string(object["access_token"]) ?? JSONFlex.string(object["accessToken"]), !access.isEmpty
        else { return nil }
        let refresh = (JSONFlex.string(object["refresh_token"]) ?? JSONFlex.string(object["refreshToken"])).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = JSONFlex.number(object["expires_in"]).flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
            ?? JSONFlex.number(claims(ofJWT: access)?["exp"]).map { Date(timeIntervalSince1970: $0) }
        return (access, refresh, expiresAt)
    }

    // MARK: Usage

    /// The usage request for a session's access token. Headers the vendor needs that name the
    /// account (Codex's workspace, Grok's user) are read from the access token as it's sent, and
    /// never stored.
    static func usageRequest(provider: Provider, accessToken: String) -> URLRequest? {
        var headers: [String: String]
        let url: URL
        switch provider {
        case .claude:
            url = Claude.usageURL
            headers = claudeHeaders
            headers["anthropic-beta"] = "oauth-2025-04-20"
        case .openai:
            url = Codex.usageURL
            headers = ["OpenAI-Beta": "codex-1", "originator": "Tokenroom"]
            let auth = JSONFlex.dictionary(claims(ofJWT: accessToken)?["https://api.openai.com/auth"])
            if let account = JSONFlex.string(auth?["chatgpt_account_id"]), !account.isEmpty {
                headers["ChatGPT-Account-ID"] = account
            }
        case .grok:
            url = Grok.usageURL
            headers = [:]
            if let user = grokUser(accessToken), !user.isEmpty {
                headers["x-userid"] = user
            }
        case .cursor, .grokBot:
            // Connect RPCs: a POST with an empty JSON message.
            let url = provider == .cursor ? Cursor.usageURL : Cursor.grokBotUsageURL
            return TokenroomHTTP.request(url, method: "POST", token: accessToken, headers: ["Connect-Protocol-Version": "1"], body: Data("{}".utf8))
        default:
            return nil
        }
        return TokenroomHTTP.request(url, token: accessToken, headers: headers)
    }

    static func snapshot(provider: Provider, from data: Data, fetchedAt: Date) throws -> QuotaSnapshot {
        switch provider {
        case .claude: try ClaudeParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .openai: try OpenAIParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .grok: try GrokParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .cursor: try CursorParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .grokBot: try GrokBotParser.snapshot(from: data, fetchedAt: fetchedAt)
        default: throw ProviderError.parse
        }
    }

    /// The user the Grok CLI names in `x-userid`: the team or organization a token was issued
    /// to, or else the person (`sub`), as Grok's own login reads them from its tokens.
    static func grokUser(_ accessToken: String) -> String? {
        guard let claims = claims(ofJWT: accessToken) else { return nil }
        let type = JSONFlex.string(claims["principal_type"]) ?? JSONFlex.string(claims["principalType"])
        let principal = JSONFlex.string(claims["principal_id"]) ?? JSONFlex.string(claims["principalId"])
        if let principal, !principal.isEmpty, type == "Team" || type == "Organization" {
            return principal
        }
        return JSONFlex.string(claims["sub"])
    }

    /// A JWT's claims, unverified: only for reading what the vendor already sent back to it.
    static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONFlex.object(from: data)
    }

    // MARK: Requests

    private static func jsonRequest(_ url: URL, _ fields: [String: String], headers: [String: String] = [:]) -> URLRequest {
        let body = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        var request = TokenroomHTTP.request(url, method: "POST", token: nil, headers: headers, body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = TokenroomHTTP.request(url, method: "POST", token: nil)
        request.httpBody = Data(formBody(fields).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func formBody(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}
