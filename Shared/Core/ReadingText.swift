import Foundation

enum ReadingText {
    static func amountHeadline(_ amount: QuotaAmount) -> String? {
        if let remaining = amount.remainingOrComputed {
            return "\(AmountFormat.text(remaining, unit: amount.unit)) left"
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    static func amountDetail(_ amount: QuotaAmount) -> String? {
        if let used = amount.used, let limit = amount.limit {
            let limitText = AmountFormat.text(limit, unit: amount.unit)
            let usedText = ["usd", "cny"].contains(amount.unit)
                ? AmountFormat.text(used, unit: amount.unit)
                : used.formatted(.number.precision(.fractionLength(0...1)))
            return "\(usedText) of \(limitText)"
        }
        if let remaining = amount.remaining {
            return "\(AmountFormat.text(remaining, unit: amount.unit)) left"
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    static func banked(_ banked: BankedResets, now: Date = .now) -> String {
        let count = banked.available == 1 ? "1 banked reset" : "\(banked.available) banked resets"
        guard let next = banked.nextExpiry(after: now) else { return count }
        return "\(count) · next expires \(next.formatted(.dateTime.month(.abbreviated).day()))"
    }

    static func extra(_ extra: ExtraUsage) -> String? {
        guard extra.isEnabled, let remaining = extra.amount.remainingOrComputed else { return nil }
        return "\(extra.title) · \(AmountFormat.text(remaining, unit: extra.amount.unit)) left"
    }

    static func circleAmount(_ amount: QuotaAmount) -> String {
        guard let value = amount.remainingOrComputed ?? amount.used else { return "—" }
        switch amount.unit {
        case "usd":
            return value.formatted(.currency(code: "USD").notation(.compactName))
        case "cny":
            return value.formatted(.currency(code: "CNY").notation(.compactName))
        default:
            return value.formatted(.number.notation(.compactName))
        }
    }

    static func headline(_ window: RelayWindow?, now: Date = .now) -> String {
        guard let window else { return "—" }
        guard !window.isAwaitingReading(at: now) else { return "—" }
        if !window.isMetered, let amount = window.amount {
            return amountHeadline(amount) ?? "—"
        }
        return "\(TokenroomFormat.percentText(window.used))%"
    }

    static func attention(_ provider: RelayProvider, now: Date = .now, lead: RelayWindow? = nil) -> String? {
        if let warning = UsageRanking.limitWarning(for: provider, now: now) { return warning }
        if let window = provider.windows.first(where: { $0.isAwaitingReading(at: now) }) {
            let pending = "Reset · awaiting reading"
            return window.id == provider.primaryWindow?.id ? pending : "\(window.displayTitle): \(pending)"
        }
        let shown = lead ?? provider.leadWindow(now: now)
        guard let shown,
              let primary = provider.primaryWindow,
              primary.id != shown.id,
              primary.isMetered,
              !primary.isAwaitingReading(at: now)
        else { return nil }
        return "\(primary.displayTitle) \(TokenroomFormat.percentText(primary.used))%"
    }

    static func reset(_ window: RelayWindow, now: Date = .now) -> String? {
        if window.isAwaitingReading(at: now) { return "Reset · awaiting reading" }
        guard let resetsAt = window.resetsAt else { return nil }
        if window.windowKind == .billingCycle || window.windowKind == .monthly {
            return resetsAt > now ? "resets \(resetsAt.formatted(.dateTime.month(.abbreviated).day()))" : "reset due"
        }
        return RelativeTime.resets(resetsAt, now: now)
    }

    static func caption(_ window: RelayWindow, now: Date = .now) -> String {
        [window.displayTitle, reset(window, now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    static let awaitingReading = "Reset, awaiting reading"

    static func meterAccessibility(used: Double, paceMark: Double?, isStale: Bool, isAwaitingReading: Bool) -> String {
        guard !isAwaitingReading else { return awaitingReading }
        let figure = "\(TokenroomFormat.percentText(used)) percent used"
        guard let pace = MeterLayout.shownPace(paceMark, isStale: isStale, isAwaitingReading: false) else { return figure }
        return "\(figure), \(TokenroomFormat.percentText(pace * 100)) percent of the window has passed"
    }

    static func windowCountdown(_ window: RelayWindow, now: Date = .now) -> String {
        if window.isAwaitingReading(at: now) { return "Reset · awaiting reading" }
        guard let resetsAt = window.resetsAt else { return window.displayTitle }
        if window.windowKind == .billingCycle || window.windowKind == .monthly {
            let day = resetsAt > now ? resetsAt.formatted(.dateTime.month(.abbreviated).day()) : "reset due"
            return "\(window.displayTitle) · \(day)"
        }
        return "\(window.displayTitle) · \(UsageFacts.countdown(to: resetsAt, now: now))"
    }

    static func watchPaceNote(_ pace: Pace?, now: Date = .now, timeZone: TimeZone = .current) -> String? {
        guard let pace else { return nil }
        if pace.needsAttention || pace.isProjected { return pace.caption(now: now, timeZone: timeZone) }
        guard let runOut = pace.currentRunOut else { return nil }
        return "Runs out \(Pace.shortMoment(runOut, now: now, timeZone: timeZone))"
    }

    static func asOf(_ checked: Date, now: Date = .now, timeZone: TimeZone = .current) -> String {
        "As of \(Pace.shortMoment(checked, now: now, timeZone: timeZone))"
    }

    static func lastChecked(_ checked: Date?, now: Date = .now) -> String {
        "Last checked \(RelativeTime.ago(checked, now: now))"
    }

    static func remainingLabel(isLive: Bool) -> String {
        isLive ? "left" : "left at last check"
    }

    static func historyTitle(_ window: RelayWindow, isLead: Bool) -> String {
        isLead ? "\(window.displayTitle) usage · last 7 days" : "Last 7 days"
    }
}

extension RelayProvider {
    func window(configured id: String?) -> RelayWindow? {
        guard let id else { return primaryWindow }
        return windows.first { $0.id == id }
    }
}
