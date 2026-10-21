import CryptoKit
import Foundation

/// The plans this iPhone signs in to by itself, with the vendor's own sign-in page: Claude (sign
/// in in Safari, then paste the code the page shows), Codex and Grok Build (approve a short code
/// on the vendor's page while Tokenroom waits). The session that comes back is Tokenroom's own,
/// kept in `PhoneSessionStore`; it isn't a copy of a CLI's login, and nothing here reads one.
///
/// These are the same public clients, token hosts, and usage endpoints the Mac reads through each
/// CLI's login (`OAuthRefresh`, `ClaudeClient`, `OpenAIClient`, `GrokClient`). None of them is
/// documented for other apps, so any of them can change or be refused without notice.
///
/// Pure: requests in, answers parsed. `PhoneSignInClient` sends them.
enum PhoneSignIn {
    /// How a provider's sign-in goes.
    enum Method: Sendable, Equatable {
        /// Sign in on the vendor's page in Safari, then paste the code it shows.
        case pasteCode
        /// Approve a short code on the vendor's page while Tokenroom waits.
        case deviceCode
    }

    /// The plans the iPhone signs in to, in the order the connect screen lists them.
    static let providers: [Provider] = [.claude, .openai, .grok]

    /// The least time between two readings of one plan from the iPhone: these endpoints aren't
    /// documented for other apps, so coming back to the app doesn't call them every minute.
    static let minimumInterval: TimeInterval = 5 * 60

    static func method(for provider: Provider) -> Method? {
        switch provider {
        case .claude: .pasteCode
        case .openai, .grok: .deviceCode
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
        /// RFC 8628's defaults, used when the answer leaves them out.
        static let defaultInterval: TimeInterval = 5
        static let minimumLifetime: TimeInterval = 10 * 60
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
        /// What polling sends back: Codex's `device_auth_id`, Grok's `device_code`.
        var handle: String
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
                interval: interval ?? Grok.defaultInterval,
                expiresAt: JSONFlex.date(object["expires_at"]).flatMap { $0 > now ? $0 : nil } ?? now.addingTimeInterval(Codex.codeLifetime),
                handle: handle
            )
        case .grok:
            guard let handle = JSONFlex.string(object["device_code"]), !handle.isEmpty else { return nil }
            let page = (JSONFlex.string(object["verification_uri_complete"]) ?? JSONFlex.string(object["verification_uri"]))
                .flatMap(URL.init(string:))
            guard let page, isVendorPage(page, provider: provider) else { return nil }
            let lifetime = max(JSONFlex.number(object["expires_in"]) ?? 0, Grok.minimumLifetime)
            return DeviceCode(
                provider: provider,
                userCode: userCode,
                verificationURL: page,
                interval: interval ?? Grok.defaultInterval,
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
        default: []
        }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func pollRequest(_ code: DeviceCode) -> URLRequest {
        switch code.provider {
        case .grok:
            formRequest(Grok.tokenURL, [("grant_type", Grok.deviceGrant), ("device_code", code.handle), ("client_id", Grok.clientID)])
        default:
            jsonRequest(Codex.pollURL, ["device_auth_id": code.handle, "user_code": code.userCode])
        }
    }

    enum PollAnswer: Equatable, Sendable {
        /// Not approved yet: ask again after the interval.
        case pending
        /// Ask less often (RFC 8628 `slow_down`).
        case slowDown
        /// Codex: an authorization code, and the verifier OpenAI made for it, to exchange.
        case authorized(code: String, verifier: String)
        /// Grok: the token answer itself.
        case granted(Data)
        case denied
        case expired
        case failed
    }

    static func pollAnswer(provider: Provider, status: Int, data: Data) -> PollAnswer {
        let object = try? JSONFlex.object(from: data)
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
        switch provider {
        case .claude: Claude.clientID
        case .openai: Codex.clientID
        case .grok: Grok.clientID
        default: nil
        }
    }

    static func tokenURLs(for provider: Provider) -> [URL] {
        switch provider {
        case .claude: Claude.tokenURLs
        case .openai: [Codex.tokenURL]
        case .grok: [Grok.tokenURL]
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
            default:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID])
            }
        }
    }

    /// What a token host said to a renewal. A grant without a refresh token keeps the one sent:
    /// hosts that don't rotate it may leave it out.
    static func refreshAnswer(status: Int, data: Data, previous: PhoneSession, now: Date) -> PhoneSessionRefresher.Grant {
        if (200..<300).contains(status), let tokens = tokens(from: data, now: now) {
            var session = previous
            session.accessToken = tokens.access
            session.refreshToken = tokens.refresh ?? previous.refreshToken
            session.expiresAt = tokens.expiresAt
            return .granted(session)
        }
        let error = (try? JSONFlex.object(from: data)).flatMap { JSONFlex.string($0["error"]) }
        return error == "invalid_grant" ? .rejected : .unavailable
    }

    private static func tokens(from data: Data, now: Date) -> (access: String, refresh: String?, expiresAt: Date?)? {
        guard let object = try? JSONFlex.object(from: data),
              let access = JSONFlex.string(object["access_token"]), !access.isEmpty
        else { return nil }
        let refresh = JSONFlex.string(object["refresh_token"]).flatMap { $0.isEmpty ? nil : $0 }
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
            if let user = JSONFlex.string(claims(ofJWT: accessToken)?["sub"]), !user.isEmpty {
                headers["x-userid"] = user
            }
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
        default: throw ProviderError.parse
        }
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
