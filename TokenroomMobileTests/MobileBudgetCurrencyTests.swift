import Security
import XCTest
@testable import TokenroomMobile

/// Hosted iPhone coverage with isolated preferences/storage, mocked Keychain calls, nil CloudKit
/// and an inert external-effects policy. Nothing reads a device credential or provider endpoint.
final class MobileBudgetCurrencyTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []; folders = []
        super.tearDown()
    }

    @MainActor
    func testLegacyChinaReferenceIsPreservedWithoutKeepingAnOldSynthesizedMeter() throws {
        let (defaults, folder) = try fixture()
        defaults.set(["moonshot": 100.0], forKey: MobileStore.Keys.budgets)
        try saveBalance(unit: "cny", reference: BudgetReference(amount: 100, unit: "cny"), to: folder)
        let store = makeStore(defaults, folder)
        XCTAssertEqual(store.budget(for: .moonshot), 100)
        XCTAssertNil(store.budgetReference(for: .moonshot))
        let shown = try XCTUnwrap(store.reading(id: "moonshot")?.provider.windows.first)
        XCTAssertFalse(shown.isMetered)
        XCTAssertEqual(shown.amount?.remaining, 25)
        XCTAssertNil(shown.amount?.limit)
        XCTAssertFalse(try XCTUnwrap(store.watchReadings?.items.first?.provider.windows.first).isMetered)
        XCTAssertEqual(makeStore(defaults, folder).budget(for: .moonshot), 100)
    }

    @MainActor
    func testExplicitDollarReferenceDoesNotMeterAChinaStandInAndCanBeReplaced() throws {
        let (defaults, folder) = try fixture()
        defaults.set(["moonshot": 100.0], forKey: MobileStore.Keys.budgets)
        defaults.set(["moonshot": BudgetReference(amount: 100, unit: "usd").propertyList], forKey: MobileStore.Keys.budgetReferences)
        try saveBalance(unit: "cny", reference: nil, to: folder)
        let store = makeStore(defaults, folder)
        XCTAssertFalse(try XCTUnwrap(store.reading(id: "moonshot")?.provider.windows.first).isMetered)
        XCTAssertEqual(store.budgetCurrency(for: .moonshot, region: "China"), "CNY")
        store.setBudget(100, for: .moonshot, unit: "cny")
        XCTAssertEqual(store.budgetReference(for: .moonshot), BudgetReference(amount: 100, unit: "cny"))
        XCTAssertEqual(try XCTUnwrap(store.reading(id: "moonshot")?.provider.windows.first).used, 75)
        XCTAssertEqual(makeStore(defaults, folder).budgetReference(for: .moonshot)?.unit, "cny")
    }

    @MainActor
    func testNewSelectedRegionOverridesAnOldReadingInTheKeyEditorLabel() throws {
        let (defaults, folder) = try fixture()
        try saveBalance(unit: "usd", reference: nil, to: folder)
        let store = makeStore(defaults, folder)
        XCTAssertEqual(store.budgetCurrency(for: .moonshot, region: "China"), "CNY")
        XCTAssertEqual(store.budgetCurrency(for: .moonshot, region: "Global"), "USD")
        XCTAssertNil(store.budget(for: .moonshot), "Changing the label does not create or convert an amount")
    }

    @MainActor
    func testSavingAReplacementRegionDoesNotRelabelTheSavedReference() async throws {
        let (defaults, folder) = try fixture()
        let store = makeStore(defaults, folder)
        store.setBudget(100, for: .moonshot, unit: "usd")
        try await store.saveKey("fixture-key", for: .moonshot, region: "China")
        XCTAssertEqual(store.budgetReference(for: .moonshot), BudgetReference(amount: 100, unit: "usd"))
        XCTAssertEqual(store.budget(for: .moonshot), 100)
        XCTAssertFalse(store.allowsExternalEffects)
        XCTAssertEqual(store.relayPhase, .unavailable)
    }

    @MainActor
    func testExplicitClearRemovesBothTheNumberAndItsUnitWhileInvalidInputKeepsThem() throws {
        let (defaults, folder) = try fixture()
        let store = makeStore(defaults, folder)
        store.setBudget(100, for: .moonshot, unit: "cny")
        store.setBudget(.infinity, for: .moonshot, unit: "usd")
        store.setBudget(100, for: .moonshot, unit: "eur")
        XCTAssertEqual(store.budgetReference(for: .moonshot), BudgetReference(amount: 100, unit: "cny"))
        store.setBudget(nil, for: .moonshot, unit: "cny")
        XCTAssertNil(store.budget(for: .moonshot))
        XCTAssertNil(store.budgetReference(for: .moonshot))
        XCTAssertNil(defaults.dictionary(forKey: MobileStore.Keys.budgetReferences)?["moonshot"])
    }

    private func fixture() throws -> (UserDefaults, URL) {
        let suite = "tokenroom.tests.MobileBudgetCurrency.\(suites.count)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["moonshot"], forKey: MobileStore.Keys.keyedProviders)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return (defaults, folder)
    }

    @MainActor
    private func saveBalance(unit: String, reference: BudgetReference?, to folder: URL) throws {
        let now = Date()
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: 25, unit: unit), metered: false)
        let snapshot = QuotaSnapshot(provider: .moonshot, usedPercent: 0, resetsAt: nil,
            fetchedAt: now, primaryTitle: "Balance", windows: [window]).applyingBudget(reference: reference)
        let provider = RelayProvider(provider: .moonshot, status: .live(snapshot), checkedAt: now)
        try ReadingCache(savedAt: now, isSample: false, items: [.init(provider: provider, source: MobileStore.localLabel, origin: .thisPhone)])
            .save(to: folder.appendingPathComponent(ReadingCache.fileName))
    }

    @MainActor
    private func makeStore(_ defaults: UserDefaults, _ folder: URL) -> MobileStore {
        let keys = APIKeyStore(servicePrefix: "app.tokenroom.tests.currency.", keychain: .init(
            copy: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecSuccess },
            update: { _, _ in errSecItemNotFound }, delete: { _ in errSecSuccess }))
        return MobileStore(defaults: defaults, containerIdentifier: nil, keys: keys, directory: folder,
            notificationScheduler: { _ in XCTFail("An inert currency fixture must not notify") },
            allowsExternalEffects: false, launchDefaults: defaults)
    }
}
