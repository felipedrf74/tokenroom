import CryptoKit
import Foundation

enum PhoneSignIn {
    enum Method: Sendable, Equatable {
        case deviceCode
    }

    static let providers: [Provider] = [.openai, .grok, .cursor, .grokBot]

    static func sessionOwner(for provider: Provider) -> Provider {
        provider == .grokBot ? .cursor : provider
    }

    static func vendorName(for provider: Provider) -> String {
        switch sessionOwner(for: provider) {
        case .openai: "OpenAI"
        case .grok: "xAI"
        case .cursor: "Cursor"
        default: provider.displayName
        }
    }

    static func planName(for provider: Provider) -> String {
        provider == .openai ? "Codex" : provider.displayName
    }

    static func sharingSession(with provider: Provider) -> [Provider] {
        let owner = sessionOwner(for: provider)
        return providers.filter { sessionOwner(for: $0) == owner }
    }

    static let defaultPollInterval: TimeInterval = 5

    static let notOnPlanRecheck: TimeInterval = 24 * 3600

    static func plansToRead(signedIn: [Provider], notOnPlan: [Provider: Date], now: Date, paused: Set<Provider> = [],
                            isHeldOff: (Provider) -> Bool) -> (listed: [Provider], due: [Provider], rechecks: Set<Provider>) {
        let rechecks = Set(signedIn.filter { provider in
            guard let since = notOnPlan[provider], !paused.contains(provider) else { return false }
            return !(0..<notOnPlanRecheck).contains(now.timeIntervalSince(since)) && !isHeldOff(provider)
        })
        let listed = signedIn.filter { notOnPlan[$0] == nil || rechecks.contains($0) }
        let due = listed.filter { !paused.contains($0) && (rechecks.contains($0) || !isHeldOff($0)) }
        return (listed, due, rechecks)
    }

    static let minimumInterval: TimeInterval = 5 * 60

    static func method(for provider: Provider) -> Method? {
        switch provider {
        case .openai, .grok, .cursor, .grokBot: .deviceCode
        default: nil
        }
    }

    enum Codex {
        static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        static let issuer = URL(string: "https://auth.openai.com")!
        static let userCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        static let pollURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
        static let verificationURL = URL(string: "https://auth.openai.com/codex/device")!
        static let redirectURL = URL(string: "https://auth.openai.com/deviceauth/callback")!
        static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
        static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        static let codeLifetime: TimeInterval = 15 * 60
    }

    enum Grok {
        static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"
        static let deviceCodeURL = URL(string: "https://auth.x.ai/oauth2/device/code")!
        static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
        static let scope = "openid offline_access grok-cli:access"
        static let usageURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
        static let defaultLifetime: TimeInterval = 10 * 60
    }

    enum Cursor {
        static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
        static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
        static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
        static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
        static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        static let grokBotUsageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
        static let loginLifetime: TimeInterval = 10 * 60
        static let pollInterval: TimeInterval = 2
    }

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

    struct DeviceCode: Sendable, Equatable {
        var provider: Provider
        var userCode: String
        var verificationURL: URL
        var interval: TimeInterval
        var expiresAt: Date
        var handle: String
        var verifier = ""
    }

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

    static func isVendorPage(_ url: URL, provider: Provider) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let domains: [String] = switch provider {
        case .openai: ["openai.com", "chatgpt.com"]
        case .grok: ["x.ai", "grok.com"]
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
        case pending
        case slowDown
        case authorized(code: String, verifier: String)
        case granted(Data)
        case denied
        case blockedByPolicy
        case expired
        case failed
    }

