import Foundation

// Plan usage parsers, shared so the iPhone can read the plans it signs in to. Pure: the
// answer in, a reading out. Each drops the account's email, names, and IDs it doesn't read.

/// Claude usage from `api.anthropic.com/api/oauth/usage`. Keys with codenames are ignored.
enum ClaudeParser {
    private static let week: Double = 7 * 86_400

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        guard let weekly = JSONFlex.dictionary(root["seven_day"]) else {
            throw ProviderError.parse
        }
        let used = JSONFlex.clampPercent(JSONFlex.number(weekly["utilization"]) ?? 0)
        let resetsAt = JSONFlex.date(weekly["resets_at"])
        let weekStart = JSONFlex.date(JSONFlex.dictionary(root["seven_day_breakdown"])?["window_started_at"])

        var windows = [
            QuotaWindow(
                id: "weekly",
                kind: .weekly,
                title: "Weekly",
                usedPercent: used,
                resetsAt: resetsAt,
                windowSeconds: week,
                startsAt: weekStart
            ),
        ]

        if let session = JSONFlex.dictionary(root["five_hour"]),
           let sessionUsed = JSONFlex.number(session["utilization"]) {
            windows.append(
                QuotaWindow(
                    id: "session",
                    kind: .session,
                    title: "Session",
                    usedPercent: JSONFlex.clampPercent(sessionUsed),
                    resetsAt: JSONFlex.date(session["resets_at"]),
                    windowSeconds: 5 * 3_600
                )
            )
        }

        // Model weekly caps, when the plan has them.
        for (key, title) in [("seven_day_opus", "Opus weekly"), ("seven_day_sonnet", "Sonnet weekly")] {
            if let object = JSONFlex.dictionary(root[key]), let percent = JSONFlex.number(object["utilization"]) {
                windows.append(
                    QuotaWindow(
                        id: key,
                        kind: .weekly,
                        title: title,
                        usedPercent: JSONFlex.clampPercent(percent),
                        resetsAt: JSONFlex.date(object["resets_at"]),
                        windowSeconds: week
                    )
                )
            }
        }

        // Other model-scoped weekly caps. Unscoped entries repeat the weekly and session windows.
        for (index, item) in (JSONFlex.array(root["limits"]) ?? []).enumerated() {
            guard let limit = JSONFlex.dictionary(item),
                  (limit["is_active"] as? Bool) != false,
                  let model = JSONFlex.dictionary(JSONFlex.dictionary(limit["scope"])?["model"]),
                  let name = JSONFlex.string(model["display_name"]), !name.isEmpty,
                  let percent = JSONFlex.number(limit["percent"])
            else { continue }
            let title = "\(name) weekly"
            guard !windows.contains(where: { $0.title == title }) else { continue }
            windows.append(
                QuotaWindow(
                    id: "limit-\(index)",
                    kind: .weekly,
                    title: title,
                    usedPercent: JSONFlex.clampPercent(percent),
                    resetsAt: JSONFlex.date(limit["resets_at"]),
                    windowSeconds: week
                )
            )
        }

        return QuotaSnapshot(
            provider: .claude,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: windows,
            extra: extraUsage(from: JSONFlex.dictionary(root["extra_usage"]))
        )
    }

    /// Paid usage past the plan. Amounts arrive in minor units (`decimal_places`).
    private static func extraUsage(from object: [String: Any]?) -> ExtraUsage? {
        guard let object, (object["is_enabled"] as? Bool) == true,
              let rawLimit = JSONFlex.number(object["monthly_limit"]), rawLimit > 0
        else { return nil }
        let scale = pow(10, JSONFlex.number(object["decimal_places"]) ?? 0)
        let used = (JSONFlex.number(object["used_credits"]) ?? 0) / scale
        let limit = rawLimit / scale
        return ExtraUsage(
            title: "Extra usage",
            amount: QuotaAmount(used: used, limit: limit, remaining: max(limit - used, 0), unit: (JSONFlex.string(object["currency"]) ?? "usd").lowercased())
        )
    }
}

