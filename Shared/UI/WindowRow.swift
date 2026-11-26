import SwiftUI

struct WindowRow: View {
    var title: String
    var headline: String
    var usedPercent: Double?
    var isStale: Bool
    var paceMark: Double? = nil
    var caption: String? = nil
    var titleFont: Font = .caption
    var captionFont: Font = .caption2
    var isAwaitingReading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(titleFont)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HeadlineValue(text: headline, font: titleFont.weight(.semibold), signFont: captionFont)
                    .foregroundStyle(ink)
            }
            if let usedPercent {
                MeterTrack(usedPercent: usedPercent, remaining: 100 - usedPercent, isStale: isStale, paceMark: paceMark, height: 5, isAwaitingReading: isAwaitingReading)
            }
            if let caption {
                Text(caption)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var ink: Color {
        guard let usedPercent else { return .primary }
        return TokenroomTokens.ink(remaining: 100 - usedPercent, isStale: isStale)
    }
}
