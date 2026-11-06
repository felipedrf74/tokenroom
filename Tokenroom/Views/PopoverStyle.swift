import SwiftUI

/// The same readings and actions, with a presentation chosen by the person using this Mac.
enum PopoverStyle: String, CaseIterable, Identifiable {
    case orbit, instrument, strata, aurora, classic

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var width: CGFloat { self == .classic ? TokenroomTokens.popoverWidth : 420 }

    var summary: String {
        switch self {
        case .orbit: "Circular meters and a spacious provider detail."
        case .instrument: "Dark instruments with precise, segmented meters."
        case .strata: "Wide usage bands and prominent percentages."
        case .aurora: "A softly tinted surface with clear, flowing meters."
        case .classic: "The original Tokenroom cards and expandable details."
        }
    }
}

struct PopoverSurface: View {
    var style: PopoverStyle
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch style {
        case .classic:
            Color.clear
        case .instrument:
            Color(hex: "1A2430")
        case .aurora:
            Rectangle().fill(.regularMaterial)
                .overlay(Color.blue.opacity(scheme == .dark ? 0.06 : 0.025))
        case .orbit, .strata:
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

/// Separate number and sign views keep the selected style's type size across detail navigation
/// and style changes, including when the same percentage is shown at several sizes.
struct PopoverValue: View {
    var text: String
    var size: CGFloat
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if text.count > 1, text.hasSuffix("%") {
                Text(String(text.dropLast()))
                    .font(.system(size: size, weight: .medium, design: monospaced ? .monospaced : .default))
                Text("%").font(.system(size: size * 0.55, weight: .regular))
            } else {
                Text(text).font(.system(size: size, weight: .semibold))
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Native meters, not images: partial segments and the fill edge reflect the actual quota.
struct PopoverMeter: View {
    var style: PopoverStyle
    var used: Double
    var isStale: Bool
    var paceMark: Double? = nil
    var height: CGFloat = 8

    @Environment(\.colorScheme) private var scheme

    private var fraction: Double { min(max(used.isFinite ? used : 0, 0), 100) / 100 }
    private var tint: Color { TokenroomTokens.usageColor(usedPercent: used, isStale: isStale) }

    var body: some View {
        if style == .instrument {
            GeometryReader { geometry in
                let gap: CGFloat = 2
                let segmentWidth = max(0, (geometry.size.width - gap * 19) / 20)
                HStack(spacing: gap) {
                    ForEach(0..<20) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(TokenroomTokens.track)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(tint)
                                    .overlay {
                                        // Past the even pace, a step lighter, as other meters.
                                        if let start = aheadStart, (Double(index) + 0.5) / 20 > start {
                                            Color.white.opacity(0.28)
                                        }
                                    }
                                    .frame(width: segmentWidth * CGFloat(min(max(fraction * 20 - Double(index), 0), 1)))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
                paceTick(width: geometry.size.width)
            }
            .frame(height: height)
            .accessibilityHidden(true)
        } else if style == .strata {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: height / 2).fill(TokenroomTokens.track)
                    .overlay(alignment: .leading) {
                        // Pale on a light panel; on a dark one, the level's own colour.
                        Rectangle().fill(tint.opacity(isStale || scheme == .dark ? 1 : 0.85))
                            .frame(width: geometry.size.width * fraction)
                            .overlay(alignment: .leading) {
                                // Past the even pace, the same colour a step lighter, as other meters.
                                if let start = aheadStart {
                                    Color.white.opacity(0.28).padding(.leading, geometry.size.width * start)
                                }
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                paceTick(width: geometry.size.width)
            }
            .frame(height: height)
            .accessibilityHidden(true)
        } else {
            MeterTrack(usedPercent: used, remaining: 100 - used, isStale: isStale, paceMark: paceMark, height: height)
        }
    }

    /// Where a fill runs ahead of the even pace, as a fraction of the meter.
    private var aheadStart: Double? {
        guard let paceMark, paceMark.isFinite, !isStale, fraction > paceMark + 0.015 else { return nil }
        return max(paceMark, 0)
    }

    @ViewBuilder private func paceTick(width: CGFloat) -> some View {
        if let paceMark, paceMark.isFinite, !isStale {
            let x = width * min(max(paceMark, 0), 1)
            if style == .instrument {
                // A gap in the segments, in the panel's own colour, with the mark in it.
                Rectangle().fill(Color(hex: "1A2430")).frame(width: 4, height: height + 2)
                    .offset(x: max(0, min(width - 4, x - 2)), y: -1)
                Capsule().fill(Color.white.opacity(0.7)).frame(width: 1.5, height: height + 2)
                    .offset(x: max(0, min(width - 1.5, x - 0.75)), y: -1)
            } else {
                // A notch through the fill, in the panel's colour, as `MeterTrack` cuts one.
                Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: 3, height: height)
                    .offset(x: max(0, min(width - 3, x - 1.5)))
                Capsule().fill(TokenroomTokens.paceMark).frame(width: 1.5, height: height + 2)
                    .offset(x: max(0, min(width - 1.5, x - 0.75)), y: -1)
            }
        }
    }
}
