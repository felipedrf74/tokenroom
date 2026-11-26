import Foundation
import LocalAuthentication
import os
import Security

enum CredentialReaders {
    static var grokHome: URL {
        if let override = ProcessInfo.processInfo.environment["GROK_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }

    static var grokAuthURL: URL {
        grokHome.appendingPathComponent("auth.json")
    }

    static var codexHome: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static var cursorDatabaseURL: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENROOM_CURSOR_DB"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static var grokBotSupportURL: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENROOM_GROK_BOT_SUPPORT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot")
    }

    static var grokBotSecretsURL: URL {
        grokBotSupportURL.appendingPathComponent("sand-secrets.json")
    }

    static var grokBotStatusURL: URL {
        grokBotSupportURL.appendingPathComponent("desktop-status.json")
    }

    struct GrokAuth: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var userID: String?
        var refreshToken: String = ""
        var clientID: String = ""
        var issuer: String = ""
        var mapKey: String = ""
        var expiresText: String = ""
        var rawJSON: String = ""
    }

    struct CodexAuth: Sendable {
        var accessToken: String
        var accountID: String?
        var refreshToken: String = ""
        var idToken: String = ""
        var expiresAt: Date? = nil
        var lastRefreshText: String = ""
        var rawJSON: String = ""
    }

    static func grokAuth(at url: URL? = nil) throws -> GrokAuth {
        let url = url ?? grokAuthURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ProviderError.unreachable
        }
        let root = try JSONFlex.object(from: data)
        var newest: (key: String, entry: [String: Any], created: Date)?
        for (key, value) in root {
            guard let entry = JSONFlex.dictionary(value),
                  let access = JSONFlex.string(entry["key"]), !access.isEmpty
            else { continue }
            let created = JSONFlex.parseISO(JSONFlex.string(entry["create_time"]) ?? "") ?? .distantPast
            if newest == nil || created >= newest!.created {
                newest = (key, entry, created)
            }
        }
        guard let newest else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        let issuer = JSONFlex.string(newest.entry["oidc_issuer"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expiresText = JSONFlex.string(newest.entry["expires_at"]) ?? ""
        return GrokAuth(
            accessToken: JSONFlex.string(newest.entry["key"]) ?? "",
            expiresAt: JSONFlex.parseISO(expiresText),
            userID: JSONFlex.string(newest.entry["user_id"]),
            refreshToken: JSONFlex.string(newest.entry["refresh_token"]) ?? "",
            clientID: JSONFlex.string(newest.entry["oidc_client_id"]) ?? "",
            issuer: issuer.isEmpty ? "https://auth.x.ai" : issuer,
            mapKey: newest.key,
            expiresText: expiresText,
            rawJSON: raw
        )
    }

    static func usableGrokToken(_ auth: GrokAuth, now: Date = .now) throws -> String {
        guard !auth.accessToken.isEmpty else {
            throw ProviderError.signedOut(Provider.grok.signInHint)
        }
        if let expiresAt = auth.expiresAt, expiresAt.timeIntervalSince(now) <= 60 {
            throw ProviderError.expired(Provider.grok.expiredHint)
        }
        return auth.accessToken
    }

    static func hasSession(_ provider: Provider) -> Bool {
        sessionStamp(provider) != nil
    }

    static func hasUsableSession(_ provider: Provider) -> Bool {
        switch provider {
        case .claude:
            guard let auth = try? claudeAuth() else { return false }
            return auth.countsAsUsableSession()
        case .grok:
            guard let auth = try? grokAuth() else { return false }
            return auth.countsAsUsableSession()
        case .openai:
            guard let auth = try? codexAuth() else { return false }
            return auth.countsAsUsableSession()
        case .grokBot:
            guard let session = try? GrokBotCredentials.read() else { return false }
            return session.isNative ? !GrokBotCredentials.wasRefused(session.token) : hasUsableCursorSession()
        case .cursor:
            return hasUsableCursorSession()
        default:
            return hasSession(provider)
        }
    }

    static let apiKeys = APIKeyStore()

    static func sessionStamp(_ provider: Provider) -> String? {
        switch provider {
        case .grok:
            return fileStamp(grokAuthURL)
        case .openai:
            return fileStamp(codexHome.appendingPathComponent("auth.json"))
        case .cursor:
            return cursorSessionStamp()
        case .grokBot:
            let parts = [
                cursorSessionStamp(),
                fileStamp(grokBotSecretsURL),
                fileStamp(grokBotStatusURL),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "|")
        case .claude:
            guard let raw = readClaudeRawFromKeychain() else { return nil }
            let checksum = raw.utf8.reduce(into: 0) { sum, byte in sum = sum &+ Int(byte) }
            return "\(raw.count)-\(checksum)"
        case .copilot:
            return CopilotCredentials.sessionStamp()
        case .antigravity:
            return AntigravityClient.sessionStamp()
        case .devin:
            return DevinCredentials.sessionStamp()
        case .zai, .kimiCode, .minimax, .opencodeGo:
            return pastedKeyStamp(provider) ?? LocalKeys.sourceFile(for: provider).flatMap(fileStamp)
        case .openrouter, .deepseek, .moonshot, .vercelGateway, .openaiOrg, .anthropicOrg, .xaiOrg:
            return pastedKeyStamp(provider)
        }
    }

    private static func pastedKeyStamp(_ provider: Provider) -> String? {
        apiKeys.metadata(for: provider).map { "\($0.last4)-\(Int($0.addedAt.timeIntervalSince1970))" }
    }

    static func invalidateCaches() {
        claudeCache.withLock { $0 = nil }
        cursorCache.withLock { $0 = nil }
        CopilotCredentials.invalidate()
    }

    static func invalidateKeychainServices() {
        claudeServicesCache.withLock { $0 = nil }
    }

    private static func fileStamp(_ url: URL) -> String? {
        LocalSources.fileStamp(url)
    }

    static func codexAuth(at url: URL? = nil) throws -> CodexAuth {
        let url = url ?? codexHome.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.signedOut(Provider.openai.signInHint)
        }
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ProviderError.unreachable
        }
        let object = try JSONFlex.object(from: data)
        let tokens = JSONFlex.dictionary(object["tokens"]) ?? [:]
        guard let access = JSONFlex.string(tokens["access_token"]), !access.isEmpty else {
            throw ProviderError.signedOut(Provider.openai.signInHint)
        }
        return CodexAuth(
            accessToken: access,
            accountID: JSONFlex.string(tokens["account_id"]),
            refreshToken: JSONFlex.string(tokens["refresh_token"]) ?? "",
            idToken: JSONFlex.string(tokens["id_token"]) ?? "",
            expiresAt: jwtExpiry(access),
            lastRefreshText: JSONFlex.string(object["last_refresh"]) ?? "",
            rawJSON: raw
        )
    }

    struct ClaudeAuth: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAtMs: Double?
        var refreshExpiresAtMs: Double?
        var rawJSON: String
        var account: String
        var service: String

        func isExpired(at now: Date) -> Bool {
            guard let expiresAtMs else { return false }
            return now.timeIntervalSince1970 * 1000 >= expiresAtMs - 60_000
        }

        var isExpired: Bool { isExpired(at: Date()) }

        func canRefresh(at now: Date) -> Bool {
            guard let refreshToken, !refreshToken.isEmpty else { return false }
            if let refreshExpiresAtMs {
                return now.timeIntervalSince1970 * 1000 < refreshExpiresAtMs - 60_000
            }
            return true
        }

        var canRefresh: Bool { canRefresh(at: Date()) }

        func countsAsUsableSession(now: Date = .now) -> Bool {
            guard !accessToken.isEmpty else { return false }
            if CredentialReaders.renewalIsRejected(.claude, refreshToken: refreshToken ?? "") {
                return !isExpired(at: now)
            }
            return !isExpired(at: now) || (canRefresh(at: now) && CredentialReaders.claudeLoginCanBeRenewedInPlace(self))
        }
    }

    static let claudeKeychainService = "Claude Code-credentials"
    private static let keychainServicesTTL: TimeInterval = 600
    private static let claudeAgentTTL: TimeInterval = 3600

    private static let claudeCache = OSAllocatedUnfairLock<ClaudeAuth?>(initialState: nil)
    private static let claudeServicesCache = OSAllocatedUnfairLock<(names: [String], readAt: Date)?>(initialState: nil)
    private static let claudeAgentCache = OSAllocatedUnfairLock<(value: String, readAt: Date)?>(initialState: nil)
    private static let cursorCache = OSAllocatedUnfairLock<(token: String, readAt: Date)?>(initialState: nil)

    static func claudeUserAgent() -> String {
        if let cached = claudeAgentCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < claudeAgentTTL {
            return cached.value
        }
        let value = claudeUserAgent(forCLI: Tooling.resolveClaude())
        claudeAgentCache.withLock { $0 = (value, Date()) }
        return value
    }

    static func claudeUserAgent(forCLI cli: URL?) -> String {
        if let version = cli.flatMap(claudeVersion(of:)) {
            return "claude-cli/\(version) (external, cli)"
        }
        return "claude-cli (external, cli)"
    }

    static func claudeVersion(of cli: URL) -> String? {
        cli.resolvingSymlinksInPath().pathComponents.reversed().first(where: isVersionString)
    }

    private static func isVersionString(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }

    static func claudeAuth() throws -> ClaudeAuth {
        if let cached = claudeCache.withLock({ $0 }), !cached.isExpired {
            return cached
        }
        let account = NSUserName()
        if let found = readBestClaudeCredential(account: account) {
            claudeCache.withLock { $0 = found.auth }
            return found.auth
        }
        claudeCache.withLock { $0 = nil }
        throw ProviderError.signedOut(Provider.claude.signInHint)
    }

    private static func readClaudeRawFromKeychain() -> String? {
        readBestClaudeCredential(account: NSUserName())?.auth.rawJSON
    }

    private static func readBestClaudeCredential(account: String) -> (raw: String, auth: ClaudeAuth)? {
        var best: (raw: String, auth: ClaudeAuth)?
        for service in claudeCredentialServices() {
            guard let secret = readClaudeSecret(service: service, account: account) else { continue }
            guard let auth = try? parseClaudeAuth(secret.value, account: secret.account ?? "", service: service) else { continue }
            if best == nil || claudeAuthIsBetter(auth, than: best!.auth) {
                best = (secret.value, auth)
            }
        }
        return best
    }

    enum SecurityPasswordResult: Equatable, Sendable {
        case value(String)
        case missing
        case unavailable
    }

    struct ClaudeSecret: Equatable {
        var value: String
        var account: String?
    }

    static func readClaudeSecret(
        service: String,
        account: String,
        access: (String) -> ClaudeKeyAccess = { claudeKeyAccess(service: $0) },
        silent: (String, String?) -> String? = { keychainPassword(service: $0, account: $1, promptAllowed: false) },
        security: (String, String?) -> SecurityPasswordResult = { securityPassword(service: $0, account: $1) },
        itemAccount: (String) -> String? = { securityAccount(service: $0) }
    ) -> ClaudeSecret? {
        _ = silent
        let policy = access(service)
        guard policy.trustsSecurityTool else { return nil }
        switch security(service, account) {
        case .value(let value):
            return present(value).map { ClaudeSecret(value: $0, account: account) }
        case .missing:
            guard !account.isEmpty else { return nil }
            guard case .value(let value) = security(service, nil), let value = present(value) else { return nil }
            let filed = itemAccount(service).flatMap { $0.isEmpty ? nil : $0 }
            return ClaudeSecret(value: value, account: filed)
        case .unavailable:
            return nil
        }
    }

    enum UnusableClaudeItem: Error, Equatable {
        case notALogin
        case untrusted
    }

    static func claudeItem(
        service: String,
        account: String,
        exists: (String, String) -> Bool? = { claudeItemExists(service: $0, account: $1) },
        access: ((String) -> ClaudeKeyAccess)? = nil,
        security: (String, String?) -> SecurityPasswordResult = { securityPassword(service: $0, account: $1) }
    ) throws -> ClaudeAuth? {
        guard !account.isEmpty else { throw ProviderError.unreachable }
        if exists(service, account) == false { return nil }
        let policy = access.map { $0(service) } ?? claudeKeyAccess(service: service, account: account)
        guard policy.trustsSecurityTool else {
            if policy.wasRead { throw UnusableClaudeItem.untrusted }
            throw ProviderError.unreachable
        }
        switch security(service, account) {
        case .value(let value):
            guard let raw = present(value) else { throw ProviderError.unreachable }
            do {
                return try parseClaudeAuth(raw, account: account, service: service)
            } catch {
                throw UnusableClaudeItem.notALogin
            }
        case .missing:
            return nil
        case .unavailable:
            throw ProviderError.unreachable
        }
    }

    static func claudeItemExists(service: String, account: String) -> Bool? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context,
        ]
        switch KeychainGate.copyMatching(query).0 {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil
        }
    }

    static func securityAccount(service: String, keychain: String? = nil) -> String? {
        var args = ["find-generic-password", "-s", service]
        if let keychain {
            args.append(keychain)
        }
        let output = KeychainGate.sync {
            BlockingIO.runProcess(URL(fileURLWithPath: "/usr/bin/security"), arguments: args)
        }
        guard output.succeeded, let text = String(data: output.stdout, encoding: .utf8) else { return nil }
        return accountAttribute(inSecurityOutput: text)
    }

    static func accountAttribute(inSecurityOutput text: String) -> String? {
        let prefix = "\"acct\"<blob>="
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
            if value.hasPrefix("0x") {
                let hex = value.dropFirst(2).prefix(while: \.isHexDigit)
                guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
                var bytes = Data(capacity: hex.count / 2)
                var index = hex.startIndex
                while index < hex.endIndex {
                    let next = hex.index(index, offsetBy: 2)
                    guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                    bytes.append(byte)
                    index = next
                }
                return String(data: bytes, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            }
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            let name = String(value.dropFirst().dropLast())
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func present(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isSecurityToolPartition(_ partition: String) -> Bool {
        partition == "apple-tool:" || partition.hasPrefix("apple-tool:")
    }

    struct ClaudeKeyAccess: Equatable {
        var partitions: [String] = []
        var hasPartitionList: Bool = false
        var trustedPaths: [String] = []
        var allowsSecurityToolDecryption: Bool = false
        var trustsThisApp: Bool = false
        var wasRead: Bool = false

        var trustsSecurityTool: Bool {
            if hasPartitionList {
                return partitions.contains(where: CredentialReaders.isSecurityToolPartition)
            }
            return trustedPaths.contains("/usr/bin/security")
        }
    }

    static func claudeKeyAccess(service: String, account: String? = nil) -> ClaudeKeyAccess {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let (status, item) = KeychainGate.copyMatching(query)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeychainItemGetTypeID() else {
            return ClaudeKeyAccess()
        }
        var access: SecAccess?
        guard SecKeychainItemCopyAccess(item as! SecKeychainItem, &access) == errSecSuccess, let access else {
            return ClaudeKeyAccess()
        }
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else {
            return ClaudeKeyAccess()
        }
        var found = ClaudeKeyAccess(wasRead: true)
        for acl in acls {
            let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
            let isPartition = authorizations.contains(kSecACLAuthorizationPartitionID as String)
            let allowsRead = authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String)
                || authorizations.contains(kSecACLAuthorizationKeychainItemRead as String)
            let allowsDecrypt = authorizations.contains(kSecACLAuthorizationDecrypt as String)
                || authorizations.contains(kSecACLAuthorizationAny as String)
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            if isPartition { found.hasPartitionList = true }
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { continue }
            if isPartition, let text = description as String? {
                found.hasPartitionList = true
                found.partitions.append(contentsOf: partitions(inACLDescription: text))
            }
            if allowsDecrypt, apps == nil { found.allowsSecurityToolDecryption = true }
            guard allowsRead, let apps else { continue }
            for index in 0..<CFArrayGetCount(apps) {
                guard let raw = CFArrayGetValueAtIndex(apps, index) else { continue }
                let app = Unmanaged<SecTrustedApplication>.fromOpaque(raw).takeUnretainedValue()
                var data: CFData?
                guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess, let data = data as Data?,
                      let path = trustedApplicationPath(from: data)
                else { continue }
                found.trustedPaths.append(path)
                if allowsDecrypt, path == "/usr/bin/security" { found.allowsSecurityToolDecryption = true }
            }
        }
        if found.hasPartitionList {
            if let team = signingTeamID {
                found.trustsThisApp = found.partitions.contains("teamid:\(team)")
            }
        } else {
            found.trustsThisApp = found.trustedPaths.contains(where: pathTrustsThisApp)
        }
        return found
    }

    static func trustedApplicationPath(from data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        guard let path = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    private static func pathTrustsThisApp(_ path: String) -> Bool {
        let trusted = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        return trusted == bundle || trusted.hasPrefix(bundle + "/")
    }

    private static let signingTeamID: String? = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else { return nil }
        return team
    }()

    static func partitions(inACLDescription description: String) -> [String] {
        var texts = [description]
        if let decoded = hexDecoded(description) {
            texts.append(decoded)
        }
        for text in texts {
            guard let data = text.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let parts = plist["Partitions"] as? [String]
            else { continue }
            return parts
        }
        return []
    }

    private static func hexDecoded(_ hex: String) -> String? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count >= 8, cleaned.count.isMultiple(of: 2), cleaned.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8)
    }

    private static func claudeAuthIsBetter(_ candidate: ClaudeAuth, than current: ClaudeAuth) -> Bool {
        func rank(_ auth: ClaudeAuth) -> Int {
            if !auth.accessToken.isEmpty, !auth.isExpired { return 3 }
            if auth.canRefresh { return 2 }
            if !auth.accessToken.isEmpty { return 1 }
            return 0
        }
        let candidateRank = rank(candidate)
        let currentRank = rank(current)
        if candidateRank != currentRank { return candidateRank > currentRank }
        return (candidate.expiresAtMs ?? 0) > (current.expiresAtMs ?? 0)
    }

    private static func claudeCredentialServices() -> [String] {
        if let cached = claudeServicesCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < keychainServicesTTL {
            return cached.names
        }
        var names = Set<String>([claudeKeychainService])
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
            kSecUseAuthenticationContext as String: context,
        ]
        let (status, result) = KeychainGate.copyMatching(query)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let service = item[kSecAttrService as String] as? String else { continue }
                if service == claudeKeychainService || service.hasPrefix("\(claudeKeychainService)-") {
                    names.insert(service)
                }
            }
        }
        let list = names.sorted()
        claudeServicesCache.withLock { $0 = (list, Date()) }
        return list
    }

    static func securityGenericPassword(service: String, account: String?) -> String? {
        guard case .value(let value) = securityPassword(service: service, account: account) else { return nil }
        return value
    }

    static func securityPassword(
        service: String,
        account: String?,
        keychain: String? = nil,
        promptAllowed: Bool = false,
        run: @escaping (URL, [String], TimeInterval) -> BlockingIO.ProcessOutput = {
            BlockingIO.runProcess($0, arguments: $1, timeout: $2)
        }
    ) -> SecurityPasswordResult {
        var args = ["find-generic-password", "-s", service, "-w"]
        if let account {
            args.insert(contentsOf: ["-a", account], at: 3)
        }
        if let keychain {
            args.append(keychain)
        }
        let read = {
            run(URL(fileURLWithPath: "/usr/bin/security"), args, promptAllowed ? 180 : 5)
        }
        let output = promptAllowed ? read() : KeychainGate.sync(read)
        if !output.timedOut, output.status == 44 { return .missing }
        guard output.succeeded, let text = String(data: output.stdout, encoding: .utf8) else { return .unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unavailable : .value(trimmed)
    }

    static func grokBotStoragePassword(
        promptAllowed: Bool = false,
        access: (String) -> ClaudeKeyAccess = { claudeKeyAccess(service: $0) },
        read: (String, Bool) -> SecurityPasswordResult = { securityPassword(service: $0, account: nil, promptAllowed: $1) }
    ) -> String? {
        let service = GrokBotCredentials.storageService
        if !promptAllowed {
            let policy = access(service)
            guard policy.wasRead, policy.allowsSecurityToolDecryption,
                  !policy.hasPartitionList || policy.partitions.contains(where: isSecurityToolPartition)
            else { return nil }
        }
        guard case .value(let password) = read(service, promptAllowed) else { return nil }
        return present(password)
    }

    static func hasUsableCursorSession() -> Bool {
        guard let token = try? cursorAccessToken() else { return false }
        return refusedCursorToken.withLock { $0 != fingerprint(token) }
    }

    static func cursorAccessToken(
        keychain: (String) -> String? = { keychainPassword(service: $0, promptAllowed: false) },
        database: URL = cursorDatabaseURL,
        usesCache: Bool = true,
        now: Date = .now
    ) throws -> String {
        if usesCache, let cached = cursorCache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < 20 {
            return cached.token
        }
        let stored = keychain(cursorKeychainService).flatMap { $0.isEmpty ? nil : $0 }
        lastKeychainCursorToken.withLock { $0 = stored.map(fingerprint) }
        let refused = stored.map { stored in refusedCursorToken.withLock { $0 == fingerprint(stored) } } ?? false
        var token = stored
        if refused || stored.map({ tokenHasExpired($0, now: now) }) ?? true,
           let saved = LocalSources.vscodeState("cursorAuth/accessToken", database: database),
           stored == nil || !tokenHasExpired(saved, now: now) {
            token = saved
        }
        guard let token else { throw ProviderError.signedOut(Provider.cursor.signInHint) }
        if usesCache { cursorCache.withLock { $0 = (token, Date()) } }
        return token
    }

    static func cursorTokenAfterRefusal(of refused: String, database: URL = cursorDatabaseURL, now: Date = .now) -> String? {
        if lastKeychainCursorToken.withLock({ $0 == fingerprint(refused) }) {
            refusedCursorToken.withLock { $0 = fingerprint(refused) }
        }
        guard let saved = LocalSources.vscodeState("cursorAuth/accessToken", database: database),
              saved != refused, !tokenHasExpired(saved, now: now)
        else { return nil }
        cursorCache.withLock { $0 = (saved, Date()) }
        return saved
    }

    private static let refusedCursorToken = OSAllocatedUnfairLock<Int?>(initialState: nil)
    private static let lastKeychainCursorToken = OSAllocatedUnfairLock<Int?>(initialState: nil)

    static func forgetCursorRefusal() {
        refusedCursorToken.withLock { $0 = nil }
        lastKeychainCursorToken.withLock { $0 = nil }
    }

    private static func fingerprint(_ token: String) -> Int {
        var hasher = Hasher()
        hasher.combine(token)
        return hasher.finalize()
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONFlex.object(from: data),
              let expiry = JSONFlex.number(claims["exp"])
        else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    static func tokenHasExpired(_ token: String, now: Date = .now) -> Bool {
        guard let expiry = jwtExpiry(token) else { return false }
        return expiry <= now
    }

    static let cursorKeychainService = "cursor-access-token"

    private static func cursorSessionStamp() -> String? {
        let db = fileStamp(cursorDatabaseURL)
        let wal = fileStamp(URL(fileURLWithPath: cursorDatabaseURL.path + "-wal"))
        if db == nil, wal == nil { return nil }
        return [db, wal].compactMap { $0 }.joined(separator: ":")
    }

    static func keychainPassword(service: String, account: String? = nil, promptAllowed: Bool = true) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !promptAllowed {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            query[kSecUseAuthenticationContext as String] = context
        }
        if let account {
            query[kSecAttrAccount as String] = account
        }
        let (status, item) = KeychainGate.copyMatching(query)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseClaudeAuth(_ raw: String, account: String, service: String) throws -> ClaudeAuth {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            let object = try JSONFlex.object(from: data)
            let nested = JSONFlex.dictionary(object["claudeAiOauth"]) ?? object
            guard let token = JSONFlex.string(nested["accessToken"]) ?? JSONFlex.string(nested["access_token"]),
                  !token.isEmpty
            else {
                throw ProviderError.signedOut(Provider.claude.signInHint)
            }
            return ClaudeAuth(
                accessToken: token,
                refreshToken: JSONFlex.string(nested["refreshToken"]) ?? JSONFlex.string(nested["refresh_token"]),
                expiresAtMs: JSONFlex.number(nested["expiresAt"]) ?? JSONFlex.number(nested["expires_at"]),
                refreshExpiresAtMs: JSONFlex.number(nested["refreshTokenExpiresAt"])
                    ?? JSONFlex.number(nested["refresh_token_expires_at"]),
                rawJSON: trimmed,
                account: account,
                service: service
            )
        }
        if !trimmed.isEmpty {
            return ClaudeAuth(
                accessToken: trimmed,
                refreshToken: nil,
                expiresAtMs: nil,
                refreshExpiresAtMs: nil,
                rawJSON: trimmed,
                account: account,
                service: service
            )
        }
        throw ProviderError.signedOut(Provider.claude.signInHint)
    }

    static func parseClaudeToken(_ raw: String) throws -> String {
        try parseClaudeAuth(raw, account: NSUserName(), service: claudeKeychainService).accessToken
    }

    static func cachedClaudeAuth() -> ClaudeAuth? {
        claudeCache.withLock { $0 }
    }

    static func rememberClaudeAuth(_ auth: ClaudeAuth) {
        claudeCache.withLock { $0 = auth }
    }

    static func claudeLoginCanBeRenewedInPlace(_ auth: ClaudeAuth) -> Bool {
        !auth.account.isEmpty
    }

    static let securityInteractiveLineLimit = 4096 - 64

    struct ClaudeSecurityUpdate: Equatable {
        var arguments: [String]
        var stdin: Data?
    }

    static func claudeSecurityUpdate(service: String, account: String, json: String, keychain: String? = nil) -> ClaudeSecurityUpdate {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        var line = "add-generic-password -U -a \(securityInteractiveQuoted(account)) -s \(securityInteractiveQuoted(service)) -X \(hex)"
        if let keychain {
            line += " \(securityInteractiveQuoted(keychain))"
        }
        line += "\n"
        if line.utf8.count <= securityInteractiveLineLimit {
            return ClaudeSecurityUpdate(arguments: ["-i"], stdin: Data(line.utf8))
        }
        var arguments = ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]
        if let keychain {
            arguments.append(keychain)
        }
        return ClaudeSecurityUpdate(arguments: arguments, stdin: nil)
    }

    static func securityInteractiveQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func writeClaudeCredential(service: String, account: String, json: String, keychain: String? = nil) -> Bool {
        guard !json.isEmpty, !account.isEmpty else { return false }
        let update = claudeSecurityUpdate(service: service, account: account, json: json, keychain: keychain)
        let output = KeychainGate.sync {
            BlockingIO.runProcess(
                URL(fileURLWithPath: "/usr/bin/security"),
                arguments: update.arguments,
                input: update.stdin
            )
        }
        guard output.succeeded else { return false }
        guard case .value(let stored) = securityPassword(service: service, account: account, keychain: keychain) else {
            return false
        }
        return stored == json
    }

    private static let rejectedRefresh = OSAllocatedUnfairLock<[Provider: Int]>(initialState: [:])

    static func noteRenewalRejected(_ provider: Provider, refreshToken: String) {
        guard !refreshToken.isEmpty else { return }
        rejectedRefresh.withLock { $0[provider] = fingerprint(refreshToken) }
    }

    static func clearRenewalRejection(_ provider: Provider) {
        rejectedRefresh.withLock { $0[provider] = nil }
    }

    static func renewalIsRejected(_ provider: Provider, refreshToken: String) -> Bool {
        guard !refreshToken.isEmpty else { return false }
        return rejectedRefresh.withLock { $0[provider] == fingerprint(refreshToken) }
    }
}

extension CredentialReaders.GrokAuth {
    var canRenew: Bool {
        guard !refreshToken.isEmpty, !clientID.isEmpty, !issuer.isEmpty else { return false }
        return OAuthRefresh.grokTokenURL(issuer: issuer) != nil
    }

    func countsAsUsableSession(now: Date = .now) -> Bool {
        let accessOK = (try? CredentialReaders.usableGrokToken(self, now: now)) != nil
        if CredentialReaders.renewalIsRejected(.grok, refreshToken: refreshToken) {
            return accessOK
        }
        return accessOK || canRenew
    }
}

extension CredentialReaders.CodexAuth {
    var canRenew: Bool { !refreshToken.isEmpty }

    func countsAsUsableSession(now: Date = .now) -> Bool {
        guard !accessToken.isEmpty else { return false }
        let expired = CredentialReaders.tokenHasExpired(accessToken, now: now)
        if CredentialReaders.renewalIsRejected(.openai, refreshToken: refreshToken) {
            return !expired
        }
        return !expired || canRenew
    }
}
