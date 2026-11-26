import Foundation

struct UsageFact: Equatable, Sendable, Identifiable {
    var label: String
    var value: String
    var detail: String?
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

    static func paceFact(_ pace: Pace, now: Date, timeZone: TimeZone) -> UsageFact {
        let target = "Even pace \(TokenroomFormat.percentText(min(max(pace.elapsedFraction, 0), 1) * 100))%"
        if let runOut = pace.currentRunOut {
            return UsageFact(label: "Pace", value: "Runs out \(Pace.shortMoment(runOut, now: now, timeZone: timeZone))",
                             detail: pace.verdict == .ahead ? "Ahead · \(target.lowercased())" : target, severity: pace.severity)
        }
        switch pace.verdict {
        case .ahead:
            return UsageFact(label: "Pace", value: "Ahead", detail: target, severity: pace.severity)
        case .limitReached:
            return UsageFact(label: "Pace", value: "Limit reached", detail: target, severity: pace.severity)
        case .onPace:
            return UsageFact(label: "Pace", value: "On pace", detail: target)
        case .plentyLeft:
            return UsageFact(label: "Pace", value: "Plenty left", detail: target)
        }
    }

    static func countdown(to date: Date, now: Date) -> String {
        guard let text = RelativeTime.resets(date, now: now) else { return "—" }
        return text.hasPrefix("resets in ") ? String(text.dropFirst("resets in ".count)) : text.capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
