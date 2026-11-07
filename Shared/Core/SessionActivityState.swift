import Foundation

/// A Live Activity's content (`SessionActivityAttributes.ContentState`), here rather than beside
/// ActivityKit so its rules are tested on the Mac. Every field added since the first release is
/// optional, so a state an earlier version encoded still decodes.
struct SessionActivityState: Codable, Hashable, Sendable {
    var used: Double
    var resetsAt: Date
    var isStale: Bool
    /// Whether this activity has alerted that the window runs out before its reset; once per
    /// activity, which ends at the reset. Nil in activities started before 2.1.
    var warnedRunsOut: Bool? = nil
    /// Optional for activities created by earlier versions. Usage remains the last measurement.
    var awaitingReading: Bool? = nil
    /// When the reading was last checked. Nil in activities from before it was kept: those go
    /// stale only at their reset.
    var checkedAt: Date? = nil
}

/// When a Live Activity counts as stale, and how a stale one is shown.
enum LiveActivityFreshness {
    /// ActivityKit marks the activity stale at the reset, or an hour after its reading's check
    /// (`ReadingFreshness.staleAfter`), whichever comes first: without pushes, nothing else
    /// would stop a reading hours old from showing as current.
    static func staleDate(resetsAt: Date, checkedAt: Date?) -> Date {
        guard let checkedAt else { return resetsAt }
        return min(resetsAt, checkedAt.addingTimeInterval(ReadingFreshness.staleAfter))
    }

    /// A newer check alone moves the stale date; the activity is updated for one this far on.
    static let checkStep: TimeInterval = 5 * 60

    /// Whether `new` is worth an update over `old`: anything shown changed, or the reading was
    /// checked again `checkStep` or more since, which moves its stale date.
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
    /// As drawn: past the reset, the recorded amount marked as awaiting a reading (a scheduled
    /// reset isn't a new measurement). Before the reset, a reading over an hour old (or one
    /// ActivityKit marked stale at that time) shows faded at its last percentage, "as of" its
    /// check, not as reset. An activity without `checkedAt` went stale only at its reset, so its
    /// stale flag still means reset.
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

    /// Faded before its reset: the last reading is over an hour old. Not "awaiting a reading".
    var isStaleBeforeReset: Bool {
        isStale && awaitingReading != true && checkedAt != nil
    }
}