/// Codex usage from `chatgpt.com/backend-api/wham/usage`. The response also carries the
/// account's email and IDs; they are never read.
enum OpenAIParser {
    private static let weekSeconds: Double = 6 * 24 * 60 * 60

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let rateLimit = JSONFlex.dictionary(root["rate_limit"]) ?? [:]
        let primary = window(from: JSONFlex.dictionary(rateLimit["primary_window"]))
        let secondary = window(from: JSONFlex.dictionary(rateLimit["secondary_window"]))

        // Decide by window length, not position: a weekly-only plan reports its week as primary.
        let candidates = [primary, secondary].compactMap { $0 }
        guard let weekly = candidates.first(where: { $0.limitSeconds >= weekSeconds }) ?? secondary ?? primary else {
            throw ProviderError.parse
        }
        let session = candidates.first { $0 != weekly }

        var windows = [makeWindow(weekly, id: "weekly")]
        if let session {
            windows.append(makeWindow(session, id: "session", title: "Session", kind: .session))
        }

        if let review = window(from: JSONFlex.dictionary(JSONFlex.dictionary(root["code_review_rate_limit"])?["primary_window"])) {
            windows.append(makeWindow(review, id: "code-review", title: "Code review"))
        }

        if let extras = JSONFlex.array(root["additional_rate_limits"]) {
            for (index, extra) in extras.enumerated() {
                guard let object = JSONFlex.dictionary(extra) else { continue }
                let name = JSONFlex.string(object["limit_name"]) ?? "Extra"
                let nested = JSONFlex.dictionary(object["rate_limit"]) ?? [:]
                let parts = [
                    window(from: JSONFlex.dictionary(nested["secondary_window"])),
                    window(from: JSONFlex.dictionary(nested["primary_window"])),
                ].compactMap { $0 }
                // Named limits only earn a line once they're in use.
                if let used = parts.first(where: { $0.used >= 1 }) {
                    windows.append(makeWindow(used, id: "extra-\(index)", title: name))
                }
            }
        }

        if let spend = spendWindow(from: JSONFlex.dictionary(JSONFlex.dictionary(root["spend_control"])?["individual_limit"])) {
            windows.append(spend)
        }

