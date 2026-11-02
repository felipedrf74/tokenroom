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
            Color(hex: "14202F")
        case .aurora:
            Rectangle().fill(.regularMaterial)
                .overlay(Color.blue.opacity(scheme == .dark ? 0.09 : 0.045))
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
                    .font(.system(size: size, weight: .semibold, design: monospaced ? .monospaced : .default))
                Text("%").font(.system(size: size * 0.55, weight: .medium))
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
    var height: CGFloat = 10

    private var fraction: Double { min(max(used.isFinite ? used : 0, 0), 100) / 100 }
    private var tint: Color { TokenroomTokens.usageColor(usedPercent: used, isStale: isStale) }

    var body: some View {
        if style == .instrument {
            GeometryReader { geometry in
                let gap: CGFloat = 3
                let segmentWidth = max(0, (geometry.size.width - gap * 19) / 20)
                HStack(spacing: gap) {
                    ForEach(0..<20) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TokenroomTokens.track)
                            .overlay(alignment: .leading) {
                                Rectangle().fill(tint)
                                    .frame(width: segmentWidth * CGFloat(min(max(fraction * 20 - Double(index), 0), 1)))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                paceTick(width: geometry.size.width)
            }
            .frame(height: height)
            .accessibilityHidden(true)
        } else if style == .strata {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 5).fill(TokenroomTokens.track)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(tint.opacity(isStale ? 0.35 : 0.3))
                            .frame(width: geometry.size.width * fraction)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                if fraction > 0 {
                    Capsule().fill(tint).frame(width: 3, height: height + 4)
                        .offset(x: max(0, min(geometry.size.width - 3, geometry.size.width * fraction - 1.5)), y: -2)
                }
                paceTick(width: geometry.size.width)
            }
            .frame(height: height)
            .accessibilityHidden(true)
        } else {
            MeterTrack(usedPercent: used, remaining: 100 - used, isStale: isStale, paceMark: paceMark, height: height)
        }
    }

    @ViewBuilder private func paceTick(width: CGFloat) -> some View {
        if let paceMark, paceMark.isFinite, !isStale {
            Capsule().fill(Color.primary.opacity(0.8)).frame(width: 2, height: height + 5)
                .offset(x: max(0, min(width - 2, width * min(max(paceMark, 0), 1) - 1)), y: -2.5)
        }
    }
}
