import SwiftUI

/// `UsageFacts` as a quiet grid: a small label, the value, and a line under it. Space separates
/// the facts; their surroundings are already a card or a page, so they add no box of their own.
struct UsageFactsGrid: View {
    var facts: [UsageFact]
    var columns = 2
    var labelFont: Font = .caption2.weight(.medium)
    var valueFont: Font = .subheadline.weight(.semibold)
    var detailFont: Font = .caption2
    var spacing: CGFloat = 12

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: max(columns, 1)),
                  alignment: .leading, spacing: spacing) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label)
                        .font(labelFont)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
