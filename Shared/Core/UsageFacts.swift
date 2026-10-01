import Foundation

/// The few facts that explain a window at a glance, as short label and value pairs instead of a
/// stack of sentences: when it resets, how the pace looks against an even spread, the plan, and
/// when it was last checked. The Mac's expanded card and the iPhone's detail show them as a grid.
struct UsageFact: Equatable, Sendable, Identifiable {
    var label: String
    var value: String
    var detail: String?
    /// Set when the value needs attention (ahead of pace, limit reached).
    var severity: Pace.Severity? = nil

    var id: String { label }
}

enum UsageFacts {
    static func facts(
        for window: RelayWindow?,
        pace: Pace?,
        plan: String?,
        checkedAt: Date?,
        isStale: Bool,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> [UsageFact] {
        var facts: [UsageFact] = []
        if let window {
            if window.isAwaitingReading(at: now) {
                facts.append(UsageFact(label: "Resets", value: "Reset", detail: "Awaiting reading"))
            } else if let resetsAt = window.resetsAt {
                facts.append(UsageFact(label: "Resets", value: countdown(to: resetsAt, now: now),
                                       detail: Pace.shortMoment(resetsAt, now: now, timeZone: timeZone)))
            }
            if window.isMetered, !isStale, !window.isAwaitingReading(at: now), let pace {
                facts.append(paceFact(pace, now: now, timeZone: timeZone))
            }
        }
        if let plan, !plan.isEmpty {
            facts.append(UsageFact(label: "Plan", value: plan))
        }
        if let checkedAt {
            facts.append(UsageFact(label: "Checked", value: RelativeTime.ago(checkedAt, now: now).capitalizedFirst))
        }
        return facts
    }

    /// "Ahead" with when it runs out, "On pace" with where an even pace would be by now.
    static func paceFact(_ pace: Pace, now: Date, timeZone: TimeZone) -> UsageFact {
        let target = "Even pace \(TokenroomFormat.percentText(min(max(pace.elapsedFraction, 0), 1) * 100))%"
        switch pace.verdict {
        case .ahead:
            let detail = pace.runsOutAt.map { "Runs out \(Pace.shortMoment($0, now: now, timeZone: timeZone))" } ?? target
            return UsageFact(label: "Pace", value: "Ahead", detail: detail, severity: pace.severity)
        case .limitReached:
            return UsageFact(label: "Pace", value: "Limit reached", detail: target, severity: pace.severity)
        case .onPace:
            return UsageFact(label: "Pace", value: "On pace", detail: target)
        case .plentyLeft:
            return UsageFact(label: "Pace", value: "Plenty left", detail: target)
        }
    }

    /// "3d 1h", "2h 10m", "5m".
    static func countdown(to date: Date, now: Date) -> String {
        guard let text = RelativeTime.resets(date, now: now) else { return "—" }
        return text.hasPrefix("resets in ") ? String(text.dropFirst("resets in ".count)) : text.capitalizedFirst
    }
}

extension String {
    /// "just now" → "Just now".
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