    static func pollAnswer(provider: Provider, status: Int, data: Data) -> PollAnswer {
        let object = try? JSONFlex.object(from: data)
        if status == 429 || (500..<600).contains(status) { return .slowDown }
        if provider == .cursor || provider == .grokBot {
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

    static func clientID(for provider: Provider) -> String? {
        switch sessionOwner(for: provider) {
        case .openai: Codex.clientID
        case .grok: Grok.clientID
        case .cursor: Cursor.clientID
        default: nil
        }
    }

    static func tokenURLs(for provider: Provider) -> [URL] {
        switch sessionOwner(for: provider) {
        case .openai: [Codex.tokenURL]
        case .grok: [Grok.tokenURL]
        case .cursor: [Cursor.tokenURL]
        default: []
        }
    }

    static func session(fromGrant data: Data, provider: Provider, now: Date) -> PhoneSession? {
        guard let clientID = clientID(for: provider), let tokenURL = tokenURLs(for: provider).first,
              let tokens = tokens(from: data, now: now),
              let refresh = tokens.refresh
        else { return nil }
        return PhoneSession(accessToken: tokens.access, refreshToken: refresh, expiresAt: tokens.expiresAt, tokenURL: tokenURL, clientID: clientID)
    }

    static func refreshRequests(for session: PhoneSession, provider: Provider) -> [URLRequest] {
        var urls = [session.tokenURL]
        urls += tokenURLs(for: provider).filter { $0 != session.tokenURL }
        return urls.map { url in
            switch provider {
            case .grok:
                formRequest(url, [("grant_type", "refresh_token"), ("refresh_token", session.refreshToken), ("client_id", session.clientID)])
            case .cursor, .grokBot:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID])
            default:
                jsonRequest(url, ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID])
            }
        }
    }

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
        if error == "invalid_client" || error == "unauthorized_client" { return .clientRefused }
        if status == 429 || status == 503 { return .notDispatched }
        if let error, !error.isEmpty, (400..<500).contains(status) { return .notDispatched }
        return .unavailable
    }

    private static func tokens(from data: Data, now: Date) -> (access: String, refresh: String?, expiresAt: Date?)? {
        guard let object = try? JSONFlex.object(from: data),
              let access = JSONFlex.string(object["access_token"]) ?? JSONFlex.string(object["accessToken"]), !access.isEmpty
        else { return nil }
        let refresh = (JSONFlex.string(object["refresh_token"]) ?? JSONFlex.string(object["refreshToken"])).flatMap { $0.isEmpty ? nil : $0 }
        let expiresAt = JSONFlex.number(object["expires_in"]).flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
            ?? JSONFlex.number(claims(ofJWT: access)?["exp"]).map { Date(timeIntervalSince1970: $0) }
        return (access, refresh, expiresAt)
    }

    static func usageRequest(provider: Provider, accessToken: String) -> URLRequest? {
        var headers: [String: String]
        let url: URL
        switch provider {
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
            let url = provider == .cursor ? Cursor.usageURL : Cursor.grokBotUsageURL
            return TokenroomHTTP.request(url, method: "POST", token: accessToken, headers: ["Connect-Protocol-Version": "1"], body: Data("{}".utf8))
        default:
            return nil
        }
        return TokenroomHTTP.request(url, token: accessToken, headers: headers)
    }

    static func snapshot(provider: Provider, from data: Data, fetchedAt: Date) throws -> QuotaSnapshot {
        switch provider {
        case .openai: try OpenAIParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .grok: try GrokParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .cursor: try CursorParser.snapshot(from: data, fetchedAt: fetchedAt)
        case .grokBot: try GrokBotParser.snapshot(from: data, fetchedAt: fetchedAt)
        default: throw ProviderError.parse
        }
    }

    static func grokUser(_ accessToken: String) -> String? {
        guard let claims = claims(ofJWT: accessToken) else { return nil }
        let type = JSONFlex.string(claims["principal_type"]) ?? JSONFlex.string(claims["principalType"])
        let principal = JSONFlex.string(claims["principal_id"]) ?? JSONFlex.string(claims["principalId"])
        if let principal, !principal.isEmpty, type == "Team" || type == "Organization" {
            return principal
        }
        return JSONFlex.string(claims["sub"])
    }

    static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONFlex.object(from: data)
    }

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
