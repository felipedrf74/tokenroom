import Foundation

struct UsageAlert: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case threshold
        case reset
        case bankedNew
        case bankedExpiring
        case lowBalance
        case runsOut
    }

    var id: String
    var provider: String
    var kind: Kind
    var level: Int
    var title: String
    var body: String
    var resetsAt: Date?
    var isUrgent: Bool
    var window: String? = nil
    var instance: String? = nil
    var windowKind: String? = nil
    var detail: String? = nil
    var runsOutAt: Date? = nil
    var projectedRunsOutAt: Date? = nil
    var identityResetAt: Date? = nil
    var identityPeriodSec: TimeInterval? = nil

    var shownKey: String {
        "shown:" + key
    }

    var instanceName: String {
        instance ?? id.components(separatedBy: "-").last ?? ""
    }

    var key: String {
        switch kind {
        case .threshold, .lowBalance, .bankedExpiring:
            "\(kind.rawValue)-\(level)"
        case .reset, .bankedNew, .runsOut:
            kind.rawValue
        }
    }

    var isSession: Bool {
        windowKind == WindowKind.session.rawValue
    }
}

struct AlertPreferences: Codable, Equatable, Sendable {
    var thresholds: [Int] = [80, 95]
    var sessionThresholds: [Int] = [80, 95]
    var sessionRunsOut = true
    var limitRunsOut = true
    var resets = true
    var banked = true
    var lowBalance = true
    var newModels = true
    var quietHours = true
    var quietStartHour = 22
    var quietEndHour = 8
    var timeZoneID = TimeZone.current.identifier
    var updatedAt: Date? = nil
    private var unknown: [String: JSONValue] = [:]

