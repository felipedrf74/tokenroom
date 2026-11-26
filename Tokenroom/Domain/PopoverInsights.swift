import Foundation

enum PopoverInsights {
    static func facts(window: RelayWindow, isStale: Bool, now: Date) -> [UsageFact] {
        guard window.isMetered, !window.isAwaitingReading(at: now), window.used.isFinite else { return [] }
        let remaining = max(0, 100 - min(max(window.used, 0), 100))
        var result = [UsageFact(label: isStale ? "Last remaining" : "Remaining",
                                value: "\(TokenroomFormat.percentText(remaining))%", detail: window.displayTitle)]
        if !isStale, let reset = window.resetsAt, reset.timeIntervalSince(now) >= 86_400 {
            let perDay = remaining * 86_400 / reset.timeIntervalSince(now)
            let quota = window.windowKind == .weekly ? "the \(WindowNames.inSentence(window.displayTitle)) quota" : "this quota"
            result.append(UsageFact(label: "Even daily pace",
                                    value: "\(perDay.formatted(.number.precision(.fractionLength(1))))%",
                                    detail: "of \(quota) per day until reset"))
        }
        return result
    }

    static func paceSummary(_ pace: Pace) -> String {
        let elapsed = "\(TokenroomFormat.percentText(pace.elapsedFraction * 100))% of the period elapsed"
        guard abs(pace.delta) >= 0.05 else { return "On an even pace · \(elapsed)" }
        let points = abs(pace.delta).formatted(.number.precision(.fractionLength(0...1)))
        return "\(points) points \(pace.delta > 0 ? "ahead" : "below") · \(elapsed)"
    }

    static func paceDetail(_ pace: Pace) -> String {
        let points = abs(pace.delta).formatted(.number.precision(.fractionLength(0...1)))
        if abs(pace.delta) < 0.05 { return "Matches an even pace" }
        return "\(points) percentage points \(pace.delta > 0 ? "ahead of" : "below") an even pace"
    }
}
