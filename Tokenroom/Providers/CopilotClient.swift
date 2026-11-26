import Foundation
import Synchronization

struct CopilotClient: ProviderClient {
    let provider = Provider.copilot
    static let userURL = URL(string: "https://api.github.com/copilot_internal/user")!
    var keys = CredentialReaders.apiKeys

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let login = await BlockingIO.run({ CopilotCredentials.token() })
        var failure = ProviderError.signedOut(provider.signInHint)
        if let token = login {
            var status: Int?
            do {
                let request = TokenroomHTTP.request(Self.userURL, token: nil, headers: ["Authorization": "token \(token)"])
                let (data, response) = try await TokenroomHTTP.data(for: request)
                status = response.statusCode
                try TokenroomHTTP.check(response, provider: provider)
                return .success(try CopilotParser.snapshot(from: data))
            } catch let error as ProviderError {
                if case .expired = error {
                    CopilotCredentials.invalidate()
                }
                failure = error
            } catch {
                failure = .unreachable
            }
            guard Self.fallsBack(after: failure, status: status) else { return .failure(failure) }
        }
        let keys = self.keys
        guard let pasted = await BlockingIO.run({ keys.key(for: .copilot).map { ($0, keys.metadata(for: .copilot)?.region) } }) else {
            return .failure(failure)
        }
        do {
            var snapshot = try await APIKeyClient.copilotSnapshot(key: pasted.0, planName: pasted.1)
            snapshot.source = "copilot-token"
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    static func fallsBack(after failure: ProviderError, status: Int?) -> Bool {
        switch failure {
        case .expired, .signedOut, .notEntitled, .parse:
            true
        default:
            status.map { [400, 404, 422].contains($0) } ?? false
        }
    }
}

enum CopilotParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now, calendar: Calendar = .gregorianUTC) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let resetsAt = JSONFlex.date(root["quota_reset_date_utc"])
            ?? JSONFlex.date(root["quota_reset_date"])
            ?? JSONFlex.date(root["limited_user_reset_date"])
        let startsAt = resetsAt.flatMap { calendar.date(byAdding: .month, value: -1, to: $0) }

        var windows: [QuotaWindow] = []
        if let snapshots = JSONFlex.dictionary(root["quota_snapshots"]) {
            let credits = (root["token_based_billing"] as? Bool) == true
            for (id, title, unit) in buckets {
                let named = id == "premium_interactions" && credits ? (title: "AI credits", unit: "credits") : (title: title, unit: unit)
                guard let bucket = JSONFlex.dictionary(snapshots[id]),
                      let window = window(bucket, id: id, title: named.title, unit: named.unit, resetsAt: resetsAt, startsAt: startsAt)
                else { continue }
                windows.append(window)
            }
        } else if let left = JSONFlex.dictionary(root["limited_user_quotas"]),
                  let limits = JSONFlex.dictionary(root["monthly_quotas"]) {
            for (id, title, unit) in buckets {
                guard let limit = JSONFlex.number(limits[id]), limit > 0, let remaining = JSONFlex.number(left[id]) else { continue }
                windows.append(QuotaWindow(
                    id: id, kind: .monthly, title: title,
                    usedPercent: JSONFlex.clampPercent((limit - remaining) / limit * 100),
                    resetsAt: resetsAt, startsAt: startsAt,
                    amount: QuotaAmount(used: limit - remaining, limit: limit, remaining: remaining, unit: unit)
                ))
            }
        }
        guard !windows.isEmpty else {
            throw ProviderError.notEntitled("Copilot didn't report a monthly quota for this account.")
        }
        return try .headlined(by: windows, provider: .copilot, fetchedAt: fetchedAt, planLabel: planLabel(root))
    }

    static let buckets: [(id: String, title: String, unit: String)] = [
        ("premium_interactions", "Premium requests", "requests"),
        ("chat", "Chat", "messages"),
        ("completions", "Completions", "completions"),
    ]

    static func window(_ bucket: [String: Any], id: String, title: String, unit: String, resetsAt: Date?, startsAt: Date?) -> QuotaWindow? {
        let entitlement = JSONFlex.number(bucket["entitlement"])
        let remaining = JSONFlex.number(bucket["remaining"]) ?? JSONFlex.number(bucket["quota_remaining"])
        if (bucket["unlimited"] as? Bool) == true || entitlement == -1 {
            return nil
        }
        guard let entitlement, entitlement > 0 else { return nil }
        let percentLeft = JSONFlex.number(bucket["percent_remaining"]) ?? remaining.map { $0 / entitlement * 100 }
        guard let percentLeft else { return nil }
        return QuotaWindow(
            id: id, kind: .monthly, title: title,
            usedPercent: JSONFlex.clampPercent(100 - percentLeft),
            resetsAt: resetsAt, startsAt: startsAt,
            amount: remaining.map { QuotaAmount(used: entitlement - $0, limit: entitlement, remaining: max($0, 0), unit: unit) }
        )
    }

    static func planLabel(_ root: [String: Any]) -> String? {
        let sku = JSONFlex.string(root["access_type_sku"])?.lowercased() ?? ""
        let plan = JSONFlex.string(root["copilot_plan"])?.lowercased() ?? ""
        let name: String? = if sku.contains("free") {
            "Free"
        } else if sku.contains("educat") {
            "Pro (Education)"
        } else if sku.contains("plus") || plan.contains("pro_plus") {
            "Pro+"
        } else if sku.contains("enterprise") || plan == "enterprise" {
            "Enterprise"
        } else if sku.contains("business") || plan == "business" {
            "Business"
        } else if sku.contains("subscriber") {
            "Pro"
        } else if !plan.isEmpty {
            plan.replacingOccurrences(of: "_", with: " ").capitalized
        } else {
            nil
        }
        return name.map { "Copilot \($0)" }
    }
}