    static let supportedThresholds = [80, 95]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case thresholds, sessionThresholds, sessionRunsOut, limitRunsOut, resets, banked, lowBalance, newModels, quietHours, quietStartHour, quietEndHour, timeZoneID, updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AlertPreferences()
        thresholds = try container.decodeIfPresent([Int].self, forKey: .thresholds) ?? defaults.thresholds
        sessionThresholds = try container.decodeIfPresent([Int].self, forKey: .sessionThresholds) ?? thresholds
        sessionRunsOut = try container.decodeIfPresent(Bool.self, forKey: .sessionRunsOut) ?? defaults.sessionRunsOut
        limitRunsOut = try container.decodeIfPresent(Bool.self, forKey: .limitRunsOut) ?? defaults.limitRunsOut
        resets = try container.decodeIfPresent(Bool.self, forKey: .resets) ?? defaults.resets
        banked = try container.decodeIfPresent(Bool.self, forKey: .banked) ?? defaults.banked
        lowBalance = try container.decodeIfPresent(Bool.self, forKey: .lowBalance) ?? defaults.lowBalance
        newModels = try container.decodeIfPresent(Bool.self, forKey: .newModels) ?? defaults.newModels
        quietHours = try container.decodeIfPresent(Bool.self, forKey: .quietHours) ?? defaults.quietHours
        quietStartHour = try container.decodeIfPresent(Int.self, forKey: .quietStartHour) ?? defaults.quietStartHour
        quietEndHour = try container.decodeIfPresent(Int.self, forKey: .quietEndHour) ?? defaults.quietEndHour
        timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? defaults.timeZoneID
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let everything = try decoder.container(keyedBy: AnyCodingKey.self)
        for key in everything.allKeys where !known.contains(key.stringValue) {
            unknown[key.stringValue] = try? everything.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in unknown {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
        try container.encode(thresholds, forKey: AnyCodingKey(CodingKeys.thresholds.rawValue))
        try container.encode(sessionThresholds, forKey: AnyCodingKey(CodingKeys.sessionThresholds.rawValue))
        try container.encode(sessionRunsOut, forKey: AnyCodingKey(CodingKeys.sessionRunsOut.rawValue))
        try container.encode(limitRunsOut, forKey: AnyCodingKey(CodingKeys.limitRunsOut.rawValue))
        try container.encode(resets, forKey: AnyCodingKey(CodingKeys.resets.rawValue))
        try container.encode(banked, forKey: AnyCodingKey(CodingKeys.banked.rawValue))
        try container.encode(lowBalance, forKey: AnyCodingKey(CodingKeys.lowBalance.rawValue))
        try container.encode(newModels, forKey: AnyCodingKey(CodingKeys.newModels.rawValue))
        try container.encode(quietHours, forKey: AnyCodingKey(CodingKeys.quietHours.rawValue))
        try container.encode(quietStartHour, forKey: AnyCodingKey(CodingKeys.quietStartHour.rawValue))
        try container.encode(quietEndHour, forKey: AnyCodingKey(CodingKeys.quietEndHour.rawValue))
        try container.encode(timeZoneID, forKey: AnyCodingKey(CodingKeys.timeZoneID.rawValue))
        try container.encodeIfPresent(updatedAt, forKey: AnyCodingKey(CodingKeys.updatedAt.rawValue))
    }

    mutating func touch(now: Date = .now, timeZone: TimeZone = .current) {
        updatedAt = now
        timeZoneID = timeZone.identifier
    }

    static func newest(_ shared: AlertPreferences?, _ local: AlertPreferences) -> AlertPreferences {
        guard let shared else { return local }
        return (shared.updatedAt ?? .distantPast) >= (local.updatedAt ?? .distantPast) ? shared : local
    }

    var subscribedKeys: [String] {
        var keys: [String] = []
        for level in Self.supportedThresholds where thresholds.contains(level) || sessionThresholds.contains(level) {
            keys.append("threshold-\(level)")
        }
        if sessionRunsOut || limitRunsOut {
            keys.append("runsOut")
        }
        if lowBalance {
            keys += Self.supportedThresholds.map { "lowBalance-\($0)" }
        }
        if resets {
            keys.append("reset")
        }
        if banked {
            keys += ["bankedNew", "bankedExpiring-48", "bankedExpiring-6"]
        }
        keys.append("test")
        return keys
    }

    func quietEnd(after date: Date) -> Date? {
        guard isQuiet(at: date) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar.nextDate(after: date, matching: DateComponents(hour: quietEndHour, minute: 0), matchingPolicy: .nextTime)
    }

    func isQuiet(at date: Date) -> Bool {
        guard quietHours, quietStartHour != quietEndHour else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        let hour = calendar.component(.hour, from: date)
        return quietStartHour < quietEndHour
            ? (quietStartHour..<quietEndHour).contains(hour)
            : hour >= quietStartHour || hour < quietEndHour
    }

    func shouldSend(_ alert: UsageAlert, at date: Date) -> Bool {
        alert.isUrgent || !isQuiet(at: date)
    }

    func allows(_ alert: UsageAlert) -> Bool {
        switch alert.kind {
        case .threshold: (alert.isSession ? sessionThresholds : thresholds).contains(alert.level)
        case .lowBalance: lowBalance
        case .reset: resets
        case .bankedNew, .bankedExpiring: banked
        case .runsOut: alert.isSession ? sessionRunsOut : limitRunsOut
        }
    }

    func thresholds(for window: RelayWindow) -> [Int] {
        window.windowKind == .session ? sessionThresholds : thresholds
    }

    func sameChoices(as other: AlertPreferences?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return self == other
    }

    var quietLength: TimeInterval {
        guard quietHours, quietStartHour != quietEndHour else { return 0 }
        return TimeInterval((quietEndHour - quietStartHour + 24) % 24) * 3600
    }

    static func merged(base: AlertPreferences, local: AlertPreferences, remote: AlertPreferences) -> AlertPreferences {
        guard let baseFields = fields(of: base), let localFields = fields(of: local), var result = fields(of: remote) else {
            return local
        }
        let byLevel: Set<String> = [CodingKeys.updatedAt.rawValue, CodingKeys.thresholds.rawValue, CodingKeys.sessionThresholds.rawValue]
        for (key, value) in localFields where !byLevel.contains(key) && baseFields[key] != value {
            result[key] = value
        }
        guard var merged = decoded(result) else { return local }
        func levels(_ keyPath: KeyPath<AlertPreferences, [Int]>) -> [Int] {
            let added = Set(local[keyPath: keyPath]).subtracting(base[keyPath: keyPath])
            let removed = Set(base[keyPath: keyPath]).subtracting(local[keyPath: keyPath])
            return Set(remote[keyPath: keyPath]).union(added).subtracting(removed).sorted()
        }
        merged.thresholds = levels(\.thresholds)
        merged.sessionThresholds = levels(\.sessionThresholds)
        merged.updatedAt = [local.updatedAt, remote.updatedAt].compactMap { $0 }.max()
        return merged
    }

    static func overlaying(_ local: AlertPreferences, on remote: AlertPreferences) -> AlertPreferences {
        guard let localFields = fields(of: local), var result = fields(of: remote) else { return local }
        for (key, value) in localFields {
            result[key] = value
        }
        return decoded(result) ?? local
    }

    private static func decoded(_ fields: [String: JSONValue]) -> AlertPreferences? {
        guard let data = try? RelayEnvelope.encoder.encode(fields) else { return nil }
        return try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: data)
    }

