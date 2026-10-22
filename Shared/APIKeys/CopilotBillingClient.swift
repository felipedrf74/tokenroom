import Foundation

extension APIKeyClient {
    /// This month's Copilot usage with a fine-grained token; `planName` is the plan picked with it.
    static func copilotSnapshot(key: String, planName: String?, now: Date = .now) async throws -> QuotaSnapshot {
        let plan = CopilotBilling.plan(named: planName)
        let user = try await copilotGet(URL(string: "https://api.github.com/user")!, key: key)
        let login = try CopilotBilling.login(from: user)
        let month = CopilotBilling.month(containing: now)
        let path = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login
        var components = URLComponents(string: "https://api.github.com/users/\(path)/settings/billing/\(plan.isLegacy ? "premium_request" : "ai_credit")/usage")!
        components.queryItems = [
            URLQueryItem(name: "year", value: String(month.year)),
            URLQueryItem(name: "month", value: String(month.month)),
        ]
        let usage = try await copilotGet(components.url!, key: key)
        return try CopilotBilling.snapshot(used: try CopilotBilling.used(from: usage), plan: plan, now: now)
    }

    private static func copilotGet(_ url: URL, key: String) async throws -> Data {
        let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(url, token: key, headers: CopilotBilling.headers))
        switch response.statusCode {
        case 401:
            throw ProviderError.expired(CopilotBilling.tokenExpiredHint)
        case 403, 429:
            if let limited = githubRateLimit(response, body: data) { throw limited }
            if response.statusCode == 429 { throw ProviderError.rateLimited(until: nil) }
            throw ProviderError.notEntitled("This token can't read Copilot usage. Create a fine-grained token with the Plan (read) account permission.")
        case 404:
            throw ProviderError.notEntitled("GitHub has no Copilot usage for this account. Copilot through an organization isn't included.")
        default:
            try TokenroomHTTP.check(response, provider: .copilot)
            return data
        }
    }

    /// GitHub answers a primary or secondary rate limit with 403 as well as 429: it says so with
    /// `x-ratelimit-remaining: 0` (until `x-ratelimit-reset`, in seconds since 1970) or with
    /// `retry-after`, or, for some secondary limits, only in its message. Nil for a 403 that's a
    /// token without the permission.
    static func githubRateLimit(_ response: HTTPURLResponse, body: Data = Data(), now: Date = .now) -> ProviderError? {
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining")?.trimmingCharacters(in: .whitespaces)
        guard retryAfter != nil || remaining == "0" else {
            let message = ((try? JSONFlex.object(from: body)).flatMap { JSONFlex.string($0["message"]) } ?? "").lowercased()
            return message.contains("secondary rate limit") || message.contains("rate limit exceeded") ? .rateLimited(until: nil) : nil
        }
        if let until = TokenroomHTTP.retryDate(retryAfter, now: now) {
            return .rateLimited(until: until)
        }
        let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map(Date.init(timeIntervalSince1970:))
        return .rateLimited(until: reset)
    }
}
