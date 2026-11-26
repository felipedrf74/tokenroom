import Foundation

enum Forecast {
    static let minimumSpan: TimeInterval = 12 * 3600
    static let topUpShare = 0.01
    static let minimumMonthFraction = 0.1
    static let maximumReadingAge: TimeInterval = 24 * 3600

    static func daysLeft(remaining: Double, unit: String, history: UsageHistory?, now: Date = .now) -> Double? {
        guard remaining.isFinite, remaining > 0, history?.amountUnit == unit,
              unit == "usd" || unit == "cny", let points = history?.amountPoints, points.count >= 2 else { return nil }
        var segment = [points[points.count - 1]]
        for point in points.dropLast().reversed() {
            let rise = segment[0].remaining - point.remaining
            guard rise <= max(segment[0].remaining * topUpShare, 1) else { break }
            segment.insert(point, at: 0)
        }
        guard let first = segment.first, let last = segment.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let spent = first.remaining - last.remaining
        guard span >= minimumSpan, spent > 0 else { return nil }
        let perDay = spent / span * 86_400
        return remaining / perDay
    }

    static func projectedSpend(spent: Double, startsAt: Date, resetsAt: Date, now: Date = .now) -> Double? {
        projectedSpend(spent: spent, startsAt: startsAt, resetsAt: resetsAt, checkedAt: nil, now: now)
    }

    static func projectedSpend(spent: Double, startsAt: Date, resetsAt: Date, checkedAt: Date?, now: Date = .now) -> Double? {
        let readAt = checkedAt ?? now
        guard now < resetsAt, readAt < resetsAt, now.timeIntervalSince(readAt) <= maximumReadingAge else { return nil }
        let length = resetsAt.timeIntervalSince(startsAt)
        let elapsed = readAt.timeIntervalSince(startsAt)
        guard length > 0, elapsed > 0, elapsed / length >= minimumMonthFraction, spent > 0 else { return nil }
        return spent / (elapsed / length)
    }

    static func runwayText(daysLeft: Double) -> String {
        if daysLeft < 1 {
            let hours = max(Int((daysLeft * 24).rounded()), 1)
            return "≈ \(hours) hour\(hours == 1 ? "" : "s") left at this week's rate"
        }
        let days = Int(daysLeft.rounded())
        return days > 60 ? "Lasts months at this week's rate" : "≈ \(days) day\(days == 1 ? "" : "s") left at this week's rate"
    }

    static func projectionText(_ projected: Double, unit: String, budget: Double?) -> String {
        let amount = AmountFormat.text(projected.rounded(), unit: unit)
        if let budget, projected > budget {
            return "On track for \(amount) this month, over budget"
        }
        return "On track for \(amount) this month"
    }

    static func text(for window: RelayWindow, history: UsageHistory?, now: Date = .now) -> String? {
        text(for: window, history: history, checkedAt: nil, now: now)
    }

    static func text(for window: RelayWindow, history: UsageHistory?, checkedAt: Date?, now: Date = .now) -> String? {
        guard !window.isAwaitingReading(at: now) else { return nil }
        guard let amount = window.amount, amount.unit == "usd" || amount.unit == "cny" else { return nil }
        if window.resetsAt == nil, let remaining = amount.remainingOrComputed {
            return daysLeft(remaining: remaining, unit: amount.unit, history: history, now: now).map(runwayText)
        }
        if let spent = amount.used, amount.remaining == nil, let resetsAt = window.resetsAt, let startsAt = window.startsAt {
            return projectedSpend(spent: spent, startsAt: startsAt, resetsAt: resetsAt, checkedAt: checkedAt, now: now)
                .map { projectionText($0, unit: amount.unit, budget: amount.limit) }
        }
        return nil
    }

    static func text(for window: QuotaWindow, history: UsageHistory?, now: Date = .now) -> String? {
        text(for: RelayWindow(window), history: history, now: now)
    }

    static func text(for window: QuotaWindow, history: UsageHistory?, checkedAt: Date?, now: Date = .now) -> String? {
        text(for: RelayWindow(window), history: history, checkedAt: checkedAt, now: now)
    }
}
