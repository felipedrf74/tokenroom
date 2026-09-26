import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity on the Lock Screen, and on Apple Watch in the Smart Stack (`small`).
struct SessionLockScreenView: View {
    var attributes: SessionActivityAttributes
    var state: SessionActivityAttributes.ContentState
    @Environment(\.activityFamily) private var family

    var body: some View {
        let color = TokenroomTokens.usageColor(usedPercent: state.used, isStale: state.isStale)
        if family == .small {
            // The Apple Watch Smart Stack.
            HStack(spacing: 8) {
                ProviderMark(providerID: attributes.providerID, monogram: attributes.monogram, tint: attributes.tint, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(attributes.shortName) \(state.percentText)")
                        .font(.headline)
                        .monospacedDigit()
                    Countdown(resetsAt: state.resetsAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            HStack(spacing: 14) {
                ProviderMark(providerID: attributes.providerID, monogram: attributes.monogram, tint: attributes.tint, size: 40)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(attributes.providerName)
                            .font(.headline)
                        Spacer()
                        Text(state.percentText)
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(color)
                    }
                    MeterTrack(usedPercent: state.used, remaining: 100 - state.used, isStale: state.isStale, paceMark: attributes.paceMark(for: state), height: 6, solid: true)
                    HStack {
                        Text(attributes.windowTitle)
                        Spacer()
                        Countdown(resetsAt: state.resetsAt)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .opacity(state.isStale ? 0.7 : 1)
        }
    }
}

extension SessionActivityAttributes {
    /// Where an even pace would be when the view is drawn, from the window's length.
    func paceMark(for state: ContentState) -> Double? {
        guard let length = windowSeconds, length > 0 else { return nil }
        return min(max(1 - state.resetsAt.timeIntervalSinceNow / length, 0), 1)
    }
}

/// "Resets in 2:10:33", counting down on its own; "Reset" once it's passed.
struct Countdown: View {
    var resetsAt: Date

    var body: some View {
        // One reading of the clock, so the range can't come out reversed.
        let now = Date.now
        if resetsAt > now {
            Text("Resets in \(Text(timerInterval: now...resetsAt, countsDown: true))")
                .monospacedDigit()
        } else {
            Text("Reset")
        }
    }
}

extension SessionActivityAttributes.ContentState {
    var percentText: String {
        "\(TokenroomFormat.percentText(used))%"
    }
}

