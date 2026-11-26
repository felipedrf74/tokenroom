import Foundation

struct RelayPublishPolicy: Sendable, Equatable {
    static let heartbeat: TimeInterval = 9 * 60
    static let minimumInterval: TimeInterval = 5 * 60
    static let statusInterval: TimeInterval = 60

    private(set) var lastHash: Int?
    private(set) var lastStates: [String: String] = [:]
    private(set) var lastLevels: [String: Int] = [:]
    private(set) var lastRunOuts: [String: Date] = [:]
    private(set) var lastSent: Date?

    func isDue(_ envelope: RelayEnvelope, force: Bool = false, now: Date) -> Bool {
        force || nextSendDate(envelope, now: now) <= now
    }

    func nextSendDate(_ envelope: RelayEnvelope, now: Date) -> Date {
        guard lastHash != nil, let lastSent, lastSent <= now else { return now }
        let urgent = Self.states(envelope) != lastStates || Self.levels(envelope) != lastLevels
        let changed = envelope.materialHash != lastHash || runOutsMoved(envelope)
        let interval = urgent ? Self.statusInterval : changed ? Self.minimumInterval : Self.heartbeat
        return max(now, lastSent.addingTimeInterval(interval))
    }

    func hasChanges(_ envelope: RelayEnvelope) -> Bool {
        envelope.materialHash != lastHash || Self.states(envelope) != lastStates
            || Self.levels(envelope) != lastLevels || runOutsMoved(envelope)
    }

    mutating func didSend(_ envelope: RelayEnvelope, at now: Date) {
        lastHash = envelope.materialHash
        lastStates = Self.states(envelope)
        lastLevels = Self.levels(envelope)
        lastRunOuts = envelope.runOuts
        lastSent = now
    }

    private func runOutsMoved(_ envelope: RelayEnvelope) -> Bool {
        Self.runOutsMoved(envelope.runOuts, since: lastRunOuts)
    }

    static func runOutsMoved(_ runOuts: [String: Date], since sent: [String: Date]) -> Bool {
        guard Set(runOuts.keys) == Set(sent.keys) else { return true }
        return runOuts.contains { key, date in
            guard let last = sent[key] else { return true }
            guard date != .distantFuture, last != .distantFuture else { return date != last }
            return abs(date.timeIntervalSince(last)) >= RelayEnvelope.runOutStep
        }
    }

    mutating func reset() {
        lastHash = nil
    }

    private static func states(_ envelope: RelayEnvelope) -> [String: String] {
        Dictionary(envelope.providers.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    }

    private static func levels(_ envelope: RelayEnvelope) -> [String: Int] {
        var levels: [String: Int] = [:]
        for provider in envelope.providers {
            for window in provider.windows where window.isMetered {
                levels[provider.id + "/" + window.id] = AlertPreferences.supportedThresholds.filter { window.used >= Double($0) }.max() ?? 0
            }
        }
        return levels
    }
}
