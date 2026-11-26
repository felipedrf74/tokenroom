import Foundation

struct UsageHistory: Codable, Equatable, Sendable {
    static let capacity = 168
    static let step: TimeInterval = 3_600
    static let resetJitter: TimeInterval = 30 * 60
    static let resetDrop = 10.0
    static let freshUse = 10.0

    var start: Date
    var used: [UInt8?]
    var amounts: [Double?]? = nil
    var amountUnit: String? = nil
    var amountCheckedAt: Date? = nil
    var resets: [Date]? = nil
    var windowResetsAt: Date? = nil

    init(endingAt now: Date) {
        start = Self.hourStart(now).addingTimeInterval(-Double(Self.capacity - 1) * Self.step)
        used = Array(repeating: nil, count: Self.capacity)
    }

    static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    var end: Date {
        start.addingTimeInterval(Double(used.count) * Self.step)
    }

    @discardableResult
    mutating func record(_ percent: Double, at date: Date) -> Bool {
        guard let index = bucket(for: date) else { return false }
        let value = UInt8(clamping: Int(min(max(percent, 0), 100).rounded()))
        let next = max(used[index] ?? 0, value)
        guard used[index] != next else { return false }
        used[index] = next
        return true
    }

    @discardableResult
    mutating func recordAmount(_ remaining: Double, unit: String, at date: Date) -> Bool {
        let lastCheck = amountCheckedAt ?? amountPoints.last?.date
        guard remaining.isFinite, unit == "usd" || unit == "cny",
              lastCheck.map({ date >= $0 }) != false else { return false }
        guard let index = bucket(for: date) else { return false }
        let changedUnit = amountUnit != unit
        if changedUnit {
            amounts = nil
            amountUnit = unit
        }
        let changedCheck = amountCheckedAt != date
        amountCheckedAt = date
        var values = amounts ?? Array(repeating: nil, count: Self.capacity)
        guard changedUnit || changedCheck || values[index] != remaining else { return false }
        values[index] = remaining
        amounts = values
        return true
    }

    func migratingLegacyAmounts(for providerID: String) -> UsageHistory {
        guard amountUnit == nil, amounts != nil else { return self }
        var copy = self
        if let provider = Provider(rawValue: providerID),
           let unit = BudgetReferencePreferences.legacyUnit(for: provider) {
            copy.amountUnit = unit
            copy.amountCheckedAt = amountPoints.last?.date
        } else {
            copy.amounts = nil
            copy.amountCheckedAt = nil
        }
        return copy
    }

    @discardableResult
    mutating func recordResetTime(_ resetsAt: Date?, used percent: Double? = nil, length: TimeInterval? = nil, at date: Date) -> Bool {
        guard let resetsAt else { return false }
        defer { windowResetsAt = resetsAt }
        guard let previous = windowResetsAt, resetsAt.timeIntervalSince(previous) > Self.resetJitter,
              let reset = previous <= date ? previous : earlyReset(opening: resetsAt, used: percent, length: length, at: date)
        else {
            return windowResetsAt.map { abs(resetsAt.timeIntervalSince($0)) > 15 * 60 } ?? true
        }
        var list = (resets ?? []).filter { $0 >= start }
        if reset >= start, !list.contains(reset) {
            list.append(reset)
        }
        resets = list
        return true
    }

    private func earlyReset(opening resetsAt: Date, used percent: Double?, length: TimeInterval?, at date: Date) -> Date? {
        guard let percent, let length, let before = usedBefore(date),
              before - percent >= Self.resetDrop, percent <= before / 2, percent <= Self.freshUse
        else { return nil }
        let opened = resetsAt.addingTimeInterval(-length)
        guard opened <= date.addingTimeInterval(Self.resetJitter) else { return nil }
        return min(opened, date)
    }

    private func usedBefore(_ date: Date) -> Double? {
        let hour = Int((Self.hourStart(date).timeIntervalSince(start) / Self.step).rounded())
        guard hour >= 0 else { return nil }
        let own = hour < used.count ? used[hour] : nil
        let earlier = used.prefix(min(hour, used.count)).last { $0 != nil } ?? nil
        return [own, earlier].compactMap { $0 }.max().map { Double($0) }
    }

    func trimmed(toLast hours: Int) -> UsageHistory? {
        guard hours > 0 else { return nil }
        guard used.count > hours else { return self }
        var copy = self
        let dropped = used.count - hours
        copy.start = start.addingTimeInterval(Double(dropped) * Self.step)
        copy.used = Array(used.suffix(hours))
        copy.amounts = amounts.map { Array($0.suffix(max(0, $0.count - dropped))) }
        copy.resets = resets?.filter { $0 >= copy.start }
        return copy
    }

    private mutating func bucket(for date: Date) -> Int? {
        if used.count < Self.capacity {
            let missing = Self.capacity - used.count
            start = start.addingTimeInterval(-Double(missing) * Self.step)
            used = Array(repeating: nil, count: missing) + used
            amounts = amounts.map { Array(repeating: nil, count: max(0, Self.capacity - $0.count)) + $0 }
        }
        var index = Int((Self.hourStart(date).timeIntervalSince(start) / Self.step).rounded())
        guard index >= 0 else { return nil }
        if index >= Self.capacity {
            let shift = index - Self.capacity + 1
            used = Self.shifted(used, by: shift)
            amounts = amounts.map { Self.shifted($0, by: shift) }
            start = start.addingTimeInterval(Double(shift) * Self.step)
            resets = resets?.filter { $0 >= start }
            index = Self.capacity - 1
        }
        return index
    }

    private static func shifted<Value>(_ values: [Value?], by shift: Int) -> [Value?] {
        guard shift < capacity else { return Array(repeating: nil, count: capacity) }
        return Array(values.dropFirst(shift)) + Array(repeating: nil, count: shift)
    }

    var points: [(date: Date, used: Double)] {
        used.enumerated().compactMap { index, value in
            value.map { (start.addingTimeInterval(Double(index) * Self.step), Double($0)) }
        }
    }

    var amountPoints: [(date: Date, remaining: Double)] {
        (amounts ?? []).enumerated().compactMap { index, value in
            value.map { (start.addingTimeInterval(Double(index) * Self.step), $0) }
        }
    }

    var isEmpty: Bool {
        used.allSatisfy { $0 == nil } && (amounts ?? []).allSatisfy { $0 == nil }
    }
}

struct RelayHistory: Codable, Equatable, Sendable {
    var v: Int = 1
    var series: [String: UsageHistory]

    static func key(provider: String, window: String) -> String {
        "\(provider)/\(window)"
    }

    func encoded() throws -> Data {
        try RelayEnvelope.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RelayHistory {
        try RelayEnvelope.decoder.decode(RelayHistory.self, from: data)
    }
}
