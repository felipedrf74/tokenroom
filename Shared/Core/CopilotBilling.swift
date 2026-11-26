import Foundation

enum CopilotBilling {
    static let windowID = "premium_interactions"
    static let legacyWindowID = "ai_credits"

    static func currentWindowID(provider: String, window: String) -> String {
        provider == Provider.copilot.rawValue && window == legacyWindowID ? windowID : window
    }

    struct Plan: Equatable, Sendable {
        var name: String
        var allowance: Double?
        var isLegacy = false
    }

    static let plans: [Plan] = [
        Plan(name: "Pro", allowance: 1_500),
        Plan(name: "Pro+", allowance: 7_000),
        Plan(name: "Max", allowance: 20_000),
        Plan(name: "Free", allowance: nil),
        Plan(name: "Student", allowance: nil),
        Plan(name: "Pro, yearly", allowance: 300, isLegacy: true),
        Plan(name: "Pro+, yearly", allowance: 1_500, isLegacy: true),
    ]

    static func plan(named name: String?) -> Plan {
        plans.first { $0.name == name } ?? plans[0]
    }

    static let headers = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2026-03-10",
    ]

    static let tokenExpiredHint = "Couldn't use this fine-grained token. Add a new one in Settings."

    static func login(from data: Data) throws -> String {
        let root = try JSONFlex.object(from: data)
        guard let login = JSONFlex.string(root["login"]), !login.isEmpty else { throw ProviderError.parse }
        return login
    }

    static func used(from data: Data) throws -> Double {
        let root = try JSONFlex.object(from: data)
        guard let items = JSONFlex.array(root["usageItems"]) else { throw ProviderError.parse }
        return items.compactMap { $0 as? [String: Any] }.reduce(0) { total, item in
            total + (JSONFlex.number(item["grossQuantity"]) ?? 0)
        }
    }

    static func month(containing date: Date) -> (start: Date, end: Date, year: Int, month: Int) {
        let calendar = Calendar.gregorianUTC
        let parts = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: parts) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (start, end, parts.year ?? 1970, parts.month ?? 1)
    }

    static func snapshot(used: Double, plan: Plan, now: Date = .now) throws -> QuotaSnapshot {
        let month = month(containing: now)
        let unit = plan.isLegacy ? "requests" : "credits"
        let window = QuotaWindow(
            id: windowID,
            kind: .monthly,
            title: plan.isLegacy ? "Premium requests" : "AI credits",
            usedPercent: plan.allowance.map { JSONFlex.clampPercent(used / $0 * 100) } ?? 0,
            resetsAt: month.end,
            startsAt: month.start,
            amount: QuotaAmount(used: used, limit: plan.allowance, remaining: plan.allowance.map { max($0 - used, 0) }, unit: unit),
            metered: plan.allowance != nil
        )
        return try .headlined(by: [window], provider: .copilot, fetchedAt: now, planLabel: "Copilot \(plan.name)")
    }
}
