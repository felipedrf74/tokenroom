import SwiftUI

struct UsageRing: View {
    var used: Double
    var isStale: Bool
    var label: String
    var lineWidth: CGFloat? = nil
    var paceMark: Double? = nil
    var isAwaitingReading = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let width = lineWidth ?? max(3, side * 0.11)
            let pace = MeterLayout.shownPace(paceMark, isStale: isStale, isAwaitingReading: isAwaitingReading)
            ZStack {
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
        ReadingText.meterAccessibility(used: used, paceMark: paceMark, isStale: isStale, isAwaitingReading: isAwaitingReading)
    }

    private var fraction: CGFloat {
        MeterLayout.usedFraction(MeterLayout.shownUsed(used, isAwaitingReading: isAwaitingReading))
    }

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
