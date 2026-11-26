import XCTest
@testable import Tokenroom

final class HistoryQueueDurabilityTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_790_002_800)
    private let weeklyKey = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")
    private let balanceKey = RelayHistory.key(provider: Provider.moonshot.rawValue, window: "balance")

    @MainActor
    func testAFailedSaveKeepsTheQueueUntilTheSameStoreSaves() throws {
        let folder = try makeFolder()
        let taken = [at(60), at(3660), at(7260)]
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: taken[0]), weekly(35, at: taken[1]), weekly(41, at: taken[2])], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)

        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.pending(in: folder).map(\.fetchedAt), taken, "A save that failed leaves every reading queued, oldest first")
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[weeklyKey]?.points.map(\.used), [30, 35, 41], "Widgets still show them")

        try allowSaves(in: folder)
        store.saveIfNeeded()
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35, 41], "The refresh's own save writes what the earlier one couldn't")
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty, "Saved, so no longer queued")
    }

    @MainActor
    func testTakingAgainAfterAFailedSaveRecordsEachReadingOnce() throws {
        let folder = try makeFolder()
        let taken = [at(60), at(3660), at(7260)]
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: taken[0]), weekly(35, at: taken[1]), weekly(41, at: taken[2])], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)

        store.takePending(now: clock)
        store.takePending(now: clock)
        try allowSaves(in: folder)
        store.takePending(now: clock)

        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35, 41], "The next refresh saves them")
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
        let samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), taken, "Each raw reading once, oldest first")
        XCTAssertEqual(samples.map(\.used), [30, 35, 41])
    }

    @MainActor
    func testReadingsLeftByAFailedSaveAreSavedAfterARelaunch() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60)), weekly(35, at: at(3660))], in: folder, now: clock)
        try blockSaves(in: folder)
        HistoryStore(directory: folder).takePending(now: clock)
        try allowSaves(in: folder)
        XCTAssertTrue(HistoryStore.load(from: folder).isEmpty, "Nothing reached the week's file")

        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35])
        XCTAssertEqual(relaunched.weeks[weeklyKey]?.points.map(\.used), [30, 35])
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    @MainActor
    func testAQueuedReadingThatCannotBeReadWaitsForTheNextRefresh() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60)), weekly(35, at: at(3660))], in: folder, now: clock)
        let first = try XCTUnwrap(queuedFiles(in: folder).first { $0.lastPathComponent.hasSuffix("-\(Int(hour.timeIntervalSince1970)).json") })
        chmod(first.path, 0)
        let store = HistoryStore(directory: folder)

        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [35], "The one that could be read is saved")
        let waiting = queuedFiles(in: folder)
        XCTAssertEqual(waiting.count, 1, "The one that couldn't is still there")
        XCTAssertEqual(waiting.first?.lastPathComponent.hasPrefix(first.deletingPathExtension().lastPathComponent + "."), true, "Under its provider and hour")
        waiting.forEach { chmod($0.path, 0o644) }

        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35])
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    @MainActor
    func testALaterReadingOfTheHourJoinsOneLeftByAFailedSave() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)

        HistoryStore.queue([money(80, at: at(600))], in: folder, now: clock)
        XCTAssertEqual(HistoryStore.pending(in: folder).map(\.fetchedAt), [at(60), at(600)], "Both of the hour's readings wait")

        try allowSaves(in: folder)
        store.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [80], "The hour keeps its latest")
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    @MainActor
    func testAnEarlierReadingOfTheHourDoesNotReplaceALaterOneAlreadyTaken() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(50, at: at(600))], in: folder, now: clock)
        try cutShort(in: folder)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)

        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [50], "The later reading stands")
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    @MainActor
    func testAFileThatIsNotAReadingDoesNotReplaceOneAlreadyTaken() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60))], in: folder, now: clock)
        let name = try XCTUnwrap(queuedFiles(in: folder).first).lastPathComponent
        try cutShort(in: folder)
        let queue = folder.appendingPathComponent(HistoryStore.pendingFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: queue.appendingPathComponent(name))

        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Neither file is left behind")
    }

    @MainActor
    func testAQueueThatCannotBeMovedKeepsBothReadingsOfTheHour() throws {
        try XCTSkipIf(getuid() == 0, "Root moves a file whatever its folder's mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60))], in: folder, now: clock)
        try cutShort(in: folder)
        HistoryStore.queue([weekly(35, at: at(600))], in: folder, now: clock)
        let queue = folder.appendingPathComponent(HistoryStore.pendingFolderName)
        chmod(queue.path, 0o555)
        let store = HistoryStore(directory: folder)

        store.takePending(now: clock)
        chmod(queue.path, 0o755)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30], "The one already taken is recorded")
        XCTAssertEqual(HistoryStore.pending(in: folder).map(\.fetchedAt), [at(600)], "The one that couldn't be moved still waits")

        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [35])
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    @MainActor
    func testReadingsOlderThanTheWeekLeaveAQueueThatCannotBeSaved() throws {
        let folder = try makeFolder()
        HistoryStore.queue([weekly(30, at: at(60))], in: folder, now: at(3600))
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)
        store.takePending(now: at(3600))
        XCTAssertEqual(HistoryStore.pending(in: folder).count, 1)

        store.takePending(now: at(8 * 86_400))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "What the week no longer holds goes")
    }

    @MainActor
    func testAReadingQueuedWhileAnInvalidFileIsReadStaysQueued() throws {
        let junk = Data(("[" + String(repeating: "0,", count: 6_000_000) + "0]").utf8)
        try assertAReadingQueuedDuringTheReadIsKept(whileReading: junk)
    }

    @MainActor
    func testAReadingQueuedWhileAnEarlierOneIsReadStaysQueued() throws {
        let window = QuotaWindow(id: "balance", kind: .pool, title: "Balance", usedPercent: 0,
            resetsAt: nil, amount: QuotaAmount(remaining: 80, unit: "usd"), metered: false)
        let earlier = QuotaSnapshot(provider: .moonshot, usedPercent: 0, resetsAt: nil, fetchedAt: at(30),
            primaryTitle: "Balance", windows: Array(repeating: window, count: 40_000))
        try assertAReadingQueuedDuringTheReadIsKept(whileReading: try RelayEnvelope.encoder.encode(earlier))
    }

    @MainActor
    private func assertAReadingQueuedDuringTheReadIsKept(whileReading slow: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(50, at: at(60))], in: folder, now: clock)
        let name = try XCTUnwrap(queuedFiles(in: folder).first).lastPathComponent
        try cutShort(in: folder)
        let queue = folder.appendingPathComponent(HistoryStore.pendingFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try slow.write(to: queue.appendingPathComponent(name), options: .atomic)
        let later = try RelayEnvelope.encoder.encode(money(90, at: at(900)))
        let store = HistoryStore(directory: folder)

        let written = expectation(description: "The widget queued its reading")
        let start = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            start.wait()
            usleep(3_000)
            try? later.write(to: queue.appendingPathComponent(name), options: .atomic)
            written.fulfill()
        }
        start.signal()
        store.takePending(now: clock)
        wait(for: [written], timeout: 10)

        store.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey], file: file, line: line)
        XCTAssertEqual(week.amountPoints.map(\.remaining), [90], "The reading queued meanwhile is recorded", file: file, line: line)
        XCTAssertEqual(week.amountCheckedAt, at(900), file: file, line: line)
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, file: file, line: line)
    }

    @MainActor
    func testAReadingWithTheTimeOfOneAFailedSaveLeftIsRecorded() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [100])

        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        XCTAssertEqual(HistoryStore.pending(in: folder).compactMap { $0.windows.first?.amount?.remaining }, [100, 80], "Oldest first, the one queued later last")
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[balanceKey]?.amountPoints.map(\.remaining), [80], "Widgets show the later one")

        try allowSaves(in: folder)
        store.takePending(now: clock)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [80], "Same time, new reading: recorded")
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [80])
        XCTAssertEqual(week.amountCheckedAt, at(60))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingWithTheTimeOfOneAFailedSaveLeftReplacesItsRawSample() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60)), weekly(35, at: at(3660)), weekly(41, at: at(7260))], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)

        HistoryStore.queue([weekly(44, at: at(7260))], in: folder, now: clock)
        try allowSaves(in: folder)
        store.takePending(now: clock)
        let samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), [at(60), at(3660), at(7260)], "Still one raw reading a time")
        XCTAssertEqual(samples.map(\.used), [30, 35, 44])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 35, 44])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingWithTheTimeOfOneAFailedSaveLeftIsRecordedAfterARelaunch() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        try blockSaves(in: folder)
        HistoryStore(directory: folder).takePending(now: clock)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(HistoryStore.pending(in: folder).compactMap { $0.windows.first?.amount?.remaining }.last, 80, "The later one is still last after a second failed save")

        try allowSaves(in: folder)
        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [80])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingMovedAsideByAnEarlierVersionComesBeforeOneWithItsTime() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        try cutShort(in: folder)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        XCTAssertEqual(HistoryStore.pending(in: folder).compactMap { $0.windows.first?.amount?.remaining }, [100, 80])

        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingThatCannotBeReadWaitsThroughARelaunchAndALaterOneOfItsHour() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60))], in: folder, now: clock)
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(queuedFiles(in: folder).count, 1, "It waits")

        HistoryStore.queue([weekly(35, at: at(600))], in: folder, now: clock)
        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [35], "The later one of its hour is recorded meanwhile")
        let waiting = queuedFiles(in: folder)
        XCTAssertEqual(waiting.count, 1, "The one that can't be read still waits")
        waiting.forEach { chmod($0.path, 0o644) }

        relaunched.takePending(now: clock)
        XCTAssertEqual(relaunched.weeks[weeklyKey]?.points.map(\.used), [35], "An hour keeps its highest use")
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Read at last, so no longer waiting")
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

    private func cutShort(in folder: URL) throws {
        try FileManager.default.moveItem(at: folder.appendingPathComponent(HistoryStore.pendingFolderName),
                                         to: folder.appendingPathComponent(HistoryStore.takingFolderName))
    }

    private func queuedFiles(in folder: URL) -> [URL] {
        [HistoryStore.takingFolderName, HistoryStore.pendingFolderName].flatMap { name in
            (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(name), includingPropertiesForKeys: nil)) ?? []
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