    private static func fields(of preferences: AlertPreferences) -> [String: JSONValue]? {
        guard let data = try? RelayEnvelope.encoder.encode(preferences) else { return nil }
        return try? RelayEnvelope.decoder.decode([String: JSONValue].self, from: data)
    }
}

enum AlertPreferencesSync {
    struct Resolution: Equatable, Sendable {
        var preferences: AlertPreferences
        var needsPublish: Bool
    }

    struct Versioned<Revision: Sendable>: Sendable {
        var preferences: AlertPreferences?
        var revision: Revision
    }

    static func synchronize<Revision: Sendable>(
        base: AlertPreferences?, local: AlertPreferences,
        read: @Sendable () async throws -> Versioned<Revision>,
        write: @Sendable (AlertPreferences, Revision) async throws -> Void,
        isConflict: @Sendable (Error) -> Bool
    ) async throws -> Resolution {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let fetched = try await read()
            let resolution = resolve(base: base, local: local, remote: fetched.preferences)
            guard resolution.needsPublish else { return resolution }
            do {
                try await write(resolution.preferences, fetched.revision)
                return resolution
            } catch {
                guard isConflict(error), attempt < 2 else { throw error }
            }
        }
        preconditionFailure("Bounded preference attempts always return or throw")
    }

    static func resolve(base: AlertPreferences?, local: AlertPreferences, remote: AlertPreferences?) -> Resolution {
        guard let remote else {
            guard local.updatedAt != nil else { return Resolution(preferences: local, needsPublish: false) }
            return publishing(local, over: [base])
        }
        guard let base else {
            if AlertPreferences.newest(remote, local) == remote {
                return Resolution(preferences: remote, needsPublish: false)
            }
            return publishing(AlertPreferences.overlaying(local, on: remote), over: [remote])
        }
        if local.sameChoices(as: base) {
            return Resolution(preferences: remote, needsPublish: false)
        }
        if remote.sameChoices(as: base) {
            return publishing(local, over: [base, remote])
        }
        return publishing(AlertPreferences.merged(base: base, local: local, remote: remote), over: [base])
    }

    private static func publishing(_ preferences: AlertPreferences, over others: [AlertPreferences?]) -> Resolution {
        var preferences = preferences
        preferences.updatedAt = ([preferences.updatedAt] + others.map { $0?.updatedAt }).compactMap { $0 }.max()
        return Resolution(preferences: preferences, needsPublish: true)
    }
}

enum AlertRules {
    static let resetWorthyUse = 80.0
    static let resetJitter: TimeInterval = 30 * 60
    static let resetNewsWindow: TimeInterval = 12 * 3600
    static let resetDrop = 10.0
    static let runsOutMinimumUse = 50.0
    static let runsOutLongLead: TimeInterval = 86_400

