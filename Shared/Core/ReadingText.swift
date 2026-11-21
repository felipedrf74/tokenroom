import Foundation

/// Words for readings, shared by the Mac popover, the iPhone, widgets, and the Watch.
enum ReadingText {
    /// A balance or spend where a percentage would go: "$12.40 left", or "$312.50 spent".
    static func amountHeadline(_ amount: QuotaAmount) -> String? {
        if let remaining = amount.remainingOrComputed {
            return "\(AmountFormat.text(remaining, unit: amount.unit)) left"
        }
        return amount.used.map { "\(AmountFormat.text($0, unit: amount.unit)) spent" }
    }

    /// "249 of 300 requests", "$37.20 of $50.00", "$12.40 left", or "$312.50 spent".
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

    /// Used % for metered windows, the amount for balances without a limit.
    /// A balance or spend short enough for a circular widget or complication: "$12", "$1.2K".
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

    /// Compact summaries retain the primary headline while explaining urgent secondary
    /// limits and any elapsed window awaiting its replacement reading.
    /// A short note under a compact reading. An exhausted secondary limit and a window that
    /// has reset come first. Otherwise, when the surface is leading with a different window,
    /// this names the primary one: "Weekly 32%".
    /// - Parameter lead: the window the surface is showing. Omit it to choose that window here.
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

    /// "resets in 2d 5h"; billing cycles say the day: "resets Oct 9".
    static func reset(_ window: RelayWindow, now: Date = .now) -> String? {
        if window.isAwaitingReading(at: now) { return "Reset · awaiting reading" }
        guard let resetsAt = window.resetsAt else { return nil }
        if window.windowKind == .billingCycle || window.windowKind == .monthly {
            return resetsAt > now ? "resets \(resetsAt.formatted(.dateTime.month(.abbreviated).day()))" : "reset due"
        }
        return RelativeTime.resets(resetsAt, now: now)
    }

    /// "Weekly · resets in 2d 5h".
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
            return caption(window, now: now)
        }
        return "\(window.displayTitle) · \(UsageFacts.countdown(to: resetsAt, now: now))"
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
