import SwiftUI

struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool
    var paceMark: Double? = nil
    var height: CGFloat = TokenroomTokens.meterHeight
    var isAwaitingReading = false

    private var overhang: CGFloat { max(1, height * 0.2) }

    var body: some View {
        let usedPercent = MeterLayout.shownUsed(self.usedPercent, isAwaitingReading: isAwaitingReading)
        let used = MeterLayout.usedFraction(usedPercent)
        let pace = MeterLayout.shownPace(paceMark, isStale: isStale, isAwaitingReading: isAwaitingReading).map { CGFloat($0) }
        Canvas { context, size in
            let trackRect = CGRect(x: 0, y: overhang, width: size.width, height: height)
            let radius = height / 2
            let track = Path(roundedRect: trackRect, cornerRadius: radius, style: .continuous)
            context.fill(track, with: .color(TokenroomTokens.track))

            let width = MeterLayout.drawnFillEnd(usedPercent: usedPercent, total: size.width, height: height)
            if width > 0 {
                var bar = context
                bar.clip(to: track)
                let fillRect = CGRect(x: -radius, y: overhang, width: width + radius, height: height)
                let fill = Path(roundedRect: fillRect, cornerRadius: min(radius, (width + radius) / 2), style: .continuous)
                bar.fill(fill, with: shading(usedPercent: usedPercent, fillEnd: width))

                if let pace, used > pace + 0.015 {
                    var ahead = bar
                    ahead.clip(to: fill)
                    ahead.fill(Path(CGRect(x: size.width * pace, y: overhang, width: width - size.width * pace, height: height)),
                               with: .color(.white.opacity(0.28)))
                }
            }

            if let pace {
                let x = size.width * pace
                var notch = context
                notch.blendMode = .destinationOut
                notch.fill(Path(CGRect(x: x - 1.5, y: overhang - 1, width: 3, height: height + 2)), with: .color(.black))
                let marker = CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)
                context.fill(Path(roundedRect: marker, cornerRadius: 0.75), with: .color(TokenroomTokens.paceMark))
            }
        }
        .frame(height: height + overhang * 2)
        .padding(.vertical, -overhang)
        .opacity(isStale ? 0.85 : 1)
        .accessibilityElement()
        .accessibilityHidden(paceMark == nil || isStale || isAwaitingReading)
        .accessibilityLabel("Even pace")
        .accessibilityValue(paceMark.map { "\(TokenroomFormat.percentText(min(max($0, 0), 1) * 100)) percent of the window has passed" } ?? "")
    }

    private func shading(usedPercent: Double, fillEnd: CGFloat) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary.opacity(0.72))
        }
        let tones = TokenroomTokens.usageTones(usedPercent: usedPercent)
        return .linearGradient(Gradient(colors: [tones.start, tones.end]),
                               startPoint: CGPoint(x: 0, y: 0),
                               endPoint: CGPoint(x: max(fillEnd, 1), y: 0))
    }
}

struct FlatMeter: View {
    var used: Double
    var pace: Double? = nil
    var tint: Color
    var height: CGFloat = 4
    var isAwaitingReading = false

    static func runs(used: Double, pace: Double?, width: CGFloat) -> (fill: ClosedRange<CGFloat>?, ahead: ClosedRange<CGFloat>?) {
        let end = MeterLayout.fillLength(usedPercent: used, total: width)
        guard end > 0 else { return (nil, nil) }
        guard let pace else { return (0...end, nil) }
        let mark = width * CGFloat(min(max(pace, 0), 1))
        return (mark > 0 ? 0...min(end, mark) : nil, end > mark ? mark...end : nil)
    }

    private struct Run: Shape {
        var span: ClosedRange<CGFloat>?

        func path(in rect: CGRect) -> Path {
            guard let span, span.upperBound > span.lowerBound else { return Path() }
            return Path(CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: rect.height))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let pace = isAwaitingReading ? nil : self.pace
            let runs = Self.runs(used: MeterLayout.shownUsed(used, isAwaitingReading: isAwaitingReading), pace: pace, width: width)
            ZStack(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.18))
                    Run(span: runs.fill).fill(tint).widgetAccentable()
                    Run(span: runs.ahead).fill(tint.mix(with: .white, by: 0.3)).widgetAccentable()
                }
                .clipShape(Capsule())
                if let pace {
                    Rectangle().fill(.primary.opacity(0.5))
                        .frame(width: 1.5, height: height + 2)
                        .offset(x: width * CGFloat(min(max(pace, 0), 1)) - 0.75, y: -1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
