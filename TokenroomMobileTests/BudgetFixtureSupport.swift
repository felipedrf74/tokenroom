@testable import TokenroomMobile

/// A test-only adapter for older in-memory fixtures; app targets require a currency-bound
/// reference and never infer one from a persisted number.
extension QuotaSnapshot {
    func applyingBudget(_ amount: Double?) -> QuotaSnapshot {
        applyingBudget(reference: amount.flatMap { value in
            budgetUnit.map { BudgetReference(amount: value, unit: $0) }
        })
    }
}
