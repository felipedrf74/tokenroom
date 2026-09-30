import Foundation
import LocalAuthentication
import os
import Security

/// New tokens kept only until they are written back into the tool's own login.
/// No names, emails, or the rest of the auth file.
struct LoginRecoveryPending: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    /// Grok `expires_at`, or Codex `last_refresh`. Claude uses `expiresAtMs`.
    var expiresText: String?
    var expiresAtMs: Double?
    /// The refresh token that was exchanged. The file is patched only while it still has this.
    var previousRefresh: String
}

/// Pure helpers for renewing a CLI login. The actor below does the reading and writing.
enum OAuthRefresh {
    struct Grant: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: TimeInterval?
    }

    enum Outcome: Sendable {
        case grant(Grant)
        case rejected
        case unavailable
    }

    /// Renew when this much life is left, so a check doesn't land in the last minute.
    static let lead: TimeInterval = 180
    /// Below this, an access token is not sent. Matches the readers' expiry buffer.
    static let usableSlack: TimeInterval = 60
    static let claudeExpiresIn: TimeInterval = 8 * 60 * 60
    static let grokExpiresIn: TimeInterval = 6 * 60 * 60

    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let claudeTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let claudeLegacyTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let codexLegacyTokenURL = URL(string: "https://auth.api.openai.org/oauth/token")!

    static func needsRefresh(expiresAt: Date?, now: Date, canRefresh: Bool, lead: TimeInterval = lead) -> Bool {
        guard canRefresh, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= lead
    }

    /// Nil expiry is left to the server. A token inside the last minute is not sent.
    static func stillUsable(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > usableSlack
    }

    /// `https://auth.x.ai/oauth2/token` when `issuer` is that host over https.
    /// An empty issuer defaults to auth.x.ai; any other host is refused.
    static func grokTokenURL(issuer: String) -> URL? {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "https://auth.x.ai" : trimmed
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "auth.x.ai"
        else { return nil }
        return URL(string: "https://auth.x.ai/oauth2/token")
    }

    static func grant(from data: Data) -> Grant? {
        guard let object = try? JSONFlex.object(from: data),
              let access = JSONFlex.string(object["access_token"]), !access.isEmpty
        else { return nil }
        let refresh = JSONFlex.string(object["refresh_token"]).flatMap { $0.isEmpty ? nil : $0 }
        let idToken = JSONFlex.string(object["id_token"]).flatMap { $0.isEmpty ? nil : $0 }
        return Grant(
            accessToken: access,
            refreshToken: refresh,
            idToken: idToken,
            expiresIn: JSONFlex.number(object["expires_in"]) ?? JSONFlex.number(object["expiresIn"])
        )
    }

    static func isRejectedGrant(_ data: Data) -> Bool {
        guard let object = try? JSONFlex.object(from: data) else { return false }
        return JSONFlex.string(object["error"]) == "invalid_grant"
    }

    static func formBody(_ fields: [(String, String)]) -> String {
        fields.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters stay as they are.
    static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// A UTC timestamp with the same fractional digits and `Z` suffix as `sample`.
    static func timestamp(like sample: String, date: Date) -> String {
        let digits = fractionalDigits(in: sample)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        var fraction = date.timeIntervalSince(whole)
        if fraction < 0 { fraction = 0 }
        let scale = pow(10, Double(digits))
        var rounded = Int((fraction * scale).rounded())
        var instant = whole
        if rounded >= Int(scale) {
            rounded = 0
            instant = whole.addingTimeInterval(1)
        }
        let fractionText = String(format: "%0*d", digits, rounded)
        return formatter.string(from: instant) + "." + fractionText + "Z"
    }

    static func post(urls: [URL], body: Data, contentType: String, headers: [String: String]) async -> Outcome {
        for url in urls {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let (data, response) = try await TokenroomHTTP.data(for: request)
                switch classify(status: response.statusCode, body: data) {
                case .grant(let grant):
                    return .grant(grant)
                case .rejected:
                    return .rejected
                case .unavailable:
                    continue
                }
            } catch {
                continue
            }
        }
        return .unavailable
    }

    static func patchGrok(
        raw: String,
        mapKey: String,
        accessToken: String,
        refreshToken: String?,
        expiresText: String,
        previousAccess: String,
        previousRefresh: String,
        previousExpires: String
    ) -> String? {
        if let surgical = surgicalGrok(
            raw: raw,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresText: expiresText,
            previousAccess: previousAccess,
            previousRefresh: previousRefresh,
            previousExpires: previousExpires
        ) {
            return surgical
        }
        return rewriteObject(raw) { root in
            guard var entry = root[mapKey] as? [String: Any] else { return nil }
            entry["key"] = accessToken
            entry["refresh_token"] = refreshToken ?? previousRefresh
            entry["expires_at"] = expiresText
            root[mapKey] = entry
            return root
        }
    }

    static func patchClaude(
        raw: String,
        accessToken: String,
        refreshToken: String?,
        expiresAtMs: Double,
        previousAccess: String,
        previousRefresh: String?,
        previousExpiresAtMs: Double?
    ) -> String? {
        if let previousExpiresAtMs,
           let surgical = surgicalClaude(
            raw: raw,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMs: expiresAtMs,
            previousAccess: previousAccess,
            previousRefresh: previousRefresh,
            previousExpiresAtMs: previousExpiresAtMs
           ) {
            return surgical
        }
        return rewriteObject(raw) { root in
            let expires = NSNumber(value: Int64(expiresAtMs.rounded()))
            if var nested = root["claudeAiOauth"] as? [String: Any] {
                writeToken(accessToken, camel: "accessToken", snake: "access_token", into: &nested)
                if let refreshToken {
                    writeToken(refreshToken, camel: "refreshToken", snake: "refresh_token", into: &nested)
                }
                nested["expiresAt"] = expires
                root["claudeAiOauth"] = nested
            } else {
                writeToken(accessToken, camel: "accessToken", snake: "access_token", into: &root)
                if let refreshToken {
                    writeToken(refreshToken, camel: "refreshToken", snake: "refresh_token", into: &root)
                }
                root["expiresAt"] = expires
            }
            return root
        }
    }

    static func patchCodex(
        raw: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        lastRefresh: String,
        previousAccess: String,
        previousRefresh: String,
        previousIDToken: String,
        previousLastRefresh: String
    ) -> String? {
        if let surgical = surgicalCodex(
            raw: raw,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            lastRefresh: lastRefresh,
            previousAccess: previousAccess,
            previousRefresh: previousRefresh,
            previousIDToken: previousIDToken,
            previousLastRefresh: previousLastRefresh
        ) {
            return surgical
        }
        return rewriteObject(raw) { root in
            var tokens = root["tokens"] as? [String: Any] ?? [:]
            tokens["access_token"] = accessToken
            tokens["refresh_token"] = refreshToken ?? previousRefresh
            if let idToken, !idToken.isEmpty {
                tokens["id_token"] = idToken
            }
            root["tokens"] = tokens
            root["last_refresh"] = lastRefresh
            return root
        }
    }

    private static func classify(status: Int, body: Data) -> Outcome {
        if (200..<300).contains(status), let grant = grant(from: body) {
            return .grant(grant)
        }
        if isRejectedGrant(body) {
            return .rejected
        }
        return .unavailable
    }

    private static func fractionalDigits(in sample: String) -> Int {
        guard let dot = sample.firstIndex(of: "."), sample.hasSuffix("Z") else { return 6 }
        let digits = sample[sample.index(after: dot)..<sample.index(before: sample.endIndex)]
        if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return digits.count }
        return 6
    }

    private static func surgicalGrok(
        raw: String,
        accessToken: String,
        refreshToken: String?,
        expiresText: String,
        previousAccess: String,
        previousRefresh: String,
        previousExpires: String
    ) -> String? {
        guard var text = replacing(["key"], from: previousAccess, to: accessToken, in: raw) else { return nil }
        if let refreshToken, refreshToken != previousRefresh {
            guard let updated = replacing(["refresh_token"], from: previousRefresh, to: refreshToken, in: text) else { return nil }
            text = updated
        }
        if previousExpires.isEmpty { return nil }
        if previousExpires != expiresText {
            guard let updated = replacing(["expires_at"], from: previousExpires, to: expiresText, in: text) else { return nil }
            text = updated
        }
        return text
    }

    private static func surgicalClaude(
        raw: String,
        accessToken: String,
        refreshToken: String?,
        expiresAtMs: Double,
        previousAccess: String,
        previousRefresh: String?,
        previousExpiresAtMs: Double
    ) -> String? {
        guard var text = replacing(["accessToken", "access_token"], from: previousAccess, to: accessToken, in: raw) else { return nil }
        if let refreshToken, let previousRefresh, refreshToken != previousRefresh {
            guard let updated = replacing(["refreshToken", "refresh_token"], from: previousRefresh, to: refreshToken, in: text) else { return nil }
            text = updated
        }
        guard let updated = replacingNumber(["expiresAt", "expires_at"], equalTo: previousExpiresAtMs, with: expiresAtMs, in: text) else { return nil }
        text = updated
        return text
    }

    private static func surgicalCodex(
        raw: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        lastRefresh: String,
        previousAccess: String,
        previousRefresh: String,
        previousIDToken: String,
        previousLastRefresh: String
    ) -> String? {
        guard var text = replacing(["access_token"], from: previousAccess, to: accessToken, in: raw) else { return nil }
        if let refreshToken, refreshToken != previousRefresh {
            guard let updated = replacing(["refresh_token"], from: previousRefresh, to: refreshToken, in: text) else { return nil }
            text = updated
        }
        if let idToken, !idToken.isEmpty, idToken != previousIDToken {
            guard let updated = replacing(["id_token"], from: previousIDToken, to: idToken, in: text) else { return nil }
            text = updated
        }
        if previousLastRefresh.isEmpty || previousLastRefresh == lastRefresh { return previousLastRefresh.isEmpty ? nil : text }
        guard let updated = replacing(["last_refresh"], from: previousLastRefresh, to: lastRefresh, in: text) else { return nil }
        return updated
    }

    private static func replacing(_ keys: [String], from old: String, to new: String, in text: String) -> String? {
        guard !old.isEmpty, let oldLiteral = JSONTextEdit.literal(old), let newLiteral = JSONTextEdit.literal(new) else { return nil }
        for key in keys {
            if let updated = JSONTextEdit.replaceValue(of: key, equalTo: oldLiteral, with: newLiteral, in: text) {
                return updated
            }
        }
        return nil
    }

    private static func replacingNumber(_ keys: [String], equalTo old: Double, with new: Double, in text: String) -> String? {
        let newLiteral = String(Int64(new.rounded()))
        for key in keys {
            guard let literals = JSONTextEdit.literals(of: key, in: text) else { continue }
            for literal in literals {
                guard let number = Double(literal), number == old else { continue }
                if let updated = JSONTextEdit.replaceValue(of: key, equalTo: literal, with: newLiteral, in: text) {
                    return updated
                }
            }
        }
        return nil
    }

    private static func writeToken(_ value: String, camel: String, snake: String, into object: inout [String: Any]) {
        if object[snake] != nil, object[camel] == nil {
            object[snake] = value
        } else {
            object[camel] = value
            if object[snake] != nil { object[snake] = value }
        }
    }

    private static func rewriteObject(_ raw: String, _ edit: (inout [String: Any]) -> [String: Any]?) -> String? {
        guard let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var root = parsed as? [String: Any],
              let edited = edit(&root),
              JSONSerialization.isValidJSONObject(edited),
              let out = try? JSONSerialization.data(withJSONObject: edited, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8)
        else { return nil }
        return text
    }
}