        return QuotaSnapshot(
            provider: .openai,
            usedPercent: weekly.used,
            resetsAt: weekly.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: windows[0].title,
            windows: windows,
            planLabel: planLabel(JSONFlex.string(root["plan_type"])),
            banked: banked(from: JSONFlex.dictionary(root["rate_limit_reset_credits"])),
            extra: credits(from: JSONFlex.dictionary(root["credits"]))
        )
    }

    /// Expiry dates of reset credits that are still available, soonest first.
    /// From `wham/rate-limit-reset-credits`; titles, images, and IDs are ignored.
    static func availableResetExpiries(from data: Data, now: Date = .now) throws -> [Date] {
        let root = try JSONFlex.object(from: data)
        return (JSONFlex.array(root["credits"]) ?? []).compactMap { item -> Date? in
            guard let credit = JSONFlex.dictionary(item),
                  credit["redeemed_at"] == nil || credit["redeemed_at"] is NSNull,
                  credit["redeem_started_at"] == nil || credit["redeem_started_at"] is NSNull,
                  (credit["is_supported_by_plan"] as? Bool) != false,
                  let expires = JSONFlex.date(credit["expires_at"]), expires > now
            else { return nil }
            return expires
        }
        .sorted()
    }

    private struct ParsedWindow: Equatable {
        var used: Double
        var resetsAt: Date?
        var limitSeconds: Double
    }

    private static func window(from object: [String: Any]?) -> ParsedWindow? {
        guard let object else { return nil }
        guard let used = JSONFlex.number(object["used_percent"]) else { return nil }
        let remaining = JSONFlex.number(object["remaining_percent"])
        let percent = remaining.map { JSONFlex.clampPercent(100 - $0) } ?? JSONFlex.clampPercent(used)
        return ParsedWindow(
            used: percent,
            resetsAt: JSONFlex.date(object["reset_at"]),
            limitSeconds: JSONFlex.number(object["limit_window_seconds"]) ?? 0
        )
    }

    private static func makeWindow(_ parsed: ParsedWindow, id: String, title: String? = nil, kind: WindowKind? = nil) -> QuotaWindow {
        let isWeekly = parsed.limitSeconds >= weekSeconds
        return QuotaWindow(
            id: id,
            kind: kind ?? (isWeekly ? .weekly : .session),
            title: title ?? (isWeekly ? "Weekly" : "Session"),
            usedPercent: parsed.used,
            resetsAt: parsed.resetsAt,
            windowSeconds: parsed.limitSeconds > 0 ? parsed.limitSeconds : nil
        )
    }

    /// `spend_control.individual_limit`: a dollar cap an admin set for this seat.
    private static func spendWindow(from object: [String: Any]?) -> QuotaWindow? {
        guard let object else { return nil }
        let limit = JSONFlex.number(object["limit"])
        let used = JSONFlex.number(object["used"])
        let percent: Double
        if let remaining = JSONFlex.number(object["remaining_percent"]) {
            percent = JSONFlex.clampPercent(100 - remaining)
        } else if let limit, limit > 0, let used {
            percent = JSONFlex.clampPercent(used / limit * 100)
        } else {
            return nil
        }
        return QuotaWindow(
            id: "spend",
            kind: .pool,
            title: "Spend limit",
            usedPercent: percent,
            resetsAt: JSONFlex.date(object["resets_at"]),
            amount: QuotaAmount(used: used, limit: limit, unit: "usd")
        )
    }

    private static func credits(from object: [String: Any]?) -> ExtraUsage? {
        guard let object,
              (object["has_credits"] as? Bool) == true,
              (object["unlimited"] as? Bool) != true,
              let balance = JSONFlex.number(object["balance"])
        else { return nil }
        return ExtraUsage(title: "Credits", amount: QuotaAmount(remaining: balance, unit: "credits"))
    }

    private static func banked(from object: [String: Any]?) -> BankedResets? {
        guard let object,
              let count = JSONFlex.number(object["applicable_available_count"]) ?? JSONFlex.number(object["available_count"]),
              count > 0
        else { return nil }
        return BankedResets(available: Int(count))
    }

    private static func planLabel(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum GrokParser {
    /// Plan name from `/v1/settings`; the rest of that response is ignored.
    static func planLabel(fromSettings data: Data) -> String? {
        guard let root = try? JSONFlex.object(from: data),
              let label = JSONFlex.string(root["subscription_tier_display"])?.trimmingCharacters(in: .whitespaces),
              !label.isEmpty
        else { return nil }
        return label
    }

    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let config = JSONFlex.dictionary(root["config"]) ?? root
        let period = JSONFlex.dictionary(config["currentPeriod"])
        let periodType = JSONFlex.string(period?["type"]) ?? ""
        let isWeekly = periodType.contains("WEEKLY")

        let usedPercent: Double
        if let percent = JSONFlex.number(config["creditUsagePercent"]) {
            usedPercent = JSONFlex.clampPercent(percent)
        } else if let used = JSONFlex.cent(config["used"]),
                  let limit = JSONFlex.cent(config["monthlyLimit"]), limit > 0 {
            usedPercent = JSONFlex.clampPercent(used / limit * 100)
        } else if period != nil || (config["isUnifiedBillingUser"] as? Bool) == true {
            usedPercent = 0
        } else {
            throw ProviderError.parse
        }

        let resetsAt = JSONFlex.date(period?["end"])
            ?? JSONFlex.date(config["billingPeriodEnd"])
        let title = isWeekly ? "Weekly" : "This cycle"
        let kind: WindowKind = isWeekly ? .weekly : .billingCycle

        var windows = [
            QuotaWindow(
                id: "primary",
                kind: kind,
                title: title,
                usedPercent: usedPercent,
                resetsAt: resetsAt,
                startsAt: JSONFlex.date(period?["start"])
            ),
        ]

        if let cap = JSONFlex.cent(config["onDemandCap"]), cap > 0 {
            let used = JSONFlex.cent(config["onDemandUsed"]) ?? 0
            let extraPercent = JSONFlex.clampPercent(used / cap * 100)
            windows.append(
                QuotaWindow(
                    id: "on-demand",
                    kind: .pool,
                    title: "Extra",
                    usedPercent: extraPercent,
                    resetsAt: resetsAt
                )
            )
        }

        return QuotaSnapshot(
            provider: .grok,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: title,
            windows: windows
        )
    }
}

