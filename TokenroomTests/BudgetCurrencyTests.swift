import XCTest
@testable import Tokenroom

final class BudgetCurrencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)

    @MainActor
    func testLegacyMoonshotReferenceKeepsItsAmountWithoutGuessingTheNewRegion() async throws {
        try await assertLegacyReference(provider: .moonshot, unit: "cny", shouldMeter: false)
    }

    @MainActor
    func testLegacyDeepSeekReferenceDoesNotGuessAReorderedBalanceCurrency() async throws {
        try await assertLegacyReference(provider: .deepseek, unit: "cny", shouldMeter: false)
    }

    @MainActor
    func testLegacyDollarOnlyProviderReferenceCanMigrateWithoutChangingMeaning() async throws {
        try await assertLegacyReference(provider: .vercelGateway, unit: "usd", shouldMeter: true)
    }

    func testDollarReferenceNeverMetersChinaBalanceOrRaisesALowBalanceAlert() throws {
        let global = balance(provider: .moonshot, unit: "usd", remaining: 25)
            .applyingBudget(reference: BudgetReference(amount: 100, unit: "usd"))
        let china = balance(provider: .moonshot, unit: "cny", remaining: 5)
            .applyingBudget(reference: BudgetReference(amount: 100, unit: "usd"))
        XCTAssertFalse(china.windows[0].isMetered)
        XCTAssertEqual(china.windows[0].amount?.remaining, 5)
        XCTAssertNil(china.windows[0].amount?.used)
        XCTAssertNil(china.windows[0].amount?.limit)
        XCTAssertTrue(AlertRules.alerts(previous: RelayProvider(provider: .moonshot, status: .live(global), checkedAt: now),
            current: RelayProvider(provider: .moonshot, status: .live(china), checkedAt: now),
            preferences: AlertPreferences(), now: now).isEmpty)
    }

    @MainActor
    func testExplicitReferenceRoundTripsAndRequiresExplicitCurrencyReplacement() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.setBudget(100, for: .moonshot, unit: "usd")
            let relaunched = AppSettings(defaults: defaults)
            XCTAssertEqual(relaunched.budgetReference(for: .moonshot), BudgetReference(amount: 100, unit: "usd"))
            let china = balance(provider: .moonshot, unit: "cny", remaining: 25)
            XCTAssertFalse(china.applyingBudget(reference: relaunched.budgetReference(for: .moonshot)).windows[0].isMetered)
            relaunched.setBudget(100, for: .moonshot, unit: "cny")
            let replacement = AppSettings(defaults: defaults).budgetReference(for: .moonshot)
            XCTAssertEqual(replacement, BudgetReference(amount: 100, unit: "cny"))
            XCTAssertEqual(china.applyingBudget(reference: replacement).usedPercent, 75)
            XCTAssertFalse(balance(provider: .moonshot, unit: "usd", remaining: 25)
                .applyingBudget(reference: replacement).windows[0].isMetered)
        }
    }

    func testSelectedMoonshotRegionDefinesTheEditorCurrencyBeforeItsFirstReading() {
        XCTAssertEqual(BudgetReferencePreferences.editorUnit(for: .moonshot, region: "China", readingUnit: nil), "cny")
        XCTAssertEqual(BudgetReferencePreferences.editorUnit(for: .moonshot, region: "China", readingUnit: "usd"), "cny")
        XCTAssertEqual(BudgetReferencePreferences.editorUnit(for: .moonshot, region: "Global", readingUnit: "cny"), "usd")
        XCTAssertEqual(BudgetReferencePreferences.editorUnit(for: .moonshot, region: nil, readingUnit: "cny"), "cny", "No proposed account: retain the known reading's label")
        XCTAssertEqual(BudgetReferencePreferences.editorUnit(for: .deepseek, region: nil, readingUnit: "cny"), "cny")
    }

    func testCachedAppCreatedMetersAreRemovedWhenTheirReferenceIsUnknownOrMismatched() {
        let raw = balance(provider: .moonshot, unit: "cny", remaining: 25)
        let cached = raw.applyingBudget(reference: BudgetReference(amount: 100, unit: "cny"))
        for reference in [nil, BudgetReference(amount: 100, unit: "usd")] {
            XCTAssertEqual(cached.applyingBudget(reference: reference), raw)
            let relayed = RelayProvider(provider: .moonshot, status: .live(cached), checkedAt: now)
            let plain = RelayProvider(provider: .moonshot, status: .live(raw), checkedAt: now)
            XCTAssertEqual(relayed.applyingBudget(reference: reference), plain)
        }
    }

    func testExplicitUnitSurvivesDeepSeekResponseCurrencyReordering() {
        var reading = balance(provider: .deepseek, unit: "cny", remaining: 250)
        reading.windows.append(QuotaWindow(id: "dollars", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: 25, unit: "usd"), metered: false))
        let metered = reading.applyingBudget(reference: BudgetReference(amount: 100, unit: "usd"))
        XCTAssertFalse(metered.windows[0].isMetered)
        XCTAssertEqual(metered.windows[0], reading.windows[0])
        XCTAssertEqual(metered.windows[1].usedPercent, 75)
        XCTAssertEqual(metered.usedPercent, 0, "The primary headline remains the primary window")
    }

    func testDowngradedOrPartialPreferenceWritesCannotReuseAnOldUnitsRecord() throws {
        try withDefaults { defaults in
            defaults.set(["moonshot": 100.0, "vercelGateway": 100.0], forKey: BudgetReferencePreferences.amountsKey)
            defaults.set(["moonshot": ["amount": 50.0, "unit": "usd"],
                          "vercelGateway": ["amount": 50.0, "unit": "usd"]], forKey: BudgetReferencePreferences.referencesKey)
            XCTAssertNil(BudgetReferencePreferences.reference(in: defaults, for: .moonshot))
            XCTAssertNil(BudgetReferencePreferences.reference(in: defaults, for: .vercelGateway), "Corrupt or stale typed provenance is not an invitation to migrate")
            XCTAssertEqual(BudgetReferencePreferences.amount(in: defaults, for: .moonshot), 100)
        }
    }

    @MainActor
    func testUnsupportedAndFutureReferenceRecordsArePreservedUntilExplicitReplacement() throws {
        try withDefaults { defaults in
            defaults.set(["moonshot": 100.0, "future-provider": 200.0], forKey: AppSettings.Keys.budgets)
            defaults.set(["moonshot": ["amount": 100.0, "unit": "eur"],
                          "future-provider": ["amount": 200.0, "unit": "eur"]], forKey: AppSettings.Keys.budgetReferences)
            let settings = AppSettings(defaults: defaults)
            XCTAssertNil(settings.budgetReference(for: .moonshot))
            XCTAssertEqual((defaults.dictionary(forKey: AppSettings.Keys.budgetReferences)?["moonshot"] as? [String: Any])?["unit"] as? String, "eur")
            settings.setBudget(100, for: .moonshot, unit: "cny")
            XCTAssertEqual(settings.budgetReference(for: .moonshot)?.unit, "cny")
            XCTAssertEqual((defaults.dictionary(forKey: AppSettings.Keys.budgetReferences)?["future-provider"] as? [String: Any])?["unit"] as? String, "eur")
        }
    }

    func testWidgetCacheFastPathStripsOnlyThisPhonesUnknownReference() throws {
        try withDefaults { defaults in
            defaults.set(["moonshot": 100.0], forKey: BudgetReferencePreferences.amountsKey)
            let row = RelayProvider(provider: .moonshot, status: .live(balance(provider: .moonshot, unit: "cny", remaining: 25)
                .applyingBudget(reference: BudgetReference(amount: 100, unit: "cny"))), checkedAt: now)
            let local = RelayMerge.Source(id: "local-fixture", label: "This iPhone",
                envelope: RelayEnvelope(producer: "iphone", appVersion: "fixture", checkedAt: now, providers: [row]), kind: .thisPhone)
            var cache = ReadingCache(savedAt: now, isSample: false, items: [
                .init(provider: row, source: "This iPhone", origin: .thisPhone),
                .init(provider: row, source: "Mac", origin: .mac)])
            cache.localSource = ReadingCache.SourceSnapshot(local)
            let guarded = cache.applyingLocalBudgetReferences(in: defaults)
            XCTAssertFalse(guarded.items[0].provider.windows[0].isMetered)
            XCTAssertFalse(guarded.localSource!.envelope.providers[0].windows[0].isMetered)
            XCTAssertEqual(guarded.items[1], cache.items[1], "Another collector's budget remains that collector's responsibility")
            XCTAssertEqual(guarded.savedAt, now)
            XCTAssertNotEqual(guarded.materialHash, cache.materialHash, "Removing a legacy meter must qualify for a widget/Watch refresh")
        }
    }

    func testInvalidExplicitReferencesCannotCreateMeters() {
        let raw = balance(provider: .moonshot, unit: "cny", remaining: 25)
        for reference in [BudgetReference(amount: 100, unit: "eur"), BudgetReference(amount: .infinity, unit: "cny"),
                          BudgetReference(amount: .nan, unit: "cny"), BudgetReference(amount: 0, unit: "cny")] {
            XCTAssertEqual(raw.applyingBudget(reference: reference), raw)
        }
    }

    func testMoneylessSnapshotKeepsItsIndependentHeadlineAndResetWhenNoBudgetApplies() {
        let reset = now.addingTimeInterval(7 * 86_400)
        let weekly = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 40, resetsAt: nil)
        let reading = QuotaSnapshot(provider: .claude, usedPercent: 55, resetsAt: reset,
            fetchedAt: now, primaryTitle: "Weekly", windows: [weekly])
        XCTAssertEqual(reading.applyingBudget(reference: nil), reading)
        XCTAssertEqual(reading.applyingBudget(reference: BudgetReference(amount: 100, unit: "usd")), reading)
    }

    func testMoonshotCurrencySwitchNeedsNewCurrencyHistoryBeforeForecasting() throws {
        var weeks: [String: UsageHistory] = [:]
        let first = balance(provider: .moonshot, unit: "usd", remaining: 100)
        var second = balance(provider: .moonshot, unit: "usd", remaining: 80)
        second.fetchedAt = now.addingTimeInterval(12 * 3600)
        var china = balance(provider: .moonshot, unit: "cny", remaining: 50)
        china.fetchedAt = now.addingTimeInterval(13 * 3600)
        let clock = china.fetchedAt
        for reading in [first, second, china] { _ = HistoryStore.fold(reading, into: &weeks, now: clock) }
        let history = try XCTUnwrap(weeks["moonshot/balance"])
        XCTAssertNil(Forecast.text(for: china.windows[0], history: history, now: clock),
            "One CNY sample cannot inherit twelve hours of USD consumption")
        XCTAssertEqual(history.amountPoints.map(\.remaining), [50])
    }

    private func balance(provider: Provider, unit: String, remaining: Double) -> QuotaSnapshot {
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: remaining, unit: unit), metered: false)
        return QuotaSnapshot(provider: provider, usedPercent: 0, resetsAt: nil,
            fetchedAt: now, primaryTitle: "Balance", windows: [window])
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void, name: String = #function) rethrows {
        let suite = "tokenroom.tests.BudgetCurrency.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    private func assertLegacyReference(provider: Provider, unit: String, shouldMeter: Bool) async throws {
        let suite = "tokenroom.tests.BudgetCurrency.\(provider.rawValue)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        defaults.set(2, forKey: AppSettings.Keys.version)
        defaults.set(Provider.allCases.map(\.rawValue), forKey: AppSettings.Keys.known)
        defaults.set([provider.rawValue], forKey: AppSettings.Keys.enabled)
        defaults.set([provider.rawValue: 100.0], forKey: AppSettings.Keys.budgets)
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: 25, unit: unit), metered: false)
        let snapshot = QuotaSnapshot(provider: provider, usedPercent: 0, resetsAt: nil,
            fetchedAt: now, primaryTitle: "Balance", windows: [window])
        let store = QuotaStore(settings: AppSettings(defaults: defaults),
            clients: [CurrencyFixtureClient(provider: provider, snapshot: snapshot)], cache: SnapshotCache(directory: folder))
        await store.refresh(force: true)
        let result = try XCTUnwrap(store.statuses[provider]?.snapshot?.windows.first)
        XCTAssertEqual(store.settings.budget(for: provider), 100, "Migration must preserve the saved number")
        XCTAssertEqual(AppSettings(defaults: defaults).budget(for: provider), 100, "A relaunch preserves it too")
        XCTAssertEqual(result.isMetered, shouldMeter, "An unlabelled legacy reference must never adopt a newly observed currency")
        XCTAssertEqual(result.amount?.remaining, 25, "The provider's reported balance remains intact")
        XCTAssertEqual(result.amount?.unit, unit)
    }
}

private struct CurrencyFixtureClient: ProviderClient {
    let provider: Provider
    let snapshot: QuotaSnapshot
    func fetch() async -> Result<QuotaSnapshot, ProviderError> { .success(snapshot) }
}