/// One renewal at a time per provider. A second caller waits for the first instead of
/// exchanging the same refresh token twice.
private final class LoginFlight<Value: Sendable>: @unchecked Sendable {
    var id: UUID?
    var task: Task<Value, Error>?
}

/// Renews Claude, Grok Build, and Codex in the login the user already has.
/// The new access token and, when the server rotates it, the new refresh token are written
/// back into that login. Nothing is kept once the write succeeds.
actor LoginSession {
    static let shared = LoginSession()

    /// Unit tests launch this app. Renewing the real CLI login from that process would rotate it.
    private static let runningUnderTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private static let log = Logger(subsystem: "app.tokenroom.mac", category: "refresh")
    private let grokFlight = LoginFlight<CredentialReaders.GrokAuth>()
    private let claudeFlight = LoginFlight<CredentialReaders.ClaudeAuth>()
    private let codexFlight = LoginFlight<CredentialReaders.CodexAuth>()
    private var memory: [String: LoginRecoveryPending] = [:]

    func grok(
        at url: URL? = nil,
        now: Date = .now,
        replacing rejected: String? = nil,
        persistsRecovery: Bool = true
    ) async throws -> CredentialReaders.GrokAuth {
        let file = url ?? CredentialReaders.grokAuthURL
        if url == nil, Self.runningUnderTests {
            return try await readGrok(file)
        }
        return try await fly(grokFlight, replacing: rejected, access: \.accessToken) {
            try await self.performGrok(file: file, now: now, replacing: rejected, persistsRecovery: persistsRecovery)
        }
    }

    /// `load` and `save` stand in for the Keychain in tests. Production reads and writes
    /// Claude Code's own item.
    func claude(
        now: Date = .now,
        replacing rejected: String? = nil,
        persistsRecovery: Bool = true,
        load: (@Sendable () throws -> CredentialReaders.ClaudeAuth)? = nil,
        save: (@Sendable (CredentialReaders.ClaudeAuth) throws -> Void)? = nil
    ) async throws -> CredentialReaders.ClaudeAuth {
        if load == nil, Self.runningUnderTests {
            return try await BlockingIO.run { try CredentialReaders.claudeAuth() }
        }
        return try await fly(claudeFlight, replacing: rejected, access: \.accessToken) {
            try await self.performClaude(now: now, replacing: rejected, persistsRecovery: persistsRecovery, load: load, save: save)
        }
    }

    func codex(
        at url: URL? = nil,
        now: Date = .now,
        replacing rejected: String? = nil,
        persistsRecovery: Bool = true
    ) async throws -> CredentialReaders.CodexAuth {
        let file = url ?? CredentialReaders.codexHome.appendingPathComponent("auth.json")
        if url == nil, Self.runningUnderTests {
            return try await readCodex(file)
        }
        return try await fly(codexFlight, replacing: rejected, access: \.accessToken) {
            try await self.performCodex(file: file, now: now, replacing: rejected, persistsRecovery: persistsRecovery)
        }
    }

    // MARK: Providers

    private func performGrok(file: URL, now: Date, replacing: String?, persistsRecovery: Bool) async throws -> CredentialReaders.GrokAuth {
        try await renew(
            provider: .grok,
            now: now,
            replacing: replacing,
            persistsRecovery: persistsRecovery,
            read: { try await self.readGrok(file) },
            facts: { Facts(accessToken: $0.accessToken, refreshToken: $0.refreshToken, expiresAt: $0.expiresAt, canRefresh: $0.canRenew) },
            post: { auth in
                guard let url = OAuthRefresh.grokTokenURL(issuer: auth.issuer) else { return .unavailable }
                let body = Data(OAuthRefresh.formBody([
                    ("grant_type", "refresh_token"),
                    ("refresh_token", auth.refreshToken),
                    ("client_id", auth.clientID),
                ]).utf8)
                return await OAuthRefresh.post(urls: [url], body: body, contentType: "application/x-www-form-urlencoded", headers: [:])
            },
            pendingFor: { auth, grant in
                let expiresIn = grant.expiresIn ?? OAuthRefresh.grokExpiresIn
                return LoginRecoveryPending(
                    accessToken: grant.accessToken,
                    refreshToken: grant.refreshToken ?? auth.refreshToken,
                    idToken: nil,
                    expiresText: OAuthRefresh.timestamp(like: auth.expiresText, date: now.addingTimeInterval(expiresIn)),
                    expiresAtMs: nil,
                    previousRefresh: auth.refreshToken
                )
            },
            apply: { auth, pending in
                guard auth.refreshToken == pending.previousRefresh else { return .moved(auth) }
                guard let patched = OAuthRefresh.patchGrok(
                    raw: auth.rawJSON,
                    mapKey: auth.mapKey,
                    accessToken: pending.accessToken,
                    refreshToken: pending.refreshToken,
                    expiresText: pending.expiresText ?? "",
                    previousAccess: auth.accessToken,
                    previousRefresh: auth.refreshToken,
                    previousExpires: auth.expiresText
                ) else { throw ProviderError.unreachable }
                try await self.writeText(patched, to: file)
                let written = try await self.readGrok(file)
                guard written.accessToken == pending.accessToken else { throw ProviderError.unreachable }
                return .wrote(written)
            }
        )
    }

    private func performClaude(
        now: Date,
        replacing: String?,
        persistsRecovery: Bool,
        load: (@Sendable () throws -> CredentialReaders.ClaudeAuth)?,
        save: (@Sendable (CredentialReaders.ClaudeAuth) throws -> Void)?
    ) async throws -> CredentialReaders.ClaudeAuth {
        let read: () async throws -> CredentialReaders.ClaudeAuth = {
            if let load {
                return try await BlockingIO.run { try load() }
            }
            let cached = CredentialReaders.cachedClaudeAuth()
            let expiry = cached?.expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
            let due = cached == nil || OAuthRefresh.needsRefresh(
                expiresAt: expiry,
                now: now,
                canRefresh: cached?.canRefresh(at: now) ?? false
            )
            let recovering = await self.recall(.claude, persists: persistsRecovery) != nil
            if replacing != nil || due || recovering {
                CredentialReaders.invalidateCaches()
            }
            return try await BlockingIO.run { try CredentialReaders.claudeAuth() }
        }
        return try await renew(
            provider: .claude,
            now: now,
            replacing: replacing,
            persistsRecovery: persistsRecovery,
            read: read,
            facts: { auth in
                let expiry = auth.expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
                return Facts(accessToken: auth.accessToken, refreshToken: auth.refreshToken ?? "", expiresAt: expiry, canRefresh: auth.canRefresh(at: now))
            },
            post: { auth in
                let userAgent = await BlockingIO.run { CredentialReaders.claudeUserAgent() }
                let payload = [
                    "client_id": OAuthRefresh.claudeClientID,
                    "grant_type": "refresh_token",
                    "refresh_token": auth.refreshToken ?? "",
                ]
                guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                    return .unavailable
                }
                return await OAuthRefresh.post(
                    urls: [OAuthRefresh.claudeTokenURL, OAuthRefresh.claudeLegacyTokenURL],
                    body: body,
                    contentType: "application/json",
                    headers: ["User-Agent": userAgent, "x-app": "cli"]
                )
            },
            pendingFor: { auth, grant in
                let expiresIn = grant.expiresIn ?? OAuthRefresh.claudeExpiresIn
                return LoginRecoveryPending(
                    accessToken: grant.accessToken,
                    refreshToken: grant.refreshToken ?? auth.refreshToken ?? "",
                    idToken: nil,
                    expiresText: nil,
                    expiresAtMs: (now.timeIntervalSince1970 + expiresIn) * 1000,
                    previousRefresh: auth.refreshToken ?? ""
                )
            },
            apply: { auth, pending in
                guard (auth.refreshToken ?? "") == pending.previousRefresh else { return .moved(auth) }
                guard let expiresAtMs = pending.expiresAtMs else { throw ProviderError.unreachable }
                guard let patched = OAuthRefresh.patchClaude(
                    raw: auth.rawJSON,
                    accessToken: pending.accessToken,
                    refreshToken: pending.refreshToken,
                    expiresAtMs: expiresAtMs,
                    previousAccess: auth.accessToken,
                    previousRefresh: auth.refreshToken,
                    previousExpiresAtMs: auth.expiresAtMs
                ) else { throw ProviderError.unreachable }
                let updated = try CredentialReaders.parseClaudeAuth(patched, account: auth.account, service: auth.service)
                if let save {
                    try await BlockingIO.run { try save(updated) }
                } else {
                    let wrote = await BlockingIO.run {
                        CredentialReaders.writeClaudeCredential(service: auth.service, account: auth.account, json: patched)
                    }
                    guard wrote else { throw ProviderError.unreachable }
                    CredentialReaders.rememberClaudeAuth(updated)
                }
                return .wrote(updated)
            }
        )
    }

    private func performCodex(file: URL, now: Date, replacing: String?, persistsRecovery: Bool) async throws -> CredentialReaders.CodexAuth {
        try await renew(
            provider: .openai,
            now: now,
            replacing: replacing,
            persistsRecovery: persistsRecovery,
            read: { try await self.readCodex(file) },
            facts: { Facts(accessToken: $0.accessToken, refreshToken: $0.refreshToken, expiresAt: $0.expiresAt, canRefresh: $0.canRenew) },
            post: { auth in
                let payload = [
                    "client_id": OAuthRefresh.codexClientID,
                    "grant_type": "refresh_token",
                    "refresh_token": auth.refreshToken,
                ]
                guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                    return .unavailable
                }
                return await OAuthRefresh.post(
                    urls: [OAuthRefresh.codexTokenURL, OAuthRefresh.codexLegacyTokenURL],
                    body: body,
                    contentType: "application/json",
                    headers: [:]
                )
            },
            pendingFor: { auth, grant in
                LoginRecoveryPending(
                    accessToken: grant.accessToken,
                    refreshToken: grant.refreshToken ?? auth.refreshToken,
                    idToken: grant.idToken ?? (auth.idToken.isEmpty ? nil : auth.idToken),
                    expiresText: OAuthRefresh.timestamp(like: auth.lastRefreshText, date: now),
                    expiresAtMs: nil,
                    previousRefresh: auth.refreshToken
                )
            },
            apply: { auth, pending in
                guard auth.refreshToken == pending.previousRefresh else { return .moved(auth) }
                guard let lastRefresh = pending.expiresText else { throw ProviderError.unreachable }
                guard let patched = OAuthRefresh.patchCodex(
                    raw: auth.rawJSON,
                    accessToken: pending.accessToken,
                    refreshToken: pending.refreshToken,
                    idToken: pending.idToken,
                    lastRefresh: lastRefresh,
                    previousAccess: auth.accessToken,
                    previousRefresh: auth.refreshToken,
                    previousIDToken: auth.idToken,
                    previousLastRefresh: auth.lastRefreshText
                ) else { throw ProviderError.unreachable }
                try await self.writeText(patched, to: file)
                let written = try await self.readCodex(file)
                guard written.accessToken == pending.accessToken else { throw ProviderError.unreachable }
                return .wrote(written)
            }
        )
    }

    // MARK: Shared renewal

    private struct Facts: Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date?
        var canRefresh: Bool
    }

    private enum Applied<Auth: Sendable>: Sendable {
        case wrote(Auth)
        case moved(Auth)
    }

    private func renew<Auth: Sendable>(
        provider: Provider,
        now: Date,
        replacing: String?,
        persistsRecovery: Bool,
        read: () async throws -> Auth,
        facts: (Auth) -> Facts,
        post: (Auth) async -> OAuthRefresh.Outcome,
        pendingFor: (Auth, OAuthRefresh.Grant) -> LoginRecoveryPending,
        apply: (Auth, LoginRecoveryPending) async throws -> Applied<Auth>
    ) async throws -> Auth {
        var current = try await read()
        if let saved = await recall(provider, persists: persistsRecovery) {
            let fact = facts(current)
            if saved.previousRefresh == fact.refreshToken {
                if fact.accessToken == saved.accessToken, fact.refreshToken == saved.refreshToken {
                    await forget(provider, persists: persistsRecovery)
                    CredentialReaders.clearRenewalRejection(provider)
                    return current
                }
                do {
                    switch try await apply(current, saved) {
                    case .wrote(let updated):
                        await forget(provider, persists: persistsRecovery)
                        CredentialReaders.clearRenewalRejection(provider)
                        return updated
                    case .moved(let updated):
                        await forget(provider, persists: persistsRecovery)
                        current = updated
                    }
                } catch {
                    if OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now), fact.accessToken != replacing {
                        return current
                    }
                    throw ProviderError.unreachable
                }
            } else {
                await forget(provider, persists: persistsRecovery)
            }
        }

        current = try await read()
        if let ready = readySession(current, facts: facts, provider: provider, now: now, replacing: replacing) {
            return try ready.get()
        }

        var tries = 0
        while tries < 2 {
            tries += 1
            let exchanged = facts(current).refreshToken
            switch await post(current) {
            case .grant(let grant):
                let pending = pendingFor(current, grant)
                await remember(pending, provider: provider, persists: persistsRecovery)
                let latest = try await read()
                if facts(latest).refreshToken != exchanged {
                    if let adopted = adoptIfUsable(latest, facts: facts, replacing: replacing, now: now) {
                        await forget(provider, persists: persistsRecovery)
                        CredentialReaders.clearRenewalRejection(provider)
                        return adopted
                    }
                    current = latest
                    continue
                }
                do {
                    switch try await apply(latest, pending) {
                    case .wrote(let updated):
                        await forget(provider, persists: persistsRecovery)
                        CredentialReaders.clearRenewalRejection(provider)
                        return updated
                    case .moved(let updated):
                        if let adopted = adoptIfUsable(updated, facts: facts, replacing: replacing, now: now) {
                            await forget(provider, persists: persistsRecovery)
                            CredentialReaders.clearRenewalRejection(provider)
                            return adopted
                        }
                        current = updated
                        continue
                    }
                } catch {
                    Self.log.error("Renewal could not be written back for \(provider.rawValue, privacy: .public)")
                    throw ProviderError.unreachable
                }
            case .rejected:
                let latest = try await read()
                let latestFacts = facts(latest)
                if latestFacts.refreshToken != exchanged || latestFacts.accessToken != facts(current).accessToken {
                    if let adopted = adoptIfUsable(latest, facts: facts, replacing: replacing, now: now) {
                        CredentialReaders.clearRenewalRejection(provider)
                        return adopted
                    }
                    if latestFacts.refreshToken != exchanged, latestFacts.canRefresh {
                        current = latest
                        continue
                    }
                }
                CredentialReaders.noteRenewalRejected(provider, refreshToken: latestFacts.refreshToken)
                Self.log.error("Renewal was rejected for \(provider.rawValue, privacy: .public)")
                throw ProviderError.expired(provider.expiredHint)
            case .unavailable:
                let fact = facts(current)
                Self.log.error("Renewal did not connect for \(provider.rawValue, privacy: .public)")
                if OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now), fact.accessToken != replacing {
                    return current
                }
                throw ProviderError.unreachable
            }
        }
        CredentialReaders.noteRenewalRejected(provider, refreshToken: facts(current).refreshToken)
        throw ProviderError.expired(provider.expiredHint)
    }

    /// A session that should be used as it is, or an error when it can't be renewed.
    /// Nil means a refresh should be attempted.
    private func readySession<Auth>(
        _ auth: Auth,
        facts: (Auth) -> Facts,
        provider: Provider,
        now: Date,
        replacing: String?
    ) -> Result<Auth, ProviderError>? {
        let fact = facts(auth)
        if fact.accessToken.isEmpty {
            return .failure(.signedOut(provider.signInHint))
        }
        if let replacing, fact.accessToken != replacing, OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now) {
            return .success(auth)
        }
        let forced = replacing != nil && fact.accessToken == replacing
        if CredentialReaders.renewalIsRejected(provider, refreshToken: fact.refreshToken) {
            if !forced, OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now) {
                return .success(auth)
            }
            return .failure(.expired(provider.expiredHint))
        }
        let due = forced || OAuthRefresh.needsRefresh(expiresAt: fact.expiresAt, now: now, canRefresh: fact.canRefresh)
        if !due {
            if OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now) {
                return .success(auth)
            }
            return .failure(.expired(provider.expiredHint))
        }
        if !fact.canRefresh {
            if !forced, OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now) {
                return .success(auth)
            }
            return .failure(.expired(provider.expiredHint))
        }
        return nil
    }

    private func adoptIfUsable<Auth>(
        _ auth: Auth,
        facts: (Auth) -> Facts,
        replacing: String?,
        now: Date
    ) -> Auth? {
        let fact = facts(auth)
        guard OAuthRefresh.stillUsable(expiresAt: fact.expiresAt, now: now), fact.accessToken != replacing else { return nil }
        return auth
    }

    private func fly<Value: Sendable>(
        _ flight: LoginFlight<Value>,
        replacing: String?,
        access: (Value) -> String,
        work: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
        if let task = flight.task {
            let value = try await task.value
            if replacing == nil || access(value) != replacing {
                return value
            }
        }
        if let task = flight.task {
            let value = try await task.value
            if replacing == nil || access(value) != replacing {
                return value
            }
        }
        let id = UUID()
        let task = Task { try await work() }
        flight.task = task
        flight.id = id
        do {
            let value = try await task.value
            if flight.id == id {
                flight.task = nil
                flight.id = nil
            }
            return value
        } catch {
            if flight.id == id {
                flight.task = nil
                flight.id = nil
            }
            throw error
        }
    }

    private func readGrok(_ url: URL) async throws -> CredentialReaders.GrokAuth {
        try await BlockingIO.run { try CredentialReaders.grokAuth(at: url) }
    }

    private func readCodex(_ url: URL) async throws -> CredentialReaders.CodexAuth {
        try await BlockingIO.run { try CredentialReaders.codexAuth(at: url) }
    }

    /// Writes the whole file back, following a symlink so the link itself stays a link,
    /// and restores the mode an atomic replace would drop. Retries once.
    private func writeText(_ text: String, to url: URL) async throws {
        var last: Error = ProviderError.unreachable
        for _ in 0..<2 {
            do {
                try await BlockingIO.run {
                    let resolved = url.resolvingSymlinksInPath()
                    let permissions = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.posixPermissions]
                    try Data(text.utf8).write(to: resolved, options: .atomic)
                    if let permissions {
                        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolved.path)
                    }
                }
                return
            } catch {
                last = error
            }
        }
        throw last
    }

    private func recall(_ provider: Provider, persists: Bool) async -> LoginRecoveryPending? {
        if let saved = memory[provider.rawValue] { return saved }
        guard persists else { return nil }
        let saved = await BlockingIO.run { LoginRecovery.load(account: provider.rawValue) }
        if let saved { memory[provider.rawValue] = saved }
        return saved
    }

    private func remember(_ pending: LoginRecoveryPending, provider: Provider, persists: Bool) async {
        memory[provider.rawValue] = pending
        guard persists else { return }
        await BlockingIO.run { _ = LoginRecovery.save(account: provider.rawValue, pending: pending) }
    }

    private func forget(_ provider: Provider, persists: Bool) async {
        memory[provider.rawValue] = nil
        guard persists else { return }
        await BlockingIO.run { LoginRecovery.delete(account: provider.rawValue) }
    }
}

