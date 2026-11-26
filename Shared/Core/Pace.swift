import Foundation

struct Pace: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case onPace
        case plentyLeft
        case ahead
        case limitReached
    }

    enum Severity: Equatable, Sendable {
        case none
        case watch
        case tight
        case critical
    }

    var verdict: Verdict
    var delta: Double
    var elapsedFraction: Double
    var resetsAt: Date
    var runsOutAt: Date?
    var severity: Severity
    var isProjected: Bool = false

    static let tolerance = 10.0
    static let minimumElapsed = 0.05
    static let minimumUsed = 5.0

    static func evaluate(
        used: Double,
        kind: WindowKind,
        resetsAt: Date?,
        startsAt: Date? = nil,
        windowSeconds: Double? = nil,
        samples: [(date: Date, used: Double)] = [],
        measured: RelayPace? = nil,
        isStale: Bool = false,
        now: Date = .now,
        calendar: Calendar = .gregorianUTC
    ) -> Pace? {
        guard let resetsAt, resetsAt > now,
              let length = windowLength(kind: kind, resetsAt: resetsAt, startsAt: startsAt, windowSeconds: windowSeconds, calendar: calendar),
              length > 0
        else { return nil }
        if isStale {
            if let measured {
                return projected(resetsAt: resetsAt, length: length, measured: measured, now: now)
            }
            guard let last = samples.last, last.date < now,
                  let then = evaluate(
                    used: last.used, kind: kind, resetsAt: resetsAt, startsAt: startsAt, windowSeconds: windowSeconds,
                    samples: samples, measured: nil, isStale: false, now: last.date, calendar: calendar
                  ),
                  let runsOut = then.runsOutAt
            else { return nil }
            return projected(resetsAt: resetsAt, length: length, measured: RelayPace(runsOutAt: runsOut), now: now)
        }

        let start = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(start)
        let fraction = elapsed / length

        if used >= 100 {
            return Pace(verdict: .limitReached, delta: 100 - fraction * 100, elapsedFraction: fraction, resetsAt: resetsAt, runsOutAt: nil, severity: .critical)
        }
        guard fraction >= minimumElapsed, fraction < 1, used >= minimumUsed else { return nil }

        let delta = used - fraction * 100
        let verdict: Verdict
        if delta >= tolerance {
            verdict = .ahead
        } else if delta <= -tolerance {
            verdict = .plentyLeft
        } else {
            verdict = .onPace
        }

        var runsOut: Date?
        if let measured {
            runsOut = measured.runsOutAt.flatMap { $0 < resetsAt ? max($0, now) : nil }
        } else if let rate = recentRate(samples: samples, since: start, kind: kind, now: now) ?? linearRate(used: used, elapsed: elapsed),
           rate > 0 {
            let projected = now.addingTimeInterval((100 - used) / rate)
            if projected < resetsAt {
                runsOut = projected
            }
        }

        let severity: Severity
        if let runsOut {
            let lastQuarter = resetsAt.addingTimeInterval(-length / 4)
            if runsOut.timeIntervalSince(now) < 3_600 {
                severity = .critical
            } else if runsOut >= lastQuarter {
                severity = .watch
            } else {
                severity = .tight
            }
        } else {
            severity = .none
        }
        return Pace(verdict: verdict, delta: delta, elapsedFraction: fraction, resetsAt: resetsAt, runsOutAt: runsOut, severity: severity)
    }

    private static func projected(resetsAt: Date, length: TimeInterval, measured: RelayPace?, now: Date) -> Pace? {
        guard let measuredAt = measured?.runsOutAt, measuredAt < resetsAt else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        let fraction = min(max(now.timeIntervalSince(start) / length, 0), 1)
        let severity: Severity
        if measuredAt.timeIntervalSince(now) < 3_600 {
            severity = .critical
        } else if measuredAt >= resetsAt.addingTimeInterval(-length / 4) {
            severity = .watch
        } else {
            severity = .tight
        }
        return Pace(
            verdict: .ahead,
            delta: 0,
            elapsedFraction: fraction,
            resetsAt: resetsAt,
            runsOutAt: measuredAt,
            severity: severity,
            isProjected: true
        )
    }

    static func windowLength(
        kind: WindowKind,
        resetsAt: Date,
        startsAt: Date?,
        windowSeconds: Double?,
        calendar: Calendar = .gregorianUTC
    ) -> TimeInterval? {
        if let windowSeconds, windowSeconds > 0 {
            return windowSeconds
        }
        if let startsAt, startsAt < resetsAt {
            return resetsAt.timeIntervalSince(startsAt)
        }
        switch kind {
        case .session:
            return 5 * 3_600
        case .daily:
            return 86_400
        case .weekly:
            return 7 * 86_400
        case .monthly, .billingCycle:
            guard let previous = calendar.date(byAdding: .month, value: -1, to: resetsAt) else { return nil }
            return resetsAt.timeIntervalSince(previous)
        case .pool:
            return nil
        }
    }

    static func recentRate(samples: [(date: Date, used: Double)], since start: Date, kind: WindowKind, now: Date) -> Double? {
        let horizon: TimeInterval = kind == .session ? 30 * 60 : 6 * 3_600
        let recent = samples.filter { $0.date >= start && $0.date >= now.addingTimeInterval(-horizon) && $0.date <= now }
        guard recent.count >= 3 else { return nil }
        let times = recent.map { $0.date.timeIntervalSince(now) }
        let values = recent.map(\.used)
        let meanT = times.reduce(0, +) / Double(times.count)
        let meanV = values.reduce(0, +) / Double(values.count)
        var numerator = 0.0
        var denominator = 0.0
        for (time, value) in zip(times, values) {
            numerator += (time - meanT) * (value - meanV)
            denominator += (time - meanT) * (time - meanT)
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    private static func linearRate(used: Double, elapsed: TimeInterval) -> Double? {
        elapsed > 0 ? used / elapsed : nil
    }
}

extension Calendar {
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

extension Pace {
    var needsAttention: Bool {
        (!isProjected && verdict == .ahead) || verdict == .limitReached || runOutNeedsAttention
    }

    var runOutNeedsAttention: Bool {
        runsOutAt != nil && ((!isProjected && verdict == .ahead) || severity == .tight || severity == .critical)
    }

    var currentRunOut: Date? {
        isProjected || verdict == .limitReached ? nil : runsOutAt
    }

    func caption(now: Date = .now, timeZone: TimeZone = .current) -> String {
        if isProjected {
            guard let runsOutAt, runsOutAt > now else { return "Projected to have run out" }
            return "Projected · runs out \(Self.shortMoment(runsOutAt, now: now, timeZone: timeZone))"
        }
        if let runOut = currentRunOut {
            return "Runs out \(Self.shortMoment(runOut, now: now, timeZone: timeZone)) · \(comparison)"
        }
        switch verdict {
        case .onPace:
            return "On pace"
        case .plentyLeft:
            return "Plenty left"
        case .limitReached:
            return RelativeTime.resets(resetsAt, now: now).map { "Limit reached · \($0)" } ?? "Limit reached"
        case .ahead:
            return "Ahead of pace"
        }
    }

    private var comparison: String {
        switch verdict {
        case .ahead: "ahead of pace"
        case .onPace: "on pace so far"
        case .plentyLeft: "below pace so far"
        case .limitReached: "limit reached"
        }
    }

    static func shortMoment(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style)
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            var weekday = Date.FormatStyle().weekday(.abbreviated)
            weekday.timeZone = timeZone
            return "\(date.formatted(weekday)) \(date.formatted(style))"
        }
        var day = Date.FormatStyle().month(.abbreviated).day()
        day.timeZone = timeZone
        return date.formatted(day)
    }
}
