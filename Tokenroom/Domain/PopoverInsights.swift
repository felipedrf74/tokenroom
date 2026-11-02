import Foundation

/// Facts derived from one open window, never totals across unrelated provider quotas.
enum PopoverInsights {
    static func facts(window: RelayWindow, isStale: Bool, now: Date) -> [UsageFact] {
        guard window.isMetered, !window.isAwaitingReading(at: now), window.used.isFinite else { return [] }
        let remaining = max(0, 100 - min(max(window.used, 0), 100))
        var result = [UsageFact(label: isStale ? "Last remaining" : "Remaining",
                                value: "\(TokenroomFormat.percentText(remaining))%", detail: window.displayTitle)]
        // This is an allowance, not a prediction: split the remaining quota evenly until reset.
        // Short sessions do not get a misleading daily figure. Frozen readings get no allowance.
        if !isStale, let reset = window.resetsAt, reset.timeIntervalSince(now) >= 86_400 {
            let perDay = remaining * 86_400 / reset.timeIntervalSince(now)
            result.append(UsageFact(label: "Daily allowance",
                                    value: "\(perDay.formatted(.number.precision(.fractionLength(1))))%",
                                    detail: "of this quota / day until reset"))
        }
        return result
    }

    static func paceDetail(_ pace: Pace) -> String {
        let points = abs(pace.delta).formatted(.number.precision(.fractionLength(0...1)))
        if abs(pace.delta) < 0.05 { return "Matches an even pace" }
        return "\(points) percentage points \(pace.delta > 0 ? "ahead of" : "below") an even pace"
    }
}
