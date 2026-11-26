import Foundation

struct SessionActivityState: Codable, Hashable, Sendable {
    var used: Double
    var resetsAt: Date
    var isStale: Bool
    var warnedRunsOut: Bool? = nil
    var awaitingReading: Bool? = nil
    var checkedAt: Date? = nil
}

enum LiveActivityFreshness {
    static func staleDate(resetsAt: Date, checkedAt: Date?) -> Date {
        guard let checkedAt else { return resetsAt }
        return min(resetsAt, checkedAt.addingTimeInterval(ReadingFreshness.staleAfter))
    }

    static let checkStep: TimeInterval = 5 * 60

    static func needsUpdate(from old: SessionActivityState, to new: SessionActivityState) -> Bool {
        var comparable = new
        comparable.checkedAt = old.checkedAt
        if comparable != old { return true }
        guard let checked = new.checkedAt else { return false }
        guard let before = old.checkedAt else { return true }
        return checked.timeIntervalSince(before) >= checkStep
    }
}

extension SessionActivityState {
    func shown(isStale activityIsStale: Bool, now: Date = .now) -> SessionActivityState {
        var result = self
        if resetsAt <= now || (activityIsStale && checkedAt == nil) {
            result.isStale = true
            result.awaitingReading = true
            return result
        }
        let aged = checkedAt.map { now.timeIntervalSince($0) >= ReadingFreshness.staleAfter } ?? false
        if activityIsStale || aged {
            result.isStale = true
        }
        return result
    }

    var isStaleBeforeReset: Bool {
        isStale && awaitingReading != true && checkedAt != nil
    }
}
