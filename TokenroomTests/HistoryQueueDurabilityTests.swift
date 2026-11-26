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
        XCTAssertEqual(waiting.count, 2, "The one that can't be read still waits, beside the later one saved")
        waiting.forEach { chmod($0.path, 0o644) }
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty, "An earlier reading of the hour doesn't count once a later one is saved")

        relaunched.takePending(now: clock)
        XCTAssertEqual(relaunched.weeks[weeklyKey]?.points.map(\.used), [35], "The hour keeps its later reading")
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Read at last, so no longer waiting")
    }

    @MainActor
    func testAReadingReadableOnlyAfterOneOfItsTimeWasSavedDoesNotReplaceIt() throws {
        try assertALateReadableReadingDoesNotReplaceTheOneSaved(relaunching: false)
    }

    @MainActor
    func testAReadingReadableOnlyAfterOneOfItsTimeWasSavedDoesNotReplaceItAfterARelaunch() throws {
        try assertALateReadableReadingDoesNotReplaceTheOneSaved(relaunching: true)
    }

    @MainActor
    private func assertALateReadableReadingDoesNotReplaceTheOneSaved(relaunching: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        var store = HistoryStore(directory: folder)
        let next = { if relaunching { store = HistoryStore(directory: folder) } }
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0, file: file, line: line) }
        store.takePending(now: clock)
        XCTAssertNil(HistoryStore.load(from: folder)[balanceKey], "It can't be read yet", file: file, line: line)

        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        next()
        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], "The one queued later is saved meanwhile", file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: clock), [80], file: file, line: line)

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(shown(in: folder, at: clock), [80], "A widget keeps the one queued later", file: file, line: line)
        XCTAssertEqual(waiting(in: folder), [], "The earlier one no longer counts", file: file, line: line)

        next()
        store.takePending(now: clock)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [80], "So does the app", file: file, line: line)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: clock), [80], file: file, line: line)
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Nothing is left behind", file: file, line: line)

        next()
        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], file: file, line: line)
    }

    @MainActor
    func testAReadingReadableLateIsRecordedWhenItIsLaterThanTheOneSaved() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(600))], in: folder, now: clock)
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        HistoryStore(directory: folder).takePending(now: clock)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80])

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(shown(in: folder, at: clock), [100], "A widget shows the hour's later reading")
        XCTAssertEqual(waiting(in: folder), [100])
        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [100])
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testANewReadingIsSavedAtOnceWhileAnotherOfItsHourCannotBeRead() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)

        for (remaining, seconds) in [(80.0, 60.0), (75, 60), (70, 300), (65, 300)] {
            HistoryStore.queue([money(remaining, at: at(seconds))], in: folder, now: clock)
            store.takePending(now: clock)
            XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [remaining], "Saved in the refresh that takes it")
            XCTAssertEqual(shown(in: folder, at: clock), [remaining])
            XCTAssertLessThanOrEqual(queuedFiles(in: folder).count, 3)
        }
        HistoryStore.queue([money(90, at: at(120))], in: folder, now: clock)
        XCTAssertEqual(shown(in: folder, at: clock), [65], "An earlier reading of the hour doesn't show over a later one saved")
        store.takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [65])
        store.takePending(now: clock)
        XCTAssertEqual(queuedFiles(in: folder).count, 2, "The one that can't be read and the latest one saved")

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(shown(in: folder, at: clock), [65])
        HistoryStore(directory: folder).takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [65])
        XCTAssertEqual(week.amountCheckedAt, at(300))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testTheReadingKeptForOneThatCannotBeReadLeavesWithItsHour() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: clock)
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        store.takePending(now: clock)
        XCTAssertEqual(queuedFiles(in: folder).count, 2)

        HistoryStore(directory: folder).takePending(now: at(8 * 86_400))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "What the week no longer holds goes")
    }

    @MainActor
    func testAReadingAheadOfTheClockLeavesItsHourToOneReadableOnlyLater() throws {
        try assertAReadingAheadOfTheClockLeavesItsHourToOneReadableOnlyLater(relaunching: false)
    }

    @MainActor
    func testAReadingAheadOfTheClockLeavesItsHourToOneReadableOnlyLaterAfterARelaunch() throws {
        try assertAReadingAheadOfTheClockLeavesItsHourToOneReadableOnlyLater(relaunching: true)
    }

    @MainActor
    private func assertAReadingAheadOfTheClockLeavesItsHourToOneReadableOnlyLater(relaunching: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let setBack = at(600 - 65 * 60)
        var store = HistoryStore(directory: folder)
        let next = { if relaunching { store = HistoryStore(directory: folder) } }
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: at(60))
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0, file: file, line: line) }
        store.takePending(now: at(120))
        XCTAssertNil(HistoryStore.load(from: folder)[balanceKey], "It can't be read yet", file: file, line: line)

        HistoryStore.queue([money(80, at: at(600))], in: folder, now: at(600))
        next()
        store.takePending(now: setBack)
        XCTAssertNil(HistoryStore.load(from: folder)[balanceKey], "65 minutes ahead of the clock, the later one stays out", file: file, line: line)
        XCTAssertNil(shown(in: folder, at: setBack), file: file, line: line)
        XCTAssertEqual(savedNames(in: folder), [], "A reading left out is never kept as the one saved for its hour", file: file, line: line)

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(waiting(in: folder), [100], "The one within the hour still counts", file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: setBack), [100], "A widget shows it", file: file, line: line)

        next()
        store.takePending(now: setBack)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [100], "So does the app", file: file, line: line)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey], file: file, line: line)
        XCTAssertEqual(week.amountPoints.map(\.remaining), [100], file: file, line: line)
        XCTAssertEqual(week.amountCheckedAt, at(60), file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: setBack), [100], file: file, line: line)
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Nothing is left behind", file: file, line: line)

        next()
        store.takePending(now: setBack)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [100], file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: setBack), [100], file: file, line: line)
    }

    @MainActor
    func testAReadingAheadOfTheClockDoesNotReplaceAnEarlierOneOfItsHourThatCanBeRead() throws {
        try assertAReadingAheadOfTheClockDoesNotReplaceAnEarlierOneOfItsHour(relaunching: false)
    }

    @MainActor
    func testAReadingAheadOfTheClockDoesNotReplaceAnEarlierOneOfItsHourAfterARelaunch() throws {
        try assertAReadingAheadOfTheClockDoesNotReplaceAnEarlierOneOfItsHour(relaunching: true)
    }

    @MainActor
    private func assertAReadingAheadOfTheClockDoesNotReplaceAnEarlierOneOfItsHour(relaunching: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let folder = try makeFolder()
        let setBack = at(600 - 65 * 60)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: at(60))
        try blockSaves(in: folder)
        var store = HistoryStore(directory: folder)
        store.takePending(now: at(120))
        XCTAssertEqual(queuedFiles(in: folder).count, 1, "A save that failed leaves it queued", file: file, line: line)

        HistoryStore.queue([money(80, at: at(600)), weekly(30, at: setBack)], in: folder, now: at(600))
        try allowSaves(in: folder)
        XCTAssertEqual(shown(in: folder, at: setBack), [100], "A widget leaves out the one ahead of the clock", file: file, line: line)
        if relaunching { store = HistoryStore(directory: folder) }
        store.takePending(now: setBack)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey], "The one within the hour is recorded", file: file, line: line)
        XCTAssertEqual(week.amountPoints.map(\.remaining), [100], file: file, line: line)
        XCTAssertEqual(week.amountCheckedAt, at(60), file: file, line: line)
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [100], file: file, line: line)
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30], "Readings of other hours are recorded as before", file: file, line: line)
        XCTAssertEqual(shown(in: folder, at: setBack), [100], file: file, line: line)
        XCTAssertTrue(queuedFiles(in: folder).isEmpty, "Nothing is left behind", file: file, line: line)

        HistoryStore(directory: folder).takePending(now: setBack)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [100], file: file, line: line)
    }

    @MainActor
    func testAReadingExactlyAnHourAheadOfTheClockIsItsHoursLatest() throws {
        for (ahead, kept) in [(3600.0, 80.0), (3601, 100)] {
            let folder = try makeFolder()
            let setBack = at(600 - ahead)
            HistoryStore.queue([money(100, at: at(60))], in: folder, now: at(60))
            try cutShort(in: folder)
            HistoryStore.queue([money(80, at: at(600))], in: folder, now: at(600))
            XCTAssertEqual(shown(in: folder, at: setBack), [kept], "\(ahead) seconds ahead, in a widget")

            let store = HistoryStore(directory: folder)
            store.takePending(now: setBack)
            XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [kept], "\(ahead) seconds ahead, in the app")
            let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
            XCTAssertEqual(week.amountPoints.map(\.remaining), [kept])
            XCTAssertEqual(week.amountCheckedAt, kept == 80 ? at(600) : at(60))
            XCTAssertTrue(queuedFiles(in: folder).isEmpty)
        }
    }

    @MainActor
    func testAReadingExactlyAnHourAheadIsKeptAsSavedWhileAnotherOfItsHourCannotBeRead() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let setBack = at(600 - 3600)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: at(60))
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        let store = HistoryStore(directory: folder)
        store.takePending(now: at(120))

        HistoryStore.queue([money(80, at: at(600))], in: folder, now: at(600))
        store.takePending(now: setBack)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], "An hour ahead is still within the rule")
        XCTAssertEqual(savedNames(in: folder).count, 1, "Recorded, so it's kept as the one saved for its hour")

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(shown(in: folder, at: setBack), [80])
        XCTAssertEqual(waiting(in: folder), [], "The earlier one no longer counts")
        HistoryStore(directory: folder).takePending(now: setBack)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [80])
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAReadingRecordedBeforeTheClockWentBackStaysQueuedUntilItIsSaved() throws {
        try XCTSkipIf(getuid() == 0, "Root reads a file whatever its mode")
        let folder = try makeFolder()
        let setBack = at(600 - 65 * 60)
        HistoryStore.queue([money(100, at: at(60))], in: folder, now: at(60))
        queuedFiles(in: folder).forEach { XCTAssertEqual(chmod($0.path, 0), 0) }
        let store = HistoryStore(directory: folder)
        store.takePending(now: at(120))
        HistoryStore.queue([money(80, at: at(600))], in: folder, now: at(600))
        try blockSaves(in: folder)
        store.takePending(now: at(660))
        XCTAssertEqual(store.weeks[balanceKey]?.amountPoints.map(\.remaining), [80], "Recorded while the clock was right")

        store.takePending(now: setBack)
        XCTAssertEqual(queuedFiles(in: folder).count, 2, "Not saved yet, so it stays queued beside the one that can't be read")
        XCTAssertEqual(savedNames(in: folder), [])

        try allowSaves(in: folder)
        store.takePending(now: setBack)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], "The save writes what was recorded")
        XCTAssertEqual(savedNames(in: folder).count, 1, "And keeps it as the one saved for its hour")

        queuedFiles(in: folder).forEach { chmod($0.path, 0o644) }
        XCTAssertEqual(waiting(in: folder), [], "The earlier one doesn't come back over the one saved")
        store.takePending(now: setBack)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testAFolderThatCannotBeListedIsNotClaimedInto() throws {
        try XCTSkipIf(getuid() == 0, "Root lists a folder whatever its mode")
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([money(50, at: at(600))], in: folder, now: clock)
        try blockSaves(in: folder)
        HistoryStore(directory: folder).takePending(now: clock)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        let taking = folder.appendingPathComponent(HistoryStore.takingFolderName)
        XCTAssertEqual(chmod(taking.path, 0o300), 0)
        XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(atPath: taking.path), "It can be written to, not listed")

        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(chmod(taking.path, 0o755), 0)
        XCTAssertEqual(amounts(in: folder).sorted(), [50, 80], "The reading a failed save left is still there")

        try allowSaves(in: folder)
        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        let week = try XCTUnwrap(HistoryStore.load(from: folder)[balanceKey])
        XCTAssertEqual(week.amountPoints.map(\.remaining), [50], "The hour's later reading is the one recorded")
        XCTAssertEqual(week.amountCheckedAt, at(600))
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    func testAClaimTakesANameOfItsOwnAndReplacesNothing() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        let taking = folder.appendingPathComponent(HistoryStore.takingFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: taking, withIntermediateDirectories: true)
        HistoryStore.queue([money(80, at: at(60))], in: folder, now: clock)
        let queued = try XCTUnwrap(queuedFiles(in: folder).first)
        let slot = queued.deletingPathExtension().lastPathComponent
        try RelayEnvelope.encoder.encode(money(50, at: at(600))).write(to: taking.appendingPathComponent("\(slot).1.json"))
        try RelayEnvelope.encoder.encode(money(60, at: at(900))).write(to: taking.appendingPathComponent("\(slot).2.json"))

        XCTAssertEqual(HistoryStore.claim(queued, slot: slot, in: taking, after: 0), 3, "The first name nothing holds")
        let held = Dictionary(uniqueKeysWithValues: queuedFiles(in: folder).map { ($0.lastPathComponent, amount(at: $0)) })
        XCTAssertEqual(held, ["\(slot).1.json": 50, "\(slot).2.json": 60, "\(slot).3.json": 80])
        XCTAssertNil(HistoryStore.claim(queued, slot: slot, in: taking, after: 3), "Nothing left to move")
        XCTAssertEqual(queuedFiles(in: folder).count, 3)
    }

    @MainActor
    func testACorrectedEarlierReadingReplacesItsRawSampleInPlace() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60)), weekly(35, at: at(3660)), weekly(41, at: at(7260))], in: folder, now: clock)
        try blockSaves(in: folder)
        let store = HistoryStore(directory: folder)
        store.takePending(now: clock)

        HistoryStore.queue([weekly(38, at: at(3660))], in: folder, now: clock)
        try allowSaves(in: folder)
        store.takePending(now: clock)
        var samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), [at(60), at(3660), at(7260)], "One raw reading a time, oldest first")
        XCTAssertEqual(samples.map(\.used), [30, 38, 41])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 38, 41])
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[weeklyKey]?.points.map(\.used), [30, 38, 41])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)

        HistoryStore.queue([weekly(33, at: at(1800))], in: folder, now: clock)
        store.takePending(now: clock)
        samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), [at(60), at(1800), at(3660), at(7260)], "A reading from between two goes between them")
        XCTAssertEqual(samples.map(\.used), [30, 33, 38, 41])
    }

    @MainActor
    func testACorrectedEarlierReadingIsInOrderAfterARelaunch() throws {
        let folder = try makeFolder()
        let clock = at(3 * 3600)
        HistoryStore.queue([weekly(30, at: at(60)), weekly(35, at: at(3660)), weekly(41, at: at(7260))], in: folder, now: clock)
        try blockSaves(in: folder)
        HistoryStore(directory: folder).takePending(now: clock)
        HistoryStore.queue([weekly(38, at: at(3660))], in: folder, now: clock)
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[weeklyKey]?.points.map(\.used), [30, 38, 41], "Widgets show the correction")

        try allowSaves(in: folder)
        let relaunched = HistoryStore(directory: folder)
        relaunched.takePending(now: clock)
        let samples = relaunched.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), [at(60), at(3660), at(7260)])
        XCTAssertEqual(samples.map(\.used), [30, 38, 41])
        XCTAssertEqual(HistoryStore.load(from: folder)[weeklyKey]?.points.map(\.used), [30, 38, 41])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
    }

    @MainActor
    func testRawSamplesStayInOrderAndWithinCapacityWhenEarlierOnesArrive() {
        let store = HistoryStore(directory: nil)
        let clock = at(3 * 3600)
        let count = HistoryStore.recentCapacity + 8
        for index in 0..<count {
            store.record(weekly(Double(index % 50), at: at(Double(index) * 60)), now: clock)
        }
        let kept = (8..<count).map { at(Double($0) * 60) }
        XCTAssertEqual(store.samples(provider: .openai, window: "weekly").map(\.date), kept)

        store.record(weekly(77, at: at(40 * 60)), now: clock)
        var samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), kept, "A corrected reading keeps its place")
        XCTAssertEqual(samples.first { $0.date == at(40 * 60) }?.used, 77)

        store.record(weekly(12, at: at(0)), now: clock)
        samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.map(\.date), kept, "One older than every sample kept doesn't push a newer one out")

        store.record(weekly(66, at: at(40 * 60 + 30)), now: clock)
        samples = store.samples(provider: .openai, window: "weekly")
        XCTAssertEqual(samples.count, HistoryStore.recentCapacity)
        XCTAssertEqual(samples.map(\.date), samples.map(\.date).sorted(), "Oldest first")
        XCTAssertEqual(Set(samples.map(\.date)).count, samples.count, "One sample a time")
        XCTAssertEqual(samples.first?.date, at(9 * 60), "The oldest makes room")
        XCTAssertEqual(samples.first { $0.date == at(40 * 60 + 30) }?.used, 66)
        XCTAssertEqual(samples.last?.date, kept.last)
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

    private func amount(at url: URL) -> Double? {
        (try? Data(contentsOf: url)).flatMap { try? RelayEnvelope.decoder.decode(QuotaSnapshot.self, from: $0) }?.windows.first?.amount?.remaining
    }

    private func amounts(in folder: URL) -> [Double] {
        queuedFiles(in: folder).compactMap(amount(at:))
    }

    private func waiting(in folder: URL) -> [Double] {
        HistoryStore.pending(in: folder).compactMap { $0.windows.first?.amount?.remaining }
    }

    private func shown(in folder: URL, at clock: Date) -> [Double]? {
        HistoryStore.loadWithPending(from: folder, now: clock)[balanceKey]?.amountPoints.map(\.remaining)
    }

    private func savedNames(in folder: URL) -> [String] {
        queuedFiles(in: folder).map(\.lastPathComponent).filter { $0.hasSuffix(".saved.json") }
    }

    private func queuedFiles(in folder: URL) -> [URL] {
        [HistoryStore.takingFolderName, HistoryStore.pendingFolderName].flatMap { name in
            (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(name), includingPropertiesForKeys: nil)) ?? []
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
