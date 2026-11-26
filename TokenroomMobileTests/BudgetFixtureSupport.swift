@testable import TokenroomMobile

extension QuotaSnapshot {
    func applyingBudget(_ amount: Double?) -> QuotaSnapshot {
        applyingBudget(reference: amount.flatMap { value in
            budgetUnit.map { BudgetReference(amount: value, unit: $0) }
        })
    }
}
