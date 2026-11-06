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
                                Rectangle().fill(tint.opacity(isStale ? 1 : 0.85))
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
                        Rectangle().fill(tint.opacity(isStale ? 1 : 0.8))
                            .frame(width: geometry.size.width * fraction)
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

    @ViewBuilder private func paceTick(width: CGFloat) -> some View {
        if let paceMark, paceMark.isFinite, !isStale {
            Capsule().fill(TokenroomTokens.paceMark).frame(width: 1.5, height: height + 2)
                .offset(x: max(0, min(width - 1.5, width * min(max(paceMark, 0), 1) - 0.75)), y: -1)
        }
    }
}
