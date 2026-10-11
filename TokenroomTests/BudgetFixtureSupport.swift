import Foundation
@testable import Tokenroom

/// Existing amount fixtures choose their own currency explicitly through this test-only adapter.
/// App targets expose only applyingBudget(reference:), so production callers cannot pass an
/// unlabelled persisted number and infer its meaning from a newly read balance.
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

/// Older test histories are explicitly dollar fixtures. Production must supply the physical
/// reading's unit, and every Forecast caller must supply the currency it wants to forecast.
extension UsageHistory {
    @discardableResult
    mutating func recordAmount(_ amount: Double, at date: Date) -> Bool {
        recordAmount(amount, unit: "usd", at: date)
    }
}
