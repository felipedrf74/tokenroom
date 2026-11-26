import SwiftUI

struct UsageFactsGrid: View {
    var facts: [UsageFact]
    var fitsContent = false
    var columns = 2
    var labelFont: Font = .caption2.weight(.medium)
    var valueFont: Font = .subheadline.weight(.semibold)
    var detailFont: Font = .caption2
    var spacing: CGFloat = 12
    var detailLines = 2
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
        if isStale { return Color.secondary }
        return switch severity {
        case .critical: TokenroomTokens.criticalText
        case .tight: TokenroomTokens.accentText
        default: Color.primary
        }
    }
}
