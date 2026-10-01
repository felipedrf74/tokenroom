import SwiftUI

/// A ring for one window: used percent in the usage gradient, a label (the monogram or the
/// percent) in the middle. Scales to its frame, from a Watch row to the iPhone's summary card.
struct UsageRing: View {
    var used: Double
    var isStale: Bool
    var label: String
    /// Stroke width; nil scales with the ring.
    var lineWidth: CGFloat? = nil
    /// Where an even pace would be now, 0–1 of the window; drawn as a notch across the ring.
    var paceMark: Double? = nil

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let width = lineWidth ?? max(3, side * 0.11)
            let pace = paceMark.map { min(max($0, 0), 1) }.flatMap { isStale ? nil : $0 }
            ZStack {
                ZStack {
                    Circle()
                        .stroke(TokenroomTokens.track, lineWidth: width)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if let pace {
                        // A notch cut through the ring where an even pace would be.
                        Capsule()
                            .fill(.black)
                            .frame(width: 4, height: width + 2)
                            .offset(y: -side / 2)
                            .rotationEffect(.degrees(360 * pace))
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
                if let pace {
                    Capsule()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2, height: width + 5)
                        .offset(y: -side / 2)
                        .rotationEffect(.degrees(360 * pace))
                }
                Text(label)
                    .font(.system(size: side * 0.3, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(width)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let used = "\(TokenroomFormat.percentText(used)) percent used"
        guard let paceMark, !isStale else { return used }
        return "\(used), \(TokenroomFormat.percentText(min(max(paceMark, 0), 1) * 100)) percent of the window has passed"
    }

    private var fraction: CGFloat {
        CGFloat(min(max(used, 0), 100) / 100)
    }

    /// The gradient runs around the whole ring, so 30% stays cool and 95% reaches red.
    private var fill: AnyShapeStyle {
        if isStale {
            return AnyShapeStyle(Color.secondary)
        }
        // Starts a little before 12 o'clock, so the round cap at the start takes the first color
        // instead of the last one wrapping around.
        return AnyShapeStyle(AngularGradient(gradient: TokenroomTokens.usageGradient, center: .center, startAngle: .degrees(-12), endAngle: .degrees(348)))
    }
}