    static func alerts(previous: RelayProvider?, current: RelayProvider, preferences: AlertPreferences, samples: [String: [(date: Date, used: Double)]] = [:], now: Date = .now) -> [UsageAlert] {
        guard let previous, current.isLive else { return [] }
        var alerts: [UsageAlert] = []
        for window in current.windows where window.isMetered && !window.isAwaitingReading(at: now) {
            guard let before = previous.windows.first(where: { $0.id == window.id }) else { continue }
            let sameInstance = isSameInstance(before: before, current: window, now: now)
            let isMoney = isMoneyWindow(window)
            let levels = isMoney ? (preferences.lowBalance ? AlertPreferences.supportedThresholds : []) : preferences.thresholds(for: window)
            let crossed = levels.sorted(by: >).first { level in
                window.used >= Double(level) && (!sameInstance || before.used < Double(level))
            }
            if let level = crossed {
                alerts.append(isMoney ? lowBalance(current, window: window, level: level, now: now) : threshold(current, window: window, level: level, now: now))
            } else if !isMoney, let alert = runsOut(current, window: window, preferences: preferences, samples: samples[window.id] ?? [], now: now) {
                alerts.append(alert)
            }
            if preferences.resets, !isMoney, !sameInstance, before.used >= resetWorthyUse, let oldReset = before.resetsAt,
               oldReset <= now.addingTimeInterval(resetJitter), oldReset > now.addingTimeInterval(-resetNewsWindow) {
                let name = instance(oldReset, window: before, now: now)
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-\(window.id)-reset-\(name)",
                    provider: current.id,
                    kind: .reset,
                    level: 0,
                    title: "\(current.name): \(window.displayTitle) reset",
                    body: "Fresh headroom. It was at \(TokenroomFormat.percentText(before.used))% before the reset.",
                    resetsAt: window.resetsAt,
                    isUrgent: false,
                    window: window.id,
                    instance: name,
                    windowKind: before.kind,
                    identityResetAt: oldReset,
                    identityPeriodSec: before.periodSec
                ))
            }
        }
        if preferences.banked, let banked = current.banked {
            let before = previous.banked?.available ?? 0
            if banked.available > before {
                let next = banked.nextExpiry(after: now)
                alerts.append(UsageAlert(
                    id: "evt-\(current.id)-banked-\(banked.available)-\(instance(next))",
                    provider: current.id,
                    kind: .bankedNew,
                    level: 0,
                    title: "\(current.name): banked reset available",
                    body: banked.available == 1 ? "You have 1 to use when a limit runs out." : "You have \(banked.available) to use when a limit runs out.",
                    resetsAt: next,
                    isUrgent: false
                ))
            }
            if let expiry = banked.nextExpiry(after: now) {
                let left = expiry.timeIntervalSince(now)
                for hours in [6, 48] where left <= Double(hours) * 3600 {
                    alerts.append(UsageAlert(
                        id: "evt-\(current.id)-banked-expiry-\(hours)-\(instance(expiry))",
                        provider: current.id,
                        kind: .bankedExpiring,
                        level: hours,
                        title: "\(current.name): banked reset expires soon",
                        body: "Use it by \(expiry.formatted(.dateTime.weekday(.abbreviated).hour().minute())), or it's gone.",
                        resetsAt: expiry,
                        isUrgent: hours <= 6
                    ))
                    break
                }
            }
        }
        return alerts
    }

    static func isMoneyWindow(_ window: RelayWindow) -> Bool {
        guard let unit = window.amount?.unit else { return false }
        return unit == "usd" || unit == "cny"
    }

    private static func threshold(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let name = instance(window.resetsAt, window: window, now: now)
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-\(level)-\(name)",
            provider: provider.id,
            kind: .threshold,
            level: level,
            title: "\(provider.name): \(level)% of \(window.limitName) used",
            body: resetSentence(window.resetsAt, now: now) ?? "It resets when \(provider.name) says so.",
            resetsAt: window.resetsAt,
            isUrgent: level >= 95,
            window: window.id,
            instance: name,
            windowKind: window.kind,
            identityPeriodSec: window.periodSec
        )
    }

    static func runsOut(_ provider: RelayProvider, window: RelayWindow, preferences: AlertPreferences, samples: [(date: Date, used: Double)] = [], now: Date) -> UsageAlert? {
        let isSession = window.windowKind == .session
        guard !isMoneyWindow(window),
              isSession ? preferences.sessionRunsOut : preferences.limitRunsOut,
              window.used >= runsOutMinimumUse, window.used < 95,
              let pace = UsageRanking.pace(for: window, isStale: !provider.isLive, samples: samples, now: now),
              pace.verdict == .ahead, let runsOutAt = pace.runsOutAt,
              isSession || pace.resetsAt.timeIntervalSince(runsOutAt) >= runsOutLongLead
        else { return nil }
        return runsOut(provider, window: window, pace: pace, runsOutAt: runsOutAt, preferences: preferences, now: now)
    }

    static func runsOut(updating alert: UsageAlert, provider: RelayProvider, window: RelayWindow, preferences: AlertPreferences, samples: [(date: Date, used: Double)] = [], now: Date) -> UsageAlert? {
        guard let pace = UsageRanking.pace(for: window, isStale: !provider.isLive, samples: samples, now: now),
              let runsOutAt = pace.runsOutAt
        else { return nil }
        var updated = runsOut(provider, window: window, pace: pace, runsOutAt: runsOutAt, preferences: preferences, now: now)
        updated.id = alert.id
        updated.instance = alert.instance
        return updated
    }

    private static func runsOut(_ provider: RelayProvider, window: RelayWindow, pace: Pace, runsOutAt: Date, preferences: AlertPreferences, now: Date) -> UsageAlert {
        let name = instance(window.resetsAt, window: window, now: now)
        let zone = TimeZone(identifier: preferences.timeZoneID) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let moment = Pace.shortMoment(runsOutAt, now: now, timeZone: zone)
        let when = calendar.isDate(runsOutAt, inSameDayAs: now) ? "at \(moment)" : moment
        let used = "\(TokenroomFormat.percentText(window.used))% used"
        let basis = pace.isProjected ? "\(used) at last check" : used
        let remaining = runsOutAt.timeIntervalSince(now)
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-runsOut-\(name)",
            provider: provider.id,
            kind: .runsOut,
            level: 0,
            title: "\(provider.name): \(window.limitName) runs out \(when)",
            body: "\(basis), \(UsageTiles.lead(runsOut: runsOutAt, resetsAt: pace.resetsAt)).",
            resetsAt: window.resetsAt,
            isUrgent: remaining < 3600 && remaining > -3600,
            window: window.id,
            instance: name,
            windowKind: window.kind,
            runsOutAt: pace.isProjected ? nil : runsOutAt,
            projectedRunsOutAt: pace.isProjected ? runsOutAt : nil,
            identityPeriodSec: window.periodSec
        )
    }

    static func runsOutDeadline(_ alert: UsageAlert) -> Date? {
        guard alert.kind == .runsOut, let runsOutAt = alert.runsOutAt ?? alert.projectedRunsOutAt else { return nil }
        return runsOutAt.addingTimeInterval(3600)
    }

    private static func resetSentence(_ resetsAt: Date?, now: Date) -> String? {
        resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
    }

    static func refreshed(_ alert: UsageAlert, now: Date) -> UsageAlert {
        guard let resetsAt = alert.resetsAt, resetsAt > now else { return alert }
        var alert = alert
        switch alert.kind {
        case .threshold:
            alert.body = resetSentence(resetsAt, now: now) ?? alert.body
        case .lowBalance:
            if let detail = alert.detail, let reset = RelativeTime.resets(resetsAt, now: now) {
                alert.body = "\(detail) It \(reset)."
            }
        case .runsOut:
            if let projected = alert.projectedRunsOutAt {
                let remaining = projected.timeIntervalSince(now)
                alert.isUrgent = remaining < 3600 && remaining > -3600
            }
        case .reset, .bankedNew, .bankedExpiring:
            break
        }
        return alert
    }

    static func neighbouringDayIDs(of alert: UsageAlert) -> [String] {
        let name = alert.instanceName
        guard alert.resetsAt == nil, name.hasPrefix("d"), let day = Int(name.dropFirst()), alert.id.hasSuffix(name) else { return [] }
        let stem = String(alert.id.dropLast(name.count))
        return [stem + "d\(day - 1)", stem + "d\(day + 1)"]
    }

    static func id(of alert: UsageAlert, atLevel level: Int) -> String? {
        guard let window = alert.window, let instance = alert.instance else { return nil }
        switch alert.kind {
        case .threshold: return "evt-\(alert.provider)-\(window)-\(level)-\(instance)"
        case .lowBalance: return "evt-\(alert.provider)-\(window)-low-\(level)-\(instance)"
        case .reset, .bankedNew, .bankedExpiring, .runsOut: return nil
        }
    }

    private static func lowBalance(_ provider: RelayProvider, window: RelayWindow, level: Int, now: Date) -> UsageAlert {
        let amount = window.amount
        let unit = amount?.unit ?? "usd"
        let title: String
        let body: String
        var detail: String?
        if window.resetsAt == nil {
            title = "\(provider.name): balance is low"
            let left = amount?.remainingOrComputed.map { AmountFormat.text(max($0, 0), unit: unit) }
            let reference = amount?.limit.map { AmountFormat.text($0, unit: unit) }
            switch (left, reference) {
            case let (left?, reference?):
                body = "\(left) left of your \(reference) reference."
            case let (left?, nil):
                body = "\(left) left."
            default:
                body = "\(level)% of your reference is used."
            }
        } else {
            title = "\(provider.name): \(level)% of the budget spent"
            let spent = amount?.used.map { AmountFormat.text($0, unit: unit) }
            let budget = amount?.limit.map { AmountFormat.text($0, unit: unit) }
            let reset = window.resetsAt.flatMap { RelativeTime.resets($0, now: now) }.map { " It \($0)." } ?? ""
            let spentText = if let spent, let budget { "\(spent) of \(budget) so far." } else { "\(level)% of your budget." }
            detail = spentText
            body = spentText + reset
        }
        let name = instance(window.resetsAt, window: window, now: now)
        return UsageAlert(
            id: "evt-\(provider.id)-\(window.id)-low-\(level)-\(name)",
            provider: provider.id,
            kind: .lowBalance,
            level: level,
            title: title,
            body: body,
            resetsAt: window.resetsAt,
            isUrgent: level >= 95,
            window: window.id,
            instance: name,
            windowKind: window.kind,
            detail: detail,
            identityPeriodSec: window.periodSec
        )
    }

    static func instance(_ resetsAt: Date?, window: RelayWindow? = nil, now: Date = .now) -> String {
        guard let resetsAt else {
            return window.map { _ in "d\(Int(now.timeIntervalSince1970 / 86_400))" } ?? "open"
        }
        let length = window?.periodSec ?? window.map { Self.typicalLength(kind: $0.kind) } ?? 0
        let bucket: Double = length >= 86_400 ? 3600 : 600
        return String(Int((resetsAt.timeIntervalSince1970 / bucket).rounded()) * Int(bucket / 600))
    }

    static func typicalLength(kind: String) -> TimeInterval {
        switch WindowKind(rawValue: kind) {
        case .session: 5 * 3600
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly, .billingCycle: 30 * 86_400
        case .pool, nil: 0
        }
    }

    static func isSameInstance(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince(rhs)) < resetJitter
        default:
            return false
        }
    }

    static func isSameInstance(before: RelayWindow, current: RelayWindow, now: Date) -> Bool {
        isSameInstance(before.resetsAt, current.resetsAt)
            || isMovedReset(from: before.resetsAt, to: current.resetsAt, usedBefore: before.used, usedNow: current.used,
                            length: current.periodSec ?? typicalLength(kind: current.kind), now: now)
    }

    static func isMovedReset(from old: Date?, to new: Date?, usedBefore: Double, usedNow: Double, length: TimeInterval?, now: Date) -> Bool {
        guard let old, let new, old > now else { return false }
        return isSmallMove(from: old, to: new, usedBefore: usedBefore, usedNow: usedNow, length: length)
    }

    static func isSmallMove(from old: Date, to new: Date, usedBefore: Double, usedNow: Double, length: TimeInterval?) -> Bool {
        abs(new.timeIntervalSince(old)) <= max(resetJitter, (length ?? 0) / 4) && usedNow > usedBefore - resetDrop
    }
}

