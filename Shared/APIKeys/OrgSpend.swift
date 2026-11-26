import Foundation

enum OrgSpend {
    static func month(containing now: Date, calendar: Calendar = .gregorianUTC) -> (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .month, for: now)!.start
        return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
    }

    static func spendWindow(_ spend: Double, limit: Double? = nil, now: Date, calendar: Calendar = .gregorianUTC) -> QuotaWindow {
        let month = month(containing: now, calendar: calendar)
        let metered = (limit ?? 0) > 0
        return QuotaWindow(
            id: "spend-month",
            kind: .monthly,
            title: "This month",
            usedPercent: metered ? JSONFlex.clampPercent(spend / limit! * 100) : 0,
            resetsAt: month.end,
            startsAt: month.start,
            amount: QuotaAmount(used: spend, limit: metered ? limit : nil, unit: "usd"),
            metered: metered
        )
    }

    static func sum(_ root: [String: Any], amount: ([String: Any]) -> Double?) throws -> Double {
        guard let buckets = JSONFlex.array(root["data"]) else { throw ProviderError.parse }
        var total = 0.0
        for item in buckets {
            guard let bucket = JSONFlex.dictionary(item) else { throw ProviderError.parse }
            guard let results = bucket["results"] else { throw ProviderError.parse }
            if results is NSNull { continue }
            guard let rows = JSONFlex.array(results) else { throw ProviderError.parse }
            for row in rows {
                guard let result = JSONFlex.dictionary(row), let value = amount(result), value.isFinite else { throw ProviderError.parse }
                total += value
            }
        }
        guard total.isFinite else { throw ProviderError.parse }
        return total
    }

    static func nextPage(_ root: [String: Any]) throws -> String? {
        guard let raw = root["has_more"], !(raw is NSNull) else {
            if let cursor = JSONFlex.string(root["next_page"]), !cursor.isEmpty { throw ProviderError.parse }
            return nil
        }
        guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw ProviderError.parse }
        guard flag.boolValue else { return nil }
        guard let next = JSONFlex.string(root["next_page"]), !next.isEmpty else { throw ProviderError.parse }
        return next
    }

    static func snapshot(_ provider: Provider, window: QuotaWindow, extra: ExtraUsage? = nil, fetchedAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: window.title,
            windows: [window],
            extra: extra
        )
    }
}

enum OpenAICostsParser {
    struct Page {
        var total: Double
        var nextPage: String?
    }

    static func page(from data: Data) throws -> Page {
        let root = try JSONFlex.object(from: data)
        let total = try OrgSpend.sum(root) { result in
            JSONFlex.number(JSONFlex.dictionary(result["amount"])?["value"])
        }
        return Page(total: total, nextPage: try OrgSpend.nextPage(root))
    }
}

enum AnthropicCostParser {
    struct Page {
        var total: Double
        var nextPage: String?
    }

    static func page(from data: Data) throws -> Page {
        let root = try JSONFlex.object(from: data)
        let cents = try OrgSpend.sum(root) { result in
            JSONFlex.number(result["amount"])
        }
        return Page(total: cents / 100, nextPage: try OrgSpend.nextPage(root))
    }
}

enum XAIBillingParser {
    static func teamID(fromValidation data: Data) throws -> String {
        let root = try JSONFlex.object(from: data)
        if let scope = JSONFlex.string(root["scopeId"]), !scope.isEmpty {
            return scope
        }
        guard let team = JSONFlex.string(root["teamId"]), !team.isEmpty else { throw ProviderError.parse }
        return team
    }

    static func canWrite(fromValidation data: Data) -> Bool {
        guard let root = try? JSONFlex.object(from: data) else { return false }
        return (JSONFlex.array(root["acls"]) ?? []).compactMap { $0 as? String }.contains { acl in
            let lowered = acl.lowercased()
            return lowered.contains("write") || lowered.contains("create") || lowered.contains("delete") || lowered.contains("update") || lowered.hasSuffix(":*") || lowered == "*"
        }
    }

    static func invoice(from data: Data) throws -> (spend: Double, limit: Double?) {
        let root = try JSONFlex.object(from: data)
        guard let core = JSONFlex.dictionary(root["coreInvoice"]) else { throw ProviderError.parse }
        let hasAfterVat = core["amountAfterVat"].map { !($0 is NSNull) } ?? false
        guard let cents = hasAfterVat ? JSONFlex.cent(core["amountAfterVat"]) : JSONFlex.cent(core["amountBeforeVat"])
        else { throw ProviderError.parse }
        let limit = JSONFlex.cent(root["effectiveSpendingLimit"]).flatMap { $0 > 0 ? $0 / 100 : nil }
        return (cents / 100, limit)
    }

