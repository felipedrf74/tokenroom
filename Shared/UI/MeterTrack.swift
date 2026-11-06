import SwiftUI

/// A usage meter: a rounded track, the used fill in its level's colour (a slightly lighter tint
/// where it starts, the full colour at its tip), and the even pace as a notch with a slim marker.
/// When use runs ahead of that pace, the stretch past the notch is a little lighter, so "ahead"
/// reads without a caption and without pattern.
struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool
    /// Where an even pace would be now, 0–1 of the window; drawn as a notch and marker.
    var paceMark: Double? = nil
    var height: CGFloat = TokenroomTokens.meterHeight

    /// How far the pace marker reaches past the track, above and below.
    private var overhang: CGFloat { max(1, height * 0.2) }

    var body: some View {
        let used = MeterLayout.usedFraction(usedPercent)
        let pace = (paceMark.map { CGFloat(min(max($0, 0), 1)) }).flatMap { isStale ? nil : $0 }
        Canvas { context, size in
            let trackRect = CGRect(x: 0, y: overhang, width: size.width, height: height)
            let radius = height / 2
            let track = Path(roundedRect: trackRect, cornerRadius: radius, style: .continuous)
            context.fill(track, with: .color(TokenroomTokens.track))

            let width = MeterLayout.drawnFillEnd(usedPercent: usedPercent, total: size.width, height: height)
            if width > 0 {
                // Ends at the fraction. It starts under the track's left cap, which clips it, so a
                // sliver shows as a rounded end without being drawn wider than it is.
                var bar = context
                bar.clip(to: track)
                let fillRect = CGRect(x: -radius, y: overhang, width: width + radius, height: height)
                let fill = Path(roundedRect: fillRect, cornerRadius: min(radius, (width + radius) / 2), style: .continuous)
                bar.fill(fill, with: shading(fillEnd: width))

                if let pace, used > pace + 0.015 {
                    // Past the even pace: the same colour, a step lighter.
                    var ahead = bar
                    ahead.clip(to: fill)
                    ahead.fill(Path(CGRect(x: size.width * pace, y: overhang, width: width - size.width * pace, height: height)),
                               with: .color(.white.opacity(0.28)))
                }
            }

            if let pace {
                let x = size.width * pace
                // The notch: a gap through track and fill, so the marker never sits on colour.
                var notch = context
                notch.blendMode = .destinationOut
                notch.fill(Path(CGRect(x: x - 1.5, y: overhang - 1, width: 3, height: height + 2)), with: .color(.black))
                let marker = CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)
                context.fill(Path(roundedRect: marker, cornerRadius: 0.75), with: .color(TokenroomTokens.paceMark))
            }
        }
        .frame(height: height + overhang * 2)
        // Lays out at the track's height; the marker reaches past it.
        .padding(.vertical, -overhang)
        .opacity(isStale ? 0.85 : 1)
        // The fill repeats the percent next to it; only the pace mark adds something to hear.
        .accessibilityElement()
        .accessibilityHidden(paceMark == nil || isStale)
        .accessibilityLabel("Even pace")
        .accessibilityValue(paceMark.map { "\(TokenroomFormat.percentText(min(max($0, 0), 1) * 100)) percent of the window has passed" } ?? "")
    }

    private func shading(fillEnd: CGFloat) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary.opacity(0.72))
        }
        // One colour by level, the menu bar's rule, from a lighter tint up to the tip.
        let tones = TokenroomTokens.usageTones(usedPercent: usedPercent)
        return .linearGradient(Gradient(colors: [tones.start, tones.end]),
                               startPoint: CGPoint(x: 0, y: 0),
                               endPoint: CGPoint(x: max(fillEnd, 1), y: 0))
    }
}

/// A meter of plain shapes, for surfaces the system tints or that can't blend: a watch face, the
/// Lock Screen. The same reading as `MeterTrack`: a track, the fill, the even pace as a gap with a
/// slim mark, and the stretch past it a step lighter.
struct FlatMeter: View {
    var used: Double
    var pace: Double? = nil
    var tint: Color
    var height: CGFloat = 4

    /// Where the fill runs, in points of `width`: up to the pace's gap, and on from it when use has
    /// passed the pace. Exactly the reading, so a meter at 0% draws nothing, as `MeterLayout` says.
    static func runs(used: Double, pace: Double?, width: CGFloat) -> (fill: ClosedRange<CGFloat>?, ahead: ClosedRange<CGFloat>?) {
        let end = MeterLayout.fillLength(usedPercent: used, total: width)
        guard end > 0 else { return (nil, nil) }
        guard let pace else { return (0...end, nil) }
        let mark = width * CGFloat(min(max(pace, 0), 1))
        let fill = min(end, mark - gap / 2)
        let ahead = mark + gap / 2
        return (fill > 0 ? 0...fill : nil, end > ahead ? ahead...end : nil)
    }

    private static let gap: CGFloat = 3

    private struct Run: Shape {
        var span: ClosedRange<CGFloat>?

        func path(in rect: CGRect) -> Path {
            guard let span, span.upperBound > span.lowerBound else { return Path() }
            let length = span.upperBound - span.lowerBound
            return Path(roundedRect: CGRect(x: span.lowerBound, y: 0, width: length, height: rect.height),
                        cornerRadius: min(rect.height, length) / 2, style: .continuous)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let mark = pace.map { width * CGFloat(min(max($0, 0), 1)) }
            let runs = Self.runs(used: used, pace: pace, width: width)
            ZStack(alignment: .leading) {
                if let mark {
                    Run(span: 0...max(mark - Self.gap / 2, 0)).fill(.primary.opacity(0.18))
                    Run(span: min(mark + Self.gap / 2, width)...width).fill(.primary.opacity(0.18))
                } else {
                    Run(span: 0...width).fill(.primary.opacity(0.18))
                }
                Run(span: runs.fill).fill(tint).widgetAccentable()
                Run(span: runs.ahead).fill(tint.mix(with: .white, by: 0.3)).widgetAccentable()
                if let mark {
                    Rectangle().fill(.primary.opacity(0.5))
                        .frame(width: 1.5, height: height + 2)
                        .offset(x: mark - 0.75, y: -1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