struct AlertLedger: Codable, Equatable, Sendable {
    struct Pending: Codable, Equatable, Sendable {
        var alert: UsageAlert
        var raisedAt: Date
    }

    var lastSeen: [String: RelayProvider] = [:]
    var sent: [String: Date] = [:]
    var pending: [Pending] = []
    var shownHere: [String: Date] = [:]
    var levelsSent: [String: LevelSent] = [:]
    private var runOutInstances: [String: RelayWindow] = [:]

    struct LevelSent: Codable, Equatable, Sendable {
        var level: Int
        var sentAt: Date
    }

    static let memory: TimeInterval = 14 * 86_400
    static let pendingLifetime: TimeInterval = 18 * 3600
    static let fileName = "alerts.json"

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastSeen = try container.decodeIfPresent([String: RelayProvider].self, forKey: .lastSeen) ?? [:]
        sent = try container.decodeIfPresent([String: Date].self, forKey: .sent) ?? [:]
        pending = (try? container.decodeIfPresent([Pending].self, forKey: .pending)) ?? []
        shownHere = (try? container.decodeIfPresent([String: Date].self, forKey: .shownHere)) ?? [:]
        levelsSent = (try? container.decodeIfPresent([String: LevelSent].self, forKey: .levelsSent)) ?? [:]
        runOutInstances = (try? container.decodeIfPresent([String: RelayWindow].self, forKey: .runOutInstances)) ?? [:]
    }

    @discardableResult
    mutating func process(_ providers: [RelayProvider], preferences: AlertPreferences, samples: [String: [String: [(date: Date, used: Double)]]] = [:], now: Date = .now) -> [UsageAlert] {
        var fresh: [UsageAlert] = []
        for provider in providers {
            if provider.isLive {
                refreshHeldRunOuts(provider, previous: lastSeen[provider.id], preferences: preferences, samples: samples[provider.id] ?? [:], now: now)
                for alert in AlertRules.alerts(previous: lastSeen[provider.id], current: provider, preferences: preferences, samples: samples[provider.id] ?? [:], now: now)
                where sent[alert.id] == nil && !pending.contains(where: { $0.alert.id == alert.id }) && !fresh.contains(where: { $0.id == alert.id })
                    && reserveRunOutInstance(for: alert, provider: provider, now: now) {
                    fresh.append(alert)
                    pending.append(Pending(alert: alert, raisedAt: now))
                }
                lastSeen[provider.id] = Self.remembering(provider, over: lastSeen[provider.id], now: now)
            } else if lastSeen[provider.id] != nil {
                for window in provider.windows where window.isMetered && !window.isAwaitingReading(at: now) {
                    guard let alert = AlertRules.runsOut(provider, window: window, preferences: preferences, samples: samples[provider.id]?[window.id] ?? [], now: now),
                          sent[alert.id] == nil,
                          !pending.contains(where: { $0.alert.id == alert.id }),
                          !fresh.contains(where: { $0.id == alert.id }),
                          reserveRunOutInstance(for: alert, provider: provider, now: now)
                    else { continue }
                    fresh.append(alert)
                    pending.append(Pending(alert: alert, raisedAt: now))
                }
            }
        }
        prune(preferences: preferences, now: now)
        return fresh
    }

    private mutating func refreshHeldRunOuts(_ provider: RelayProvider, previous: RelayProvider?, preferences: AlertPreferences, samples: [String: [(date: Date, used: Double)]], now: Date) {
        var dropped: [String] = []
        pending = pending.compactMap { item in
            guard item.alert.kind == .runsOut, item.alert.provider == provider.id, let id = item.alert.window,
                  let window = provider.windows.first(where: { $0.id == id }), !window.isAwaitingReading(at: now),
                  let before = previous?.windows.first(where: { $0.id == id }),
                  AlertRules.isSameInstance(before: before, current: window, now: now)
            else { return item }
            guard let updated = AlertRules.runsOut(updating: item.alert, provider: provider, window: window, preferences: preferences, samples: samples[id] ?? [], now: now) else {
                dropped.append(id)
                return nil
            }
            return Pending(alert: updated, raisedAt: item.raisedAt)
        }
        for id in dropped {
            runOutInstances[provider.id + "/" + id] = nil
        }
    }

    private static func remembering(_ provider: RelayProvider, over previous: RelayProvider?, now: Date) -> RelayProvider {
        guard let previous else { return provider }
        let present = Set(provider.windows.map(\.id))
        var remembered = provider
        remembered.windows += previous.windows.filter { window in
            !present.contains(window.id) && (window.resetsAt.map { $0 > now } ?? false)
        }
        return remembered
    }

    private mutating func reserveRunOutInstance(for alert: UsageAlert, provider: RelayProvider, now: Date) -> Bool {
        guard alert.kind == .runsOut, let id = alert.window,
              let window = provider.windows.first(where: { $0.id == id }) else { return true }
        let key = provider.id + "/" + id
        if runOutInstances[key] == nil {
            if let held = pending.first(where: { $0.alert.kind == .runsOut && $0.alert.provider == provider.id && $0.alert.window == id }),
               let reset = held.alert.resetsAt {
                var before = lastSeen[provider.id]?.windows.first(where: { $0.id == id }) ?? window
                before.resetsAt = reset
                runOutInstances[key] = before
            } else if let before = lastSeen[provider.id]?.windows.first(where: { $0.id == id }) {
                let name = AlertRules.instance(before.resetsAt, window: before, now: now)
                if sent["evt-\(provider.id)-\(id)-runsOut-\(name)"] != nil {
                    runOutInstances[key] = before
                }
            }
        }
        if let before = runOutInstances[key], AlertRules.isSameInstance(before: before, current: window, now: now) {
            return false
        }
        runOutInstances[key] = window
        return true
    }

    func due(preferences: AlertPreferences, now: Date = .now) -> [UsageAlert] {
        let ready = pending.map { item in
            var item = item
            item.alert = AlertRules.refreshed(item.alert, now: now)
            return item
        }.filter { preferences.allows($0.alert) && preferences.shouldSend($0.alert, at: now) && !Self.isPastRunOut($0.alert, now: now) }
        let going = ready.map(\.alert)
        return ready
            .filter { !Self.isSuperseded($0, sent: sent, levelsSent: levelsSent, going: going) }
            .map(\.alert)
    }

    private static func isSuperseded(_ item: Pending, sent: [String: Date], levelsSent: [String: LevelSent], going: [UsageAlert]) -> Bool {
        let alert = item.alert
        if let key = levelKey(alert), let higher = levelsSent[key], higher.level > alert.level, higher.sentAt >= item.raisedAt {
            return true
        }
        if alert.kind == .runsOut, let window = alert.window {
            if let sent95 = levelsSent["\(alert.provider)/\(window)/\(UsageAlert.Kind.threshold.rawValue)"], sent95.level >= 95, sent95.sentAt >= item.raisedAt {
                return true
            }
            if going.contains(where: { $0.kind == .threshold && $0.level >= 95 && $0.provider == alert.provider && $0.window == window }) {
                return true
            }
        }
        return AlertPreferences.supportedThresholds.contains { level in
            guard level > alert.level, let higher = AlertRules.id(of: alert, atLevel: level) else { return false }
            return sent[higher] != nil || going.contains { $0.id == higher }
        }
    }

    private static func isPastRunOut(_ alert: UsageAlert, now: Date) -> Bool {
        AlertRules.runsOutDeadline(alert).map { $0 <= now } ?? false
    }

    private static func levelKey(_ alert: UsageAlert) -> String? {
        guard let window = alert.window, alert.kind == .threshold || alert.kind == .lowBalance else { return nil }
        return "\(alert.provider)/\(window)/\(alert.kind.rawValue)"
    }

    mutating func markSent(_ ids: [String], at now: Date = .now) {
        let delivered = Set(ids)
        for id in delivered {
            sent[id] = now
        }
        for item in pending where delivered.contains(item.alert.id) {
            guard let key = Self.levelKey(item.alert), (levelsSent[key]?.level ?? 0) <= item.alert.level else { continue }
            levelsSent[key] = LevelSent(level: item.alert.level, sentAt: now)
        }
        pending.removeAll { delivered.contains($0.alert.id) }
    }

    struct Delivery: Equatable, Sendable {
        var saved: [String] = []
        var announced: Set<String> = []
    }

    mutating func settle(_ due: [UsageAlert], delivery: Delivery?, showsHere: Bool, now: Date = .now) -> [UsageAlert] {
        let announced = delivery?.announced ?? []
        let shown = showsHere ? due.filter { shownHere[$0.id] == nil && !announced.contains($0.id) } : []
        markShownHere(shown.map(\.id), at: now)
        markSent(delivery?.saved ?? due.map(\.id), at: now)
        return shown
    }

    mutating func markShownHere(_ ids: [String], at now: Date = .now) {
        for id in ids {
            shownHere[id] = now
        }
    }

    private mutating func prune(preferences: AlertPreferences, now: Date) {
        sent = sent.filter { now.timeIntervalSince($0.value) < Self.memory }
        shownHere = shownHere.filter { now.timeIntervalSince($0.value) < Self.memory }
        levelsSent = levelsSent.filter { now.timeIntervalSince($0.value.sentAt) < Self.memory }
        runOutInstances = runOutInstances.filter { $0.value.resetsAt.map { now.timeIntervalSince($0) < Self.memory } ?? false }
        let lifetime = max(Self.pendingLifetime, preferences.quietLength + 3600)
        let delivered = sent
        let shown = shownHere
        let levels = levelsSent
        var lapsed: [UsageAlert] = []
        pending.removeAll { item in
            if now.timeIntervalSince(item.raisedAt) > lifetime { return true }
            if Self.isPastRunOut(item.alert, now: now) {
                if delivered[item.alert.id] == nil && shown[item.alert.id] == nil {
                    lapsed.append(item.alert)
                }
                return true
            }
            if !preferences.allows(item.alert) || Self.isSuperseded(item, sent: delivered, levelsSent: levels, going: []) { return true }
            switch item.alert.kind {
            case .threshold, .lowBalance, .bankedExpiring, .runsOut:
                return item.alert.resetsAt.map { $0 <= now } ?? false
            case .reset, .bankedNew:
                return false
            }
        }
        for alert in lapsed {
            releaseRunOutInstance(of: alert, now: now)
        }
    }

    private mutating func releaseRunOutInstance(of alert: UsageAlert, now: Date) {
        guard let window = alert.window else { return }
        let key = alert.provider + "/" + window
        guard let held = runOutInstances[key], AlertRules.instance(held.resetsAt, window: held, now: now) == alert.instance else { return }
        runOutInstances[key] = nil
    }

    static func load(from directory: URL?) -> AlertLedger {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let ledger = try? RelayEnvelope.decoder.decode(AlertLedger.self, from: data)
        else { return AlertLedger() }
        return ledger
    }

    func save(to directory: URL?) {
        guard let url = directory?.appendingPathComponent(Self.fileName),
              let data = try? RelayEnvelope.encoder.encode(self)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
