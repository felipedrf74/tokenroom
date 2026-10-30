import SwiftUI

/// A ring for one window: used percent in its level's colour, a lighter tint at the start running
/// to the full colour at the tip, where a rounded cap casts a soft shadow, as Apple's Activity
/// rings do. A label (the monogram or the percent) sits in the middle. Scales to its frame, from a
/// Watch row to the iPhone's summary card.
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
                    if showsTip {
                        // The tip: a cap in the full colour with a soft shadow, so the end reads
                        // as raised above the track (and above the start once it laps).
                        Circle()
                            .fill(TokenroomTokens.usageTones(usedPercent: used).end)
                            .frame(width: width, height: width)
                            .shadow(color: .black.opacity(0.28), radius: width * 0.22)
                            .offset(tipOffset(radius: side / 2))
                    }
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
                HeadlineValue(
                    text: label,
                    font: .system(size: side * 0.3, weight: .semibold, design: .rounded),
                    signFont: .system(size: side * 0.17, weight: .semibold, design: .rounded)
                )
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

    /// A tip needs room to show as one: not on a sliver, not on a faded reading.
    private var showsTip: Bool {
        !isStale && fraction >= 0.04
    }

    /// Where the tip sits: the end of the arc, clockwise from 12 o'clock.
    private func tipOffset(radius: CGFloat) -> CGSize {
        let angle = Double(fraction) * 2 * .pi - .pi / 2
        return CGSize(width: radius * cos(angle), height: radius * sin(angle))
    }

    /// From a lighter tint of the level's colour to the colour itself at the tip. It starts a
    /// little before 12 o'clock, so the round cap at the start takes the tint.
    private var fill: AnyShapeStyle {
        if isStale {
            return AnyShapeStyle(Color.secondary)
        }
        let tones = TokenroomTokens.usageTones(usedPercent: used)
        let end = max(Double(fraction) * 360, 1)
        return AnyShapeStyle(AngularGradient(colors: [tones.start, tones.end], center: .center, startAngle: .degrees(-8), endAngle: .degrees(end)))
    }
}
