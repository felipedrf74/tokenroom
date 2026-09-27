import Foundation

enum BudgetInput {
    enum Result: Equatable {
        case clear
        case amount(Double)
        case invalid
    }

    static let error = "Enter a positive amount, or leave this empty to clear it."

    /// Full-string parsing: NumberFormatter alone can accept a valid prefix of invalid input.
    static func parse(_ text: String, locale: Locale = .current) -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .clear }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        let decimal = formatter.decimalSeparator ?? "."
        let grouping = formatter.groupingSeparator ?? ","
        let parts = text.components(separatedBy: decimal)
        guard parts.count <= 2 else { return .invalid }
        var integer = parts[0]
        if integer.contains(grouping) {
            let groups = integer.components(separatedBy: grouping)
            let primary = max(1, formatter.groupingSize)
            let secondary = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : primary
            guard groups.last?.count == primary,
                  groups.dropFirst().dropLast().allSatisfy({ $0.count == secondary }),
                  (1...secondary).contains(groups[0].count) else { return .invalid }
            integer = groups.joined()
        }
        let normalized = integer + (parts.count == 2 ? "." + parts[1] : "")
        guard normalized.range(of: #"^(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let amount = Double(normalized), amount.isFinite, amount > 0 else { return .invalid }
        return .amount(amount)
    }
}