enum CopilotCredentials {
    private static let cache = Mutex<(token: String, readAt: Date)?>(nil)
    static let cacheTTL: TimeInterval = 5 * 60

    static var configDirectory: URL {
        if let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !config.isEmpty {
            return URL(fileURLWithPath: config, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
    }

    static func token(configDirectory: URL = CopilotCredentials.configDirectory) -> String? {
        if let cached = cache.withLock({ $0 }), Date().timeIntervalSince(cached.readAt) < cacheTTL {
            return cached.token
        }
        let token = copilotToken(configDirectory: configDirectory) ?? ghToken(configDirectory: configDirectory)
        if let token {
            cache.withLock { $0 = (token, Date()) }
        }
        return token
    }

    static func invalidate() {
        cache.withLock { $0 = nil }
    }

    static func sessionStamp(configDirectory: URL = CopilotCredentials.configDirectory) -> String? {
        for file in ["github-copilot/apps.json", "github-copilot/hosts.json"] {
            let url = configDirectory.appendingPathComponent(file)
            if copilotToken(in: url) != nil, let stamp = LocalSources.fileStamp(url) {
                return stamp
            }
        }
        let hosts = configDirectory.appendingPathComponent("gh/hosts.yml")
        guard let text = try? String(contentsOf: hosts, encoding: .utf8), ghHost(text) != nil else { return nil }
        return LocalSources.fileStamp(hosts)
    }

    static func copilotToken(configDirectory: URL) -> String? {
        ["github-copilot/apps.json", "github-copilot/hosts.json"].lazy
            .compactMap { copilotToken(in: configDirectory.appendingPathComponent($0)) }
            .first
    }

    static func copilotToken(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), let root = try? JSONFlex.object(from: data) else { return nil }
        for key in root.keys.sorted() where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = JSONFlex.string(JSONFlex.dictionary(root[key])?["oauth_token"]), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    static func ghToken(configDirectory: URL) -> String? {
        let hosts = configDirectory.appendingPathComponent("gh/hosts.yml")
        guard let text = try? String(contentsOf: hosts, encoding: .utf8), let host = ghHost(text) else { return nil }
        if let token = host.token {
            return token
        }
        guard let stored = CredentialReaders.securityGenericPassword(service: "gh:github.com", account: host.user) else { return nil }
        return decodeKeyring(stored)
    }

    static func ghHost(_ yaml: String) -> (user: String?, token: String?)? {
        var inHost = false
        var childIndent: Int?
        var user: String?
        var token: String?
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 {
                inHost = trimmed == "github.com:"
                childIndent = nil
                continue
            }
            guard inHost, let colon = trimmed.firstIndex(of: ":") else { continue }
            if childIndent == nil {
                childIndent = indent
            }
            guard indent == childIndent else { continue }
            let key = trimmed[..<colon]
            let value = unquote(trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            if key == "user", !value.isEmpty {
                user = value
            } else if key == "oauth_token", !value.isEmpty {
                token = value
            }
        }
        guard user != nil || token != nil else { return nil }
        return (user, token)
    }

    static func decodeKeyring(_ value: String) -> String? {
        if value.hasPrefix("go-keyring-base64:") {
            return Data(base64Encoded: String(value.dropFirst("go-keyring-base64:".count))).flatMap { String(data: $0, encoding: .utf8) }
        }
        if value.hasPrefix("go-keyring-encoded:") {
            let hex = Array(value.dropFirst("go-keyring-encoded:".count).utf8)
            guard hex.count.isMultiple(of: 2) else { return nil }
            var bytes: [UInt8] = []
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(byte)
            }
            return String(bytes: bytes, encoding: .utf8)
        }
        return value.isEmpty ? nil : value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}
