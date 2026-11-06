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

    private struct Run: Shape {
        var from: CGFloat
        var to: CGFloat

        func path(in rect: CGRect) -> Path {
            guard to > from else { return Path() }
            return Path(roundedRect: CGRect(x: from, y: 0, width: to - from, height: rect.height), cornerRadius: rect.height / 2, style: .continuous)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let end = width * CGFloat(MeterLayout.usedFraction(used))
            let mark = pace.map { width * CGFloat(min(max($0, 0), 1)) }
            let gapStart = mark.map { $0 - 1.5 } ?? width
            let gapEnd = mark.map { $0 + 1.5 } ?? width
            ZStack(alignment: .leading) {
                Run(from: 0, to: gapStart).fill(.primary.opacity(0.18))
                Run(from: gapEnd, to: width).fill(.primary.opacity(0.18))
                Run(from: 0, to: min(max(end, height), gapStart)).fill(tint).widgetAccentable()
                Run(from: gapEnd, to: end).fill(tint.opacity(0.6)).widgetAccentable()
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
