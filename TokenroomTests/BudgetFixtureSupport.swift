import Foundation
@testable import Tokenroom

extension QuotaSnapshot {
    func applyingBudget(_ amount: Double?) -> QuotaSnapshot {
        applyingBudget(reference: amount.flatMap { value in
            budgetUnit.map { BudgetReference(amount: value, unit: $0) }
        })
    }
}

extension RelayProvider {
    func applyingBudget(_ amount: Double?) -> RelayProvider {
        let unit = windows.first { $0.amount != nil }?.amount?.unit
        return applyingBudget(reference: amount.flatMap { value in
            unit.map { BudgetReference(amount: value, unit: $0) }
        })
    }
}

extension UsageHistory {
    @discardableResult
    mutating func recordAmount(_ amount: Double, at date: Date) -> Bool {
        recordAmount(amount, unit: "usd", at: date)
    }
}
