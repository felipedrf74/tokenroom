import SwiftUI

/// `UsageFacts` as a grid of quiet tiles: a small label, the value, and a line under it.
struct UsageFactsGrid: View {
    var facts: [UsageFact]
    var columns = 2
    var labelFont: Font = .caption2.weight(.medium)
    var valueFont: Font = .subheadline.weight(.semibold)
    var detailFont: Font = .caption2
    var spacing: CGFloat = 8
    var cornerRadius: CGFloat = 10

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: max(columns, 1)),
                  alignment: .leading, spacing: spacing) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label.uppercased())
                        .font(labelFont)
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Text(fact.value)
                        .font(valueFont)
                        .monospacedDigit()
                        .foregroundStyle(color(fact.severity))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if let detail = fact.detail {
                        Text(detail)
                            .font(detailFont)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(_ severity: Pace.Severity?) -> Color {
        switch severity {
        case .critical: TokenroomTokens.criticalText
        case .tight: TokenroomTokens.accentText
        default: .primary
        }
    }
}
