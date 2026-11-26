import XCTest
@testable import Tokenroom

final class HistoryStoreRecoveryTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_790_002_800)
    private let weeklyKey = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")
    private let balanceKey = RelayHistory.key(provider: Provider.moonshot.rawValue, window: "balance")

    @MainActor
    func testAnEarlierVersionFindsNothingToUndoASavedReadingWith() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        queued(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(queued(in: folder).map(\.pathExtension), [HistoryStore.heldExtension], "Out of an earlier version's sight from the refresh that couldn't read it")

        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(balances(in: folder), [150, 80])
        queued(in: folder).forEach { chmod($0.path, 0o644) }

        XCTAssertEqual(queued(in: folder).count, 2, "The one that couldn't be read and the one saved for its hour")
        XCTAssertTrue(readingsAnEarlierVersionLists(in: folder).isEmpty, "Neither is a reading to an earlier version")
        XCTAssertEqual(shownByAnEarlierVersion(in: folder, at: clock), [[150, 80]], "Its widgets keep the saved reading in whichever order they read")
        refreshAsAnEarlierVersion(in: folder)
        XCTAssertEqual(balances(in: folder), [150, 80], "And so does its app")
        XCTAssertEqual(queued(in: folder).count, 2, "It leaves both where they were")

        let returned = HistoryStore(directory: folder)
        returned.takePending(now: clock)
        XCTAssertEqual(returned.weeks[balanceKey]?.amountPoints.map(\.remaining), [150, 80], "Back on this version, the saved reading still stands")
        XCTAssertEqual(balances(in: folder), [150, 80])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30], "The other provider is untouched")
        XCTAssertTrue(queued(in: folder).isEmpty)
    }

    @MainActor
    func testALaterReadingKeptOutOfSightIsRecordedOnceItCanBeRead() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(70, at: at(600))], in: folder, now: clock)
        queued(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        HistoryStore(directory: folder).takePending(now: clock)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        HistoryStore(directory: folder).takePending(now: clock)
        queued(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertTrue(readingsAnEarlierVersionLists(in: folder).isEmpty)
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[balanceKey]?.amountPoints.map(\.remaining), [70], "This version's widgets show the later one")

        HistoryStore(directory: folder).takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [70])
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(queued(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingRecordedAndThenUnreadableIsSavedOnceAndLeavesNothingBehind() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        let store = HistoryStore(directory: folder)
        try blockSaves(in: folder)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        store.takePending(now: clock)
        XCTAssertEqual(queued(in: folder).map(\.pathExtension), ["json"], "Recorded but not saved, so still a reading to any version")

        queued(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        store.takePending(now: clock)
        XCTAssertEqual(queued(in: folder).map(\.pathExtension), [HistoryStore.heldExtension])

        try allowSaves(in: folder)
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(balances(in: folder), [80])
        XCTAssertEqual(queued(in: folder).count, 1, "Kept as the one saved for its hour")
        XCTAssertTrue(queued(in: folder).allSatisfy { $0.lastPathComponent.hasSuffix(".saved.\(HistoryStore.heldExtension)") })

        queued(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
        store.takePending(now: clock)
        XCTAssertTrue(queued(in: folder).isEmpty, "Nothing of its hour is waiting any more")
        XCTAssertEqual(balances(in: folder), [80])
    }

    @MainActor
    func testAClaimCountsPastTheOnesKeptOutOfSight() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        queued(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        HistoryStore(directory: folder).takePending(now: clock)
        try blockSaves(in: folder)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        HistoryStore(directory: folder).takePending(now: clock)
        let names = queued(in: folder).map(\.lastPathComponent)
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains { $0.hasSuffix(".1.\(HistoryStore.heldExtension)") })
        XCTAssertTrue(names.contains { $0.hasSuffix(".2.json") }, "The next claim, not the held one's again")
    }

    @MainActor
    func testACompetingClaimCannotBeCommittedUntilTheOldReaderCannotReplayItsPredecessor() throws {
        try XCTSkipIf(getuid() == 0, "Requires directory permissions")
        let folder = try makeFolder()
        let taking = folder.appendingPathComponent(HistoryStore.takingFolderName)
        try FileManager.default.createDirectory(at: taking, withIntermediateDirectories: true)
        let slot = "moonshot-\(Int(hour.timeIntervalSince1970))"
        let earlier = taking.appendingPathComponent("\(slot).1.json")
        let later = taking.appendingPathComponent("\(slot).2.json")
        try RelayEnvelope.encoder.encode(money(100, at: at(60))).write(to: earlier)
        try RelayEnvelope.encoder.encode(money(80, at: at(60))).write(to: later)
        XCTAssertEqual(chmod(earlier.path, 0), 0)
        XCTAssertEqual(chmod(taking.path, 0o555), 0)
        defer { chmod(taking.path, 0o755) }
        let store = HistoryStore(directory: folder)
        store.takePending(now: at(600))
        XCTAssertTrue(HistoryStore.load(from: folder).isEmpty)
        XCTAssertEqual(chmod(taking.path, 0o755), 0)
        store.takePending(now: at(600))
        XCTAssertEqual(balances(in: folder), [80])
        XCTAssertTrue(queued(in: folder).allSatisfy { $0.pathExtension == HistoryStore.heldExtension })
    }

    @MainActor
    func testAHistoryFileThatCannotBeReadAtLaunchIsNotReplacedAndComesBackWithNewReadings() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let original = try Data(contentsOf: file)

        XCTAssertEqual(chmod(file.path, 0), 0)
        let store = HistoryStore(directory: folder)
        XCTAssertTrue(store.weeks.isEmpty)
        XCTAssertTrue(HistoryStore.load(from: folder).isEmpty, "Readers that don't record see nothing meanwhile")
        XCTAssertTrue(store.record(money(100, at: at(60)), now: clock))
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [100], "New readings show at once")
        XCTAssertFalse(store.saveIfNeeded(), "Nothing is written over a file that's there but couldn't be loaded")
        XCTAssertFalse(store.saveIfNeeded())

        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertEqual(try Data(contentsOf: file), original, "Byte for byte what it was")
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [150, 100])
        XCTAssertEqual(store.weeks[weeklyKey]?.points.map(\.used), [30])
        XCTAssertEqual(balances(in: folder), [150, 100])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30], "The other provider's week is back too")

        XCTAssertTrue(store.record(money(90, at: at(3660)), now: clock))
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(balances(in: folder), [150, 100, 90], "And it saves as usual from then on")
    }

    @MainActor
    func testAHistoryFileThatCannotBeDecodedAtLaunchIsNotReplacedAndComesBackWithNewReadings() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let original = try Data(contentsOf: file)
        let damaged = Data("not a history file".utf8)
        try damaged.write(to: file)

        let store = HistoryStore(directory: folder)
        XCTAssertTrue(store.record(money(100, at: at(60)), now: clock))
        XCTAssertTrue(store.record(weekly(35, at: at(120)), now: clock))
        XCTAssertFalse(store.saveIfNeeded())
        XCTAssertEqual(try Data(contentsOf: file), damaged, "Left as it was")

        try original.write(to: file)
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(balances(in: folder), [150, 100])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35])
    }

    @MainActor
    func testReadingsTakenWhileTheHistoryFileCannotBeLoadedKeepTheirHoursLatest() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let original = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)

        let store = HistoryStore(directory: folder)
        for (remaining, seconds) in [(100.0, 60.0), (95, 300), (70, 3660), (60, 7260), (65, 7200)] {
            XCTAssertTrue(store.record(money(remaining, at: at(seconds)), now: clock))
        }
        XCTAssertFalse(store.record(money(1, at: at(9 * 3600)), now: clock), "One dated over an hour ahead is left out as ever")
        try original.write(to: file)
        XCTAssertTrue(store.saveIfNeeded())
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [150, 95, 70, 60])
        XCTAssertEqual(week.amountCheckedAt, at(7260))
    }

    @MainActor
    func testQueuedReadingsStayQueuedThroughRelaunchesUntilTheHistoryFileLoads() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let original = try Data(contentsOf: file)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)

        XCTAssertEqual(chmod(file.path, 0), 0)
        for _ in 0..<2 {
            let store = HistoryStore(directory: folder)
            store.takePending(now: clock)
            store.takePending(now: clock)
            XCTAssertEqual(HistoryStore.pending(in: folder).count, 1, "Still queued, once")
            XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[balanceKey]?.amountPoints.map(\.remaining), [100], "Widgets show it meanwhile")
        }
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertEqual(try Data(contentsOf: file), original)

        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        XCTAssertEqual(balances(in: folder), [150, 100])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30])
        XCTAssertTrue(queued(in: folder).isEmpty)
    }

    @MainActor
    func testAHistoryFileReadableAgainBeforeTheRefreshLoadsBeforeAnythingIsRecorded() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)

        XCTAssertEqual(chmod(file.path, 0), 0)
        let store = HistoryStore(directory: folder)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        store.takePending(now: clock)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [150, 100])
        XCTAssertEqual(balances(in: folder), [150, 100])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30])
        XCTAssertTrue(queued(in: folder).isEmpty)
    }

    @MainActor
    func testAHistoryFileGoneWhileItCouldNotBeLoadedIsWrittenAnew() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        try Data("{".utf8).write(to: file)
        let store = HistoryStore(directory: folder)
        XCTAssertTrue(store.record(money(100, at: at(60)), now: clock))
        XCTAssertTrue(store.record(money(95, at: at(300)), now: clock))
        XCTAssertFalse(store.saveIfNeeded())

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(balances(in: folder), [95])
    }

    @MainActor
    func testReloadingTheWeekKeepsAnHourlyPeakFromBeforeAReset() throws {
        let folder = try makeFolder()
        let clock = at(3600)
        try seed(in: folder, clock: clock)
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let original = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        let store = HistoryStore(directory: folder)
        store.record(weekly(90, at: at(60)), now: clock)
        store.record(weekly(5, at: at(90)), now: clock)
        try original.write(to: file)
        XCTAssertTrue(store.saveIfNeeded())
        XCTAssertEqual(HistoryStore.load(from: folder)["openai/weekly"]?.points.last?.used, 90)
    }

    @MainActor
    func testAnOldModificationDateCannotAuthorizeReplacingUnreadableHistory() throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        let damaged = Data("not a history file".utf8)
        try damaged.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: file.path)

        let store = HistoryStore(directory: folder)
        store.record(money(100, at: at(60)), now: at(900))
        XCTAssertFalse(store.saveIfNeeded())
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    private func at(_ seconds: TimeInterval) -> Date {
        hour.addingTimeInterval(seconds)
    }

    private func weekly(_ used: Double, at date: Date) -> QuotaSnapshot {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: hour.addingTimeInterval(3 * 86_400), windowSeconds: 7 * 86_400)
        return try! QuotaSnapshot.headlined(by: [window], provider: .openai, fetchedAt: date)
    }

    private func money(_ remaining: Double, at date: Date) -> QuotaSnapshot {
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: remaining, unit: "usd"), metered: false)
        return QuotaSnapshot(provider: .moonshot, usedPercent: 0, resetsAt: nil,
            fetchedAt: date, primaryTitle: "Balance", windows: [window])
    }

    @MainActor
    private func seed(in folder: URL, clock: Date) throws {
        let store = HistoryStore(directory: folder)
        XCTAssertTrue(store.record(money(150, at: at(-7200)), now: clock))
        XCTAssertTrue(store.record(weekly(30, at: at(-3600)), now: clock))
        XCTAssertTrue(store.saveIfNeeded())
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            for url in files { chmod(url.path, 0o755) }
            try? FileManager.default.removeItem(at: folder)
        }
        return folder
    }

    private func blockSaves(in folder: URL) throws {
        let file = folder.appendingPathComponent(HistoryStore.fileName)
        try FileManager.default.createDirectory(at: file.appendingPathComponent("held"), withIntermediateDirectories: true)
    }

    private func allowSaves(in folder: URL) throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(HistoryStore.fileName))
    }

    private func balances(in folder: URL) -> [Double]? {
        HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining)
    }

    private func queued(in folder: URL) -> [URL] {
        [HistoryStore.takingFolderName, HistoryStore.pendingFolderName].flatMap { name in
            (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(name), includingPropertiesForKeys: nil)) ?? []
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readingsAnEarlierVersionLists(in folder: URL) -> [QuotaSnapshot] {
        queued(in: folder).filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? RelayEnvelope.decoder.decode(QuotaSnapshot.self, from: $0) }
        }
    }

    private func shownByAnEarlierVersion(in folder: URL, at clock: Date) -> Set<[Double]> {
        let readings = readingsAnEarlierVersionLists(in: folder)
        var shown: Set<[Double]> = []
        for order in [readings, readings.reversed()] {
            var weeks = HistoryStore.load(from: folder)
            for snapshot in order.enumerated().sorted(by: { ($0.element.fetchedAt, $0.offset) < ($1.element.fetchedAt, $1.offset) }).map(\.element) {
                _ = HistoryStore.fold(snapshot, into: &weeks, now: clock)
            }
            shown.insert(weeks[balanceKey]?.amountPoints.map(\.remaining) ?? [])
        }
        return shown
    }

    private func refreshAsAnEarlierVersion(in folder: URL) {
        for url in queued(in: folder) where url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
