import CoreGraphics
import Foundation

enum MeterLayout {
    static func usedFraction(_ usedPercent: Double) -> CGFloat {
        CGFloat(min(max(usedPercent / 100, 0), 1))
    }

    static func fillLength(usedPercent: Double, total: CGFloat) -> CGFloat {
        let fraction = usedFraction(usedPercent)
        return fraction <= 0 ? 0 : total * fraction
    }

    /// Where the drawn fill ends on a track `total` long and `height` tall: at the fraction,
    /// never widened. A sliver takes its rounded end from the track's own cap, which clips it.
    static func drawnFillEnd(usedPercent: Double, total: CGFloat, height: CGFloat) -> CGFloat {
        fillLength(usedPercent: usedPercent, total: total)
    }

    static func shownUsed(_ usedPercent: Double, isAwaitingReading: Bool) -> Double {
        isAwaitingReading ? 0 : usedPercent
    }

    static func shownPace(_ pace: Double?, isStale: Bool, isAwaitingReading: Bool) -> Double? {
        guard !isStale, !isAwaitingReading, let pace else { return nil }
        return min(max(pace, 0), 1)
    }
}