enum CursorParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        let plan = JSONFlex.dictionary(root["planUsage"]) ?? [:]
        let auto = JSONFlex.number(plan["autoPercentUsed"])
        let api = JSONFlex.number(plan["apiPercentUsed"])
        let total = JSONFlex.number(plan["totalPercentUsed"])

        let autoPercent = JSONFlex.clampPercent(auto ?? 0)
        let apiPercent = JSONFlex.clampPercent(api ?? 0)
        var used = max(autoPercent, apiPercent)
        if used == 0, let total {
            used = JSONFlex.clampPercent(total)
        }
        if used == 0,
           let limit = JSONFlex.number(plan["limit"]), limit > 0,
           let spend = JSONFlex.number(plan["includedSpend"]) ?? JSONFlex.number(plan["totalSpend"]) {
            used = JSONFlex.clampPercent(spend / limit * 100)
        }

        let resetsAt = JSONFlex.date(root["billingCycleEnd"])
        let startsAt = JSONFlex.date(root["billingCycleStart"])
        var windows = [
            QuotaWindow(
                id: "cycle",
                kind: .billingCycle,
                title: "This cycle",
                usedPercent: used,
                resetsAt: resetsAt,
                startsAt: startsAt
            ),
        ]
        if auto != nil {
            windows.append(
                QuotaWindow(
                    id: "cursor-models",
                    kind: .pool,
                    title: "Cursor Models",
                    usedPercent: autoPercent,
                    resetsAt: resetsAt
                )
            )
        }
        if api != nil {
            windows.append(
                QuotaWindow(
                    id: "other-models",
                    kind: .pool,
                    title: "Other Models",
                    usedPercent: apiPercent,
                    resetsAt: resetsAt
                )
            )
        }

        return QuotaSnapshot(
            provider: .cursor,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "This cycle",
            windows: windows
        )
    }
}

enum GrokBotParser {
    static func snapshot(from data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot {
        let root = try JSONFlex.object(from: data)
        if let included = root["hasNonZeroIncludedLimit"] as? Bool, included == false {
            throw ProviderError.notEntitled("Grok Bot isn't on this Cursor plan.")
        }
        guard let usedRaw = JSONFlex.number(root["usagePercent"]) else {
            throw ProviderError.parse
        }
        let used = JSONFlex.clampPercent(usedRaw)
        let resetsAt = JSONFlex.date(root["nextResetTimestampUtc"])
        let plan = JSONFlex.string(root["grokPlanLabel"]).flatMap { $0.isEmpty ? nil : $0 }
        return QuotaSnapshot(
            provider: .grokBot,
            usedPercent: used,
            resetsAt: resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: "Weekly",
            windows: [
                QuotaWindow(
                    id: "weekly",
                    kind: .weekly,
                    title: "Weekly",
                    usedPercent: used,
                    resetsAt: resetsAt,
                    startsAt: JSONFlex.date(root["currentPeriodStart"])
                ),
            ],
            planLabel: plan
        )
    }
}