    static func prepaidCredits(from data: Data) throws -> Double {
        let root = try JSONFlex.object(from: data)
        guard let cents = JSONFlex.cent(root["total"]) else { throw ProviderError.parse }
        return max(-cents, 0) / 100
    }
}

extension APIKeyClient {
    static func orgSnapshot(for provider: Provider, key: String, now: Date = .now) async throws -> QuotaSnapshot {
        switch provider {
        case .openaiOrg:
            let start = Int(OrgSpend.month(containing: now).start.timeIntervalSince1970)
            var total = 0.0
            var page: String?
            for _ in 0..<3 {
                var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
                components.queryItems = [
                    URLQueryItem(name: "start_time", value: String(start)),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
                let data = try await TokenroomHTTP.get(components.url!, token: key, provider: provider)
                let parsed = try OpenAICostsParser.page(from: data)
                total += parsed.total
                page = parsed.nextPage
                if page == nil { break }
            }
            guard page == nil else { throw ProviderError.parse }
            return OrgSpend.snapshot(provider, window: OrgSpend.spendWindow(total, now: now), fetchedAt: now)

        case .anthropicOrg:
            let start = ISO8601DateFormatter().string(from: OrgSpend.month(containing: now).start)
            var total = 0.0
            var page: String?
            for _ in 0..<3 {
                var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
                components.queryItems = [
                    URLQueryItem(name: "starting_at", value: start),
                    URLQueryItem(name: "bucket_width", value: "1d"),
                    URLQueryItem(name: "limit", value: "31"),
                ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
                let data = try await TokenroomHTTP.get(
                    components.url!,
                    token: nil,
                    headers: ["x-api-key": key, "anthropic-version": "2023-06-01"],
                    provider: provider
                )
                let parsed = try AnthropicCostParser.page(from: data)
                total += parsed.total
                page = parsed.nextPage
                if page == nil { break }
            }
            guard page == nil else { throw ProviderError.parse }
            return OrgSpend.snapshot(provider, window: OrgSpend.spendWindow(total, now: now), fetchedAt: now)

        case .xaiOrg:
            let base = "https://management-api.x.ai"
            let validation = try await TokenroomHTTP.get(URL(string: "\(base)/auth/management-keys/validation")!, token: key, provider: provider)
            let team = try XAIBillingParser.teamID(fromValidation: validation)
            let teamPath = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
            let credits: Result<ExtraUsage?, any Error>
            do {
                let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(URL(string: "\(base)/v1/billing/teams/\(teamPath)/prepaid/balance")!, token: key))
                if response.statusCode == 404 {
                    credits = .success(nil)
                } else {
                    try TokenroomHTTP.check(response, provider: provider)
                    let dollars = try XAIBillingParser.prepaidCredits(from: data)
                    credits = .success(ExtraUsage(title: "Prepaid credits", amount: QuotaAmount(remaining: dollars, unit: "usd")))
                }
            } catch {
                credits = .failure(error)
            }
            let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(URL(string: "\(base)/v1/billing/teams/\(teamPath)/postpaid/invoice/preview")!, token: key))
            guard response.statusCode != 404 else {
                guard let credits = try credits.get() else { throw ProviderError.parse }
                let window = QuotaWindow(id: "balance", kind: .pool, title: "Prepaid credits", usedPercent: 0, resetsAt: nil, amount: credits.amount, metered: false)
                return OrgSpend.snapshot(provider, window: window, fetchedAt: now)
            }
            try TokenroomHTTP.check(response, provider: provider)
            let invoice = try XAIBillingParser.invoice(from: data)
            let extra: ExtraUsage?
            switch credits {
            case .success(let found):
                extra = found
            case .failure(let error):
                switch error as? ProviderError {
                case .rateLimited?, .expired?: throw error
                default: break
                }
                extra = nil
            }
            return OrgSpend.snapshot(provider, window: OrgSpend.spendWindow(invoice.spend, limit: invoice.limit, now: now), extra: extra, fetchedAt: now)

        default:
            throw ProviderError.parse
        }
    }
}
