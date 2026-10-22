import Foundation

/// Month-to-date organization spend, read with an admin or management key.
/// Without a budget this is an amount ("$312 spent"); a budget turns it into a meter.
enum OrgSpend {
    /// The current calendar month in UTC, which is how these providers bill.
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

/// OpenAI's `GET /v1/organization/costs`: daily buckets of `results[].amount.value` in dollars.
enum OpenAICostsParser {
    struct Page {
        var total: Double
        var nextPage: String?
    }

    static func page(from data: Data) throws -> Page {
        let root = try JSONFlex.object(from: data)
        guard let buckets = JSONFlex.array(root["data"]) else { throw ProviderError.parse }
        var total = 0.0
        for bucket in buckets {
            for result in JSONFlex.array(JSONFlex.dictionary(bucket)?["results"]) ?? [] {
                total += JSONFlex.number(JSONFlex.dictionary(JSONFlex.dictionary(result)?["amount"])?["value"]) ?? 0
            }
        }
        let more = (root["has_more"] as? Bool) == true
        return Page(total: total, nextPage: more ? JSONFlex.string(root["next_page"]) : nil)
    }
}

/// Anthropic's `GET /v1/organizations/cost_report`: `results[].amount` in cents, as decimal strings.
enum AnthropicCostParser {
    struct Page {
        var total: Double
        var nextPage: String?
    }

    static func page(from data: Data) throws -> Page {
        let root = try JSONFlex.object(from: data)
        guard let buckets = JSONFlex.array(root["data"]) else { throw ProviderError.parse }
        var cents = 0.0
        for bucket in buckets {
            for result in JSONFlex.array(JSONFlex.dictionary(bucket)?["results"]) ?? [] {
                cents += JSONFlex.number(JSONFlex.dictionary(result)?["amount"]) ?? 0
            }
        }
        let more = (root["has_more"] as? Bool) == true
        return Page(total: cents / 100, nextPage: more ? JSONFlex.string(root["next_page"]) : nil)
    }
}

/// xAI's Management API. Amounts are US cents as strings.
enum XAIBillingParser {
    /// The team a management key belongs to: `scopeId` (team scope), else the deprecated `teamId`.
    static func teamID(fromValidation data: Data) throws -> String {
        let root = try JSONFlex.object(from: data)
        if let scope = JSONFlex.string(root["scopeId"]), !scope.isEmpty {
            return scope
        }
        guard let team = JSONFlex.string(root["teamId"]), !team.isEmpty else { throw ProviderError.parse }
        return team
    }

    /// Whether the key can change anything (keys, billing), for the Settings warning.
    static func canWrite(fromValidation data: Data) -> Bool {
        guard let root = try? JSONFlex.object(from: data) else { return false }
        return (JSONFlex.array(root["acls"]) ?? []).compactMap { $0 as? String }.contains { acl in
            let lowered = acl.lowercased()
            return lowered.contains("write") || lowered.contains("create") || lowered.contains("delete") || lowered.contains("update") || lowered.hasSuffix(":*") || lowered == "*"
        }
    }

    /// `coreInvoice.amountAfterVat` (this month so far) and `effectiveSpendingLimit`, in dollars.
    static func invoice(from data: Data) throws -> (spend: Double, limit: Double?) {
        let root = try JSONFlex.object(from: data)
        guard let core = JSONFlex.dictionary(root["coreInvoice"]),
              let cents = JSONFlex.cent(core["amountAfterVat"]) ?? JSONFlex.cent(core["amountBeforeVat"])
        else { throw ProviderError.parse }
        let limit = JSONFlex.cent(root["effectiveSpendingLimit"]).flatMap { $0 > 0 ? $0 / 100 : nil }
        return (cents / 100, limit)
    }

    /// Prepaid credits left, in dollars. xAI keeps this ledger with credit as a negative total;
    /// a positive one is spent past the credits, so none are left.
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
            return OrgSpend.snapshot(provider, window: OrgSpend.spendWindow(total, now: now), fetchedAt: now)

        case .xaiOrg:
            let base = "https://management-api.x.ai"
            let validation = try await TokenroomHTTP.get(URL(string: "\(base)/auth/management-keys/validation")!, token: key, provider: provider)
            let team = try XAIBillingParser.teamID(fromValidation: validation)
            let teamPath = team.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? team
            // Nil when the team has no prepaid ledger (404).
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
                // Prepaid-only teams have no invoice: the credits are the balance, and a call for
                // them that failed (a 429, an outage) fails the check.
                guard let credits = try credits.get() else { throw ProviderError.parse }
                let window = QuotaWindow(id: "balance", kind: .pool, title: "Prepaid credits", usedPercent: 0, resetsAt: nil, amount: credits.amount, metered: false)
                return OrgSpend.snapshot(provider, window: window, fetchedAt: now)
            }
            // Any other failure is the invoice's (a 429's wait, an outage, a refused key), not a
            // team without one.
            try TokenroomHTTP.check(response, provider: provider)
            let invoice = try XAIBillingParser.invoice(from: data)
            let extra: ExtraUsage?
            switch credits {
            case .success(let found):
                extra = found
            case .failure(let error):
                // The same key and team: a wait or a refusal holds for the whole check.
                switch error as? ProviderError {
                case .rateLimited?, .expired?: throw error
                default: break
                }
                // Otherwise the spend still shows; the credits beside it come back on the next check.
                extra = nil
            }
            return OrgSpend.snapshot(provider, window: OrgSpend.spendWindow(invoice.spend, limit: invoice.limit, now: now), extra: extra, fetchedAt: now)

        default:
            throw ProviderError.parse
        }
    }
}
