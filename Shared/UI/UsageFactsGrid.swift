import SwiftUI

/// `UsageFacts` as a quiet grid: a small label, the value, and a line under it. Space separates
/// the facts; their surroundings are already a card or a page, so they add no box of their own.
struct UsageFactsGrid: View {
    var facts: [UsageFact]
    /// Each fact as wide as its text, on one line, rather than in equal columns.
    var fitsContent = false
    var columns = 2
    var labelFont: Font = .caption2.weight(.medium)
    var valueFont: Font = .subheadline.weight(.semibold)
    var detailFont: Font = .caption2
    var spacing: CGFloat = 12
    /// Lines a fact's detail may take.
    var detailLines = 2
    /// A last reading rather than a current one: its figures fade like every other stale figure.
    var isStale = false

    var body: some View {
        if fitsContent {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(facts) { fact in
                    if fact.id != facts.first?.id { Spacer(minLength: 0) }
                    cell(fact).fixedSize()
                }
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: max(columns, 1)),
                  alignment: .leading, spacing: spacing) {
            ForEach(facts) { fact in
                cell(fact)
            }
        }
    }

    private func cell(_ fact: UsageFact) -> some View {
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
                    .lineLimit(detailLines)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: fitsContent ? nil : .infinity, maxHeight: fitsContent ? nil : .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func color(_ severity: Pace.Severity?) -> Color {
        if isStale { return Color.secondary.opacity(TokenroomTokens.staleOpacity) }
        return switch severity {
        case .critical: TokenroomTokens.criticalText
        case .tight: TokenroomTokens.accentText
        default: Color.primary
        }
    }
}
