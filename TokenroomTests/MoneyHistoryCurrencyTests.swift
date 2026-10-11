import XCTest
@testable import Tokenroom

final class MoneyHistoryCurrencyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_337_600)

    func testCurrencyTransitionClearsOnlyAmountsAndPreservesUsageAndResetHistory() {
        var week = UsageHistory(endingAt: base.addingTimeInterval(13 * 3600))
        week.record(40, at: base)
        week.recordAmount(100, unit: "usd", at: base)
        week.recordResetTime(base.addingTimeInterval(3600), at: base)
        week.record(60, at: base.addingTimeInterval(12 * 3600))
        week.recordAmount(80, unit: "usd", at: base.addingTimeInterval(12 * 3600))
        week.recordResetTime(base.addingTimeInterval(24 * 3600), at: base.addingTimeInterval(12 * 3600))
        let used = week.used, resets = week.resets, boundary = week.windowResetsAt
        XCTAssertTrue(week.recordAmount(50, unit: "cny", at: base.addingTimeInterval(13 * 3600)))
        XCTAssertEqual(week.amountUnit, "cny")
        XCTAssertEqual(week.amountPoints.map(\.remaining), [50])
        XCTAssertEqual(week.used, used)
        XCTAssertEqual(week.resets, resets)
        XCTAssertEqual(week.windowResetsAt, boundary)
    }

    func testForecastRejectsMismatchedAndUnknownUnitsEvenWithEnoughMonetarySamples() throws {
        var week = UsageHistory(endingAt: base)
        week.recordAmount(100, unit: "usd", at: base)
        week.recordAmount(80, unit: "usd", at: base.addingTimeInterval(12 * 3600))
        XCTAssertNotNil(Forecast.daysLeft(remaining: 80, unit: "usd", history: week))
        XCTAssertNil(Forecast.daysLeft(remaining: 80, unit: "cny", history: week))
        let yuan = money(remaining: 80, unit: "cny", at: base.addingTimeInterval(12 * 3600))
        XCTAssertNil(Forecast.text(for: yuan.windows[0], history: week))
        week.amountUnit = nil
        XCTAssertNil(Forecast.daysLeft(remaining: 80, unit: "usd", history: week))
        XCTAssertNil(Forecast.text(for: yuan.windows[0], history: week))
    }

    func testLegacyAmbiguousAmountsAreDiscardedWithoutLosingPercentagesOrResets() throws {
        var legacy = UsageHistory(endingAt: base)
        legacy.record(40, at: base)
        legacy.recordAmount(100, unit: "usd", at: base)
        legacy.recordAmount(80, unit: "usd", at: base.addingTimeInterval(12 * 3600))
        legacy.recordResetTime(base.addingTimeInterval(3600), at: base)
        legacy.amountUnit = nil
        legacy.amountCheckedAt = nil
        let restored = try RelayEnvelope.decoder.decode(UsageHistory.self, from: RelayEnvelope.encoder.encode(legacy))
        XCTAssertNil(restored.amountUnit, "Older records still decode")
        for provider in ["moonshot", "deepseek"] {
            let migrated = restored.migratingLegacyAmounts(for: provider)
            XCTAssertNil(migrated.amounts)
            XCTAssertEqual(migrated.used, restored.used)
            XCTAssertEqual(migrated.resets, restored.resets)
            XCTAssertEqual(migrated.windowResetsAt, restored.windowResetsAt)
            var next = migrated
            next.recordAmount(50, unit: "cny", at: base.addingTimeInterval(13 * 3600))
            XCTAssertEqual(next.amountPoints.map(\.remaining), [50])
        }
        let dollars = restored.migratingLegacyAmounts(for: "vercelGateway")
        XCTAssertEqual(dollars.amountUnit, "usd")
        XCTAssertEqual(dollars.amountPoints.map(\.remaining), [100, 80])
    }

    func testRelayPreservesUnitAndLegacyRelayConsumersDoNotReuseAmbiguousAmounts() throws {
        var week = UsageHistory(endingAt: base)
        week.record(40, at: base)
        week.recordAmount(50, unit: "cny", at: base)
        let relay = RelayHistory(series: ["moonshot/balance": week])
        let restored = try RelayHistory.decode(relay.encoded())
        XCTAssertEqual(restored, relay)
        XCTAssertEqual(ReadingAssembler.history(for: "moonshot", in: restored)["balance"]?.amountUnit, "cny")
        week.amountUnit = nil
        week.amountCheckedAt = nil
        let oldRelay = RelayHistory(series: ["moonshot/balance": week])
        let oldRestored = try RelayHistory.decode(oldRelay.encoded())
        let guarded = try XCTUnwrap(ReadingAssembler.history(for: "moonshot", in: oldRestored)["balance"])
        XCTAssertNil(guarded.amounts)
        XCTAssertEqual(guarded.points.map(\.used), [40])
    }

    @MainActor
    func testWidgetPendingSamplesAndPersistedHistoryKeepOnlyTheCurrentCurrencySegment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = base.addingTimeInterval(13 * 3600)
        let readings = [money(remaining: 100, unit: "usd", at: base),
                        money(remaining: 80, unit: "usd", at: base.addingTimeInterval(12 * 3600)),
                        money(remaining: 50, unit: "cny", at: clock)]
        HistoryStore.queue(readings, in: folder, now: clock)
        let pending = try XCTUnwrap(HistoryStore.loadWithPending(from: folder, now: clock)["moonshot/balance"])
        XCTAssertEqual(pending.amountUnit, "cny")
        XCTAssertEqual(pending.amountPoints.map(\.remaining), [50])
        XCTAssertNil(Forecast.text(for: readings[2].windows[0], history: pending, now: clock))
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        let persisted = try XCTUnwrap(HistoryStore.load(from: folder)["moonshot/balance"])
        XCTAssertEqual(persisted, pending)
        let next = money(remaining: 30, unit: "cny", at: clock.addingTimeInterval(12 * 3600))
        store.record(next, now: next.fetchedAt)
        let week = try XCTUnwrap(store.weeks["moonshot/balance"])
        XCTAssertNotNil(Forecast.text(for: next.windows[0], history: week, now: next.fetchedAt), "Only a new CNY burn interval establishes CNY runway")
    }

    func testLateOldRegionSampleCannotReplaceTheNewSegmentAndUnchangedChecksAdvanceProvenance() throws {
        var weeks: [String: UsageHistory] = [:]
        let clock = base.addingTimeInterval(13.5 * 3600)
        for reading in [money(remaining: 100, unit: "usd", at: base),
                        money(remaining: 50, unit: "cny", at: base.addingTimeInterval(13 * 3600)),
                        money(remaining: 50, unit: "cny", at: clock)] {
            XCTAssertTrue(HistoryStore.fold(reading, into: &weeks, now: clock))
        }
        let late = money(remaining: 80, unit: "usd", at: base.addingTimeInterval(13.25 * 3600))
        _ = HistoryStore.fold(late, into: &weeks, now: clock)
        let week = try XCTUnwrap(weeks["moonshot/balance"])
        XCTAssertEqual(week.amountUnit, "cny")
        XCTAssertEqual(week.amountCheckedAt, clock)
        XCTAssertEqual(week.amountPoints.map(\.remaining), [50], "The unchanged same-hour check advances the fence without adding a bucket")
    }

    @MainActor
    func testDiskLegacyMigrationPreservesUsageWhileClearingOnlyAmbiguousAmounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var legacy = UsageHistory(endingAt: base)
        legacy.record(40, at: base)
        legacy.recordAmount(100, unit: "usd", at: base)
        legacy.amountUnit = nil; legacy.amountCheckedAt = nil
        let records = ["moonshot/balance": legacy, "deepseek/balance-usd": legacy, "vercelGateway/credits": legacy]
        try RelayEnvelope.encoder.encode(records).write(to: folder.appendingPathComponent(HistoryStore.fileName))
        let store = HistoryStore(directory: folder)
        XCTAssertNil(store.weeks["moonshot/balance"]?.amounts)
        XCTAssertNil(store.weeks["deepseek/balance-usd"]?.amounts)
        XCTAssertEqual(store.weeks["moonshot/balance"]?.used, legacy.used)
        XCTAssertEqual(store.weeks["vercelGateway/credits"]?.amountUnit, "usd")
        XCTAssertEqual(store.weeks["vercelGateway/credits"]?.amountPoints.map(\.remaining), [100])
        store.saveIfNeeded()
        XCTAssertEqual(HistoryStore.load(from: folder), store.weeks)
    }

    private func money(remaining: Double, unit: String, at date: Date) -> QuotaSnapshot {
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: remaining, unit: unit), metered: false)
        return QuotaSnapshot(provider: .moonshot, usedPercent: 0, resetsAt: nil,
            fetchedAt: date, primaryTitle: "Balance", windows: [window])
    }
}
