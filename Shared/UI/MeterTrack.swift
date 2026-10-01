import SwiftUI

/// A usage meter: a rounded track, the used fill coloured by how far it has gone, and the even
/// pace as a notch cut through the bar with a slim marker. When use runs ahead of that pace, the
/// stretch past the notch is lightly striped, so "ahead" reads without a caption.
struct MeterTrack: View {
    var usedPercent: Double
    var remaining: Double
    var isStale: Bool
    /// Where an even pace would be now, 0–1 of the window; drawn as a notch and marker.
    var paceMark: Double? = nil
    var height: CGFloat = TokenroomTokens.meterHeight
    /// One colour by level (the menu bar's rule) instead of the gradient across the track.
    var solid = false

    /// How far the pace marker reaches past the track, above and below.
    private var overhang: CGFloat { max(2, height * 0.35) }

    var body: some View {
        let used = MeterLayout.usedFraction(usedPercent)
        let pace = (paceMark.map { CGFloat(min(max($0, 0), 1)) }).flatMap { isStale ? nil : $0 }
        Canvas { context, size in
            let trackRect = CGRect(x: 0, y: overhang, width: size.width, height: height)
            let radius = height / 2
            let track = Path(roundedRect: trackRect, cornerRadius: radius, style: .continuous)
            context.fill(track, with: .color(TokenroomTokens.track))

            let fillWidth = MeterLayout.fillLength(usedPercent: usedPercent, total: size.width)
            if fillWidth > 0 {
                // At least a dot, so a sliver of use still shows as a rounded end.
                let width = max(fillWidth, min(height, size.width))
                let fillRect = CGRect(x: 0, y: overhang, width: width, height: height)
                let fill = Path(roundedRect: fillRect, cornerRadius: min(radius, width / 2), style: .continuous)
                context.fill(fill, with: shading(trackWidth: size.width))
                // A soft highlight along the top keeps the bar from looking flat.
                var shine = context
                shine.clip(to: fill)
                shine.fill(Path(CGRect(x: 0, y: overhang, width: width, height: height * 0.42)),
                           with: .color(.white.opacity(isStale ? 0 : 0.16)))

                if let pace, used > pace + 0.015 {
                    // Past the even pace: stripes over that stretch of the fill.
                    var ahead = context
                    ahead.clip(to: fill)
                    ahead.clip(to: Path(CGRect(x: size.width * pace, y: overhang, width: width - size.width * pace, height: height)))
                    var stripes = Path()
                    let step = max(4, height * 0.9)
                    var x = size.width * pace - height
                    while x < width + height {
                        stripes.move(to: CGPoint(x: x, y: overhang + height))
                        stripes.addLine(to: CGPoint(x: x + height, y: overhang))
                        x += step
                    }
                    ahead.stroke(stripes, with: .color(.white.opacity(0.28)), lineWidth: max(1, height * 0.18))
                }
            }

            if let pace {
                let x = size.width * pace
                // The notch: a gap through track and fill, so the marker never sits on colour.
                var notch = context
                notch.blendMode = .destinationOut
                notch.fill(Path(CGRect(x: x - 2, y: overhang - 1, width: 4, height: height + 2)), with: .color(.black))
                let marker = CGRect(x: x - 1, y: 0.5, width: 2, height: size.height - 1)
                context.fill(Path(roundedRect: marker, cornerRadius: 1), with: .color(.primary.opacity(0.8)))
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

    private func shading(trackWidth: CGFloat) -> GraphicsContext.Shading {
        if isStale {
            return .color(Color.secondary.opacity(0.72))
        }
        if solid {
            return .color(TokenroomTokens.usageColor(usedPercent: usedPercent, isStale: false))
        }
        // The gradient spans the whole track, so the colour where the fill ends says how far it went.
        return .linearGradient(TokenroomTokens.usageGradient, startPoint: .zero, endPoint: CGPoint(x: trackWidth, y: 0))
    }
}
