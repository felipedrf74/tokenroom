import SwiftUI

/// A ring for one window: used percent in its level's colour, a slightly lighter tint at the start
/// running to the full colour at its rounded tip. A label (the monogram or the percent) sits in
/// the middle. Scales to its frame, from a Watch row to the iPhone's summary card.
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
                // A little wider than the ring: the stroke straddles its frame.
                Canvas { context, size in
                    draw(in: &context, size: size, radius: side / 2, width: width, pace: pace)
                }
                .frame(width: side + width * 2, height: side + width * 2)
                HeadlineValue(
                    text: label,
                    font: .system(size: side * 0.29, weight: .semibold, design: .rounded),
                    signFont: .system(size: side * 0.16, weight: .medium, design: .rounded)
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

    /// Track and fill, with the even pace left out of both as a gap: it's geometry rather than a
    /// blend, so it stays a gap in every view it's composited into, whether use has passed it or not.
    private func draw(in context: inout GraphicsContext, size: CGSize, radius: CGFloat, width: CGFloat, pace: Double?) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let top = Angle.degrees(-90)
        var ring = context
        if let pace {
            let gap = max(3, width * 0.4)
            let notch = Path(CGRect(x: radius - width, y: -gap / 2, width: width * 2, height: gap))
                .applying(CGAffineTransform(rotationAngle: CGFloat(Angle.degrees(360 * pace).radians + top.radians)))
                .applying(CGAffineTransform(translationX: center.x, y: center.y))
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addPath(notch)
            ring.clip(to: outside, style: FillStyle(eoFill: true))
        }
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ring.stroke(circle, with: .color(TokenroomTokens.track), lineWidth: width)
        if fraction > 0 {
            let arc = Path { path in
                path.addArc(center: center, radius: radius, startAngle: top,
                            endAngle: top + .degrees(Double(fraction) * 360), clockwise: false)
            }
            ring.stroke(arc, with: fill(center: center, start: top), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        if let pace {
            let angle = CGFloat(Angle.degrees(360 * pace).radians + top.radians)
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + (radius - width / 2) * cos(angle), y: center.y + (radius - width / 2) * sin(angle)))
            tick.addLine(to: CGPoint(x: center.x + (radius + width / 2) * cos(angle), y: center.y + (radius + width / 2) * sin(angle)))
            context.stroke(tick, with: .color(TokenroomTokens.paceMark), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
    }

    private var accessibilityValue: String {
        let used = "\(TokenroomFormat.percentText(used)) percent used"
        guard let paceMark, !isStale else { return used }
        return "\(used), \(TokenroomFormat.percentText(min(max(paceMark, 0), 1) * 100)) percent of the window has passed"
    }

    private var fraction: CGFloat {
        CGFloat(min(max(used, 0), 100) / 100)
    }

    /// From a slightly lighter tint of the level's colour to the colour itself at the tip. The
    /// sweep starts a little before 12 o'clock and comes back to the tint, so the round cap at
    /// the start of the arc takes the tint rather than the far end's full colour.
    private func fill(center: CGPoint, start: Angle) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary)
        }
        let tones = TokenroomTokens.usageTones(usedPercent: used)
        let lead = 10.0 / 360
        let tip = min(Double(fraction) + lead, 1 - lead / 2)
        let stops = [Gradient.Stop(color: tones.start, location: 0),
                     Gradient.Stop(color: tones.start, location: lead / 2),
                     Gradient.Stop(color: tones.end, location: tip),
                     Gradient.Stop(color: tones.end, location: tip + (1 - tip) / 2),
                     Gradient.Stop(color: tones.start, location: 1)]
        return .conicGradient(Gradient(stops: stops), center: center, angle: start - .degrees(10))
    }
}