/// Tokenroom's own Keychain item. It is not synced, and it is deleted once the CLI file is updated.
/// A team-signed build keeps it in the data-protection keychain, off the legacy lock. An item
/// 2.2.1 saved in the login keychain is still read. The login-keychain query is never used to
/// delete after the data-protection write: that query can match the item just added.
private enum LoginRecovery {
    static let service = "app.tokenroom.mac.login-recovery"

    static func load(account: String) -> LoginRecoveryPending? {
        if KeychainAvailability.dataProtection, let pending = read(account: account, dataProtection: true) {
            return pending
        }
        return read(account: account, dataProtection: false)
    }

    static func save(account: String, pending: LoginRecoveryPending) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        if KeychainAvailability.dataProtection, write(account: account, data: data, dataProtection: true) {
            return true
        }
        return write(account: account, data: data, dataProtection: false)
    }

    static func delete(account: String) {
        if KeychainAvailability.dataProtection {
            _ = KeychainGate.delete(quiet(base(account: account, dataProtection: true)))
        }
        _ = KeychainGate.delete(quiet(base(account: account, dataProtection: false)))
    }

    private static func read(account: String, dataProtection: Bool) -> LoginRecoveryPending? {
        var query = quiet(base(account: account, dataProtection: dataProtection))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = KeychainGate.copyMatching(query)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(LoginRecoveryPending.self, from: data)
    }

    private static func write(account: String, data: Data, dataProtection: Bool) -> Bool {
        let query = quiet(base(account: account, dataProtection: dataProtection))
        if KeychainGate.update(query, [kSecValueData as String: data]) == errSecSuccess {
            return true
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return KeychainGate.add(add) == errSecSuccess
    }

    private static func base(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func quiet(_ query: [String: Any]) -> [String: Any] {
        var query = query
        query[kSecUseAuthenticationContext as String] = quietContext()
        return query
    }

    private static func quietContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
