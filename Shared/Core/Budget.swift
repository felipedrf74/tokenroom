import Foundation

/// A reference is an amount in one currency, never an exchange-rate conversion. Keeping both
/// fields together prevents a replacement key or reordered multi-currency response from changing
/// the meaning of the saved number.
struct BudgetReference: Equatable, Sendable {
    var amount: Double
    var unit: String

    var isValid: Bool { amount.isFinite && amount > 0 && ["usd", "cny"].contains(unit) }
    var propertyList: [String: Any] { ["amount": amount, "unit": unit] }
}

enum BudgetReferencePreferences {
    static let amountsKey = "budgets"
    static let referencesKey = "budgetReferences"

    /// Older builds saved only numbers. Only providers with a single documented currency can
    /// migrate automatically. Moonshot and DeepSeek retain their number without a guessed unit;
    /// the user must enter it again in the labelled field to activate it.
    static func legacyUnit(for provider: Provider) -> String? {
        switch provider {
        case .openrouter, .vercelGateway, .openaiOrg, .anthropicOrg, .xaiOrg: "usd"
        default: nil
        }
    }

    static func amount(in defaults: UserDefaults, for provider: Provider) -> Double? {
        guard let value = (defaults.dictionary(forKey: amountsKey) as? [String: Double])?[provider.rawValue],
              value.isFinite, value > 0 else { return nil }
        return value
    }

    static func reference(in defaults: UserDefaults, for provider: Provider) -> BudgetReference? {
        guard let amount = amount(in: defaults, for: provider) else { return nil }
        if let saved = defaults.dictionary(forKey: referencesKey)?[provider.rawValue] {
            guard let fields = saved as? [String: Any], let savedAmount = fields["amount"] as? Double,
                  let unit = fields["unit"] as? String, savedAmount == amount else { return nil }
            let reference = BudgetReference(amount: amount, unit: unit)
            return reference.isValid ? reference : nil
        }
        return legacyUnit(for: provider).map { BudgetReference(amount: amount, unit: $0) }
    }

    /// The proposed Moonshot account defines the editor label before a key is saved or fetched.
    /// Other multi-currency providers use their reading's unit. No credential read is needed.
    static func editorUnit(for provider: Provider, region: String?, readingUnit: String?) -> String {
        if provider == .moonshot, let region { return region.lowercased() == "china" ? "cny" : "usd" }
        return ["usd", "cny"].contains(readingUnit ?? "") ? readingUnit! : "usd"
    }
}

extension QuotaSnapshot {
    /// A budget the user sets turns amount-only windows into meters: spend against the budget,
    /// or a balance against the amount it started from. Provider-owned meters are left alone;
    /// old app-created meters are removed before the saved reference's currency is checked.
    /// Rows in other currencies stay plain amounts. An organization's monthly
    /// budget only measures spend: an xAI team's prepaid credits stay an amount.
    func applyingBudget(reference: BudgetReference?) -> QuotaSnapshot {
        let measuresBalances = provider.category != .orgSpend
        var copy = self
        copy.windows = windows.map(\.removingBudget)
        copy.windows = copy.windows.map { window in
            guard let reference, reference.isValid, !window.isMetered,
                  let amount = window.amount, amount.unit == reference.unit,
                  let meter = amount.meter(against: reference.amount, measuresBalances: measuresBalances)
            else { return window }
            var metered = window
            metered.usedPercent = meter.used
            metered.amount = meter.amount
            metered.metered = true
            return metered
        }
        if let first = copy.windows.first, copy.windows.first != windows.first {
            copy.usedPercent = first.usedPercent
            copy.resetsAt = first.resetsAt
        }
        return copy
    }

    /// The unit a budget is set in: the first amount's, e.g. `usd` or `cny`.
    var budgetUnit: String? {
        windows.first { $0.amount != nil }?.amount?.unit
    }

    /// ISO code for the budget field: `CNY` for a yuan balance, else `USD`.
    var budgetCurrencyCode: String {
        budgetUnit == "cny" ? "CNY" : "USD"
    }
}

extension ReadingCache {
    /// Widget fast paths and retained local readings must obey the current phone reference too.
    /// References on other collectors belong to those collectors and are never replaced here.
    func applyingLocalBudgetReferences(in defaults: UserDefaults) -> ReadingCache {
        guard !isSample else { return self }
        var copy = self
        copy.items = items.map { item in
            guard item.resolvedOrigin == .thisPhone, let provider = Provider(rawValue: item.id) else { return item }
            var updated = item
            updated.provider = item.provider.applyingBudget(reference: BudgetReferencePreferences.reference(in: defaults, for: provider))
            return updated
        }
        if var local = localSource {
            local.envelope.providers = local.envelope.providers.map { row in
                guard let provider = Provider(rawValue: row.id) else { return row }
                return row.applyingBudget(reference: BudgetReferencePreferences.reference(in: defaults, for: provider))
            }
            copy.localSource = local
        }
        return copy
    }
}

private extension QuotaWindow {
    var removingBudget: QuotaWindow {
        guard var amount, amount.isBudget == true else { return self }
        var plain = self
        amount.limit = nil
        amount.isBudget = nil
        if amount.remaining != nil { amount.used = nil }
        plain.amount = amount
        plain.usedPercent = 0
        plain.metered = false
        return plain
    }
}

extension QuotaAmount {
    /// This amount measured against a budget: spend against it, or a balance against the amount
    /// it started from. Nil when the budget doesn't measure it (a balance, for an organization's
    /// monthly budget).
    func meter(against budget: Double, measuresBalances: Bool) -> (used: Double, amount: QuotaAmount)? {
        var amount = self
        let used: Double
        if let spent = self.used, remaining == nil {
            used = JSONFlex.clampPercent(spent / budget * 100)
        } else if measuresBalances, let remaining = remainingOrComputed {
            used = JSONFlex.clampPercent((1 - remaining / budget) * 100)
            // What the meter shows: spent from the reference, not a lifetime total.
            amount.used = max(budget - remaining, 0)
        } else {
            return nil
        }
        amount.limit = budget
        amount.isBudget = true
        return (used, amount)
    }
}

extension RelayProvider {
    /// A saved reading with the budget or reference set now rather than the one it was saved
    /// with: a stand-in for a provider this launch hasn't read (its calls are spaced, or it's
    /// rate limited) shows a new budget at once. Windows metered against a budget are measured
    /// again; the provider's own meters are left alone.
    func applyingBudget(reference: BudgetReference?) -> RelayProvider {
        var copy = self
        copy.windows = windows.map { window in
            guard var amount = window.amount, amount.isBudget == true else { return window }
            var plain = window
            amount.limit = nil
            amount.isBudget = nil
            if amount.remaining != nil {
                // Worked out from the old reference.
                amount.used = nil
            }
            plain.amount = amount
            plain.used = 0
            plain.metered = false
            return plain
        }
        guard let reference, reference.isValid else { return copy }
        let measuresBalances = category != ProviderDescriptor.Category.orgSpend.rawValue
        copy.windows = copy.windows.map { window in
            guard !window.isMetered, let amount = window.amount, amount.unit == reference.unit,
                  let meter = amount.meter(against: reference.amount, measuresBalances: measuresBalances)
            else { return window }
            var metered = window
            metered.used = meter.used
            metered.amount = meter.amount
            metered.metered = true
            return metered
        }
        return copy
    }

}
