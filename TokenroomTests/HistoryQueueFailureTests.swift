import XCTest
@testable import Tokenroom

final class HistoryQueueFailureTests: XCTestCase {
    private let hour = Date(timeIntervalSince1970: 1_790_002_800)
    private let balanceKey = RelayHistory.key(provider: Provider.moonshot.rawValue, window: "balance")
    private let weeklyKey = RelayHistory.key(provider: Provider.openai.rawValue, window: "weekly")

    func testAReadingThatCannotBeWrittenIsReportedAndLeavesTheOneBeforeItWhole() throws {
        let folder = try makeFolder()
        let clock = at(900)
        XCTAssertTrue(HistoryStore.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        let file = try XCTUnwrap(queuedFiles(in: folder).first)
        let before = try Data(contentsOf: file)
        try blockWrites(in: folder)

        let outcome = HistoryStore.queue([money(80, at: at(130))], in: folder, now: clock)

        XCTAssertFalse(outcome.isComplete, "The producer says the reading didn't go in")
        XCTAssertFalse(outcome.isPartial)
        XCTAssertTrue(outcome.queued.isEmpty)
        XCTAssertEqual(outcome.failures.map(\.snapshot), [money(80, at: at(130))])
        XCTAssertEqual(outcome.failures.first?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(outcome.failures.first?.code, CocoaError.fileWriteNoPermission.rawValue)
        XCTAssertEqual(try Data(contentsOf: file), before, "The reading queued before is byte for byte what it was")
        XCTAssertEqual(queuedFiles(in: folder), [file], "Nothing half written is left beside it")
        XCTAssertEqual(waiting(in: folder), [100])
        XCTAssertEqual(shown(in: folder, at: clock), [100])
    }

    func testAFirstReadingThatCannotBeWrittenIsReportedToo() throws {
        let folder = try makeFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(HistoryStore.pendingFolderName), withIntermediateDirectories: true)
        try blockWrites(in: folder)

        let outcome = HistoryStore.queue([money(80, at: at(130))], in: folder, now: at(900))

        XCTAssertEqual(outcome.failures.map(\.snapshot), [money(80, at: at(130))])
        XCTAssertTrue(queuedFiles(in: folder).isEmpty)
        XCTAssertFalse(HistoryStore.queue([money(80, at: at(130))], in: nil, now: at(900)).isComplete)
    }

    @MainActor
    func testTheWidgetAsksForARetryAndQueuesTheReadingOnceItCanBeWritten() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let retry = HistoryQueueRetry()
        XCTAssertNil(retry.queue([money(100, at: at(120))], in: folder, now: clock).retryDate(after: nil, now: clock))
        try blockWrites(in: folder)

        let failed = retry.queue([money(80, at: at(130))], in: folder, now: clock)
        XCTAssertEqual(failed.failures.map(\.snapshot), [money(80, at: at(130))])
        XCTAssertEqual(failed.retryDate(after: nil, now: clock), clock)
        let asked = WidgetRefreshResult(cache: nil, retryAt: failed.retryDate(after: nil, now: clock))
        XCTAssertEqual(asked.nextReload(after: clock, reloads: 1), clock.addingTimeInterval(300), "A short retry, like a failed read")
        XCTAssertEqual(asked.nextReload(after: clock, reloads: WidgetRefreshResult.retryAllowance), clock.addingTimeInterval(3600), "Within the day's allowance")
        let serverWait = clock.addingTimeInterval(7200)
        XCTAssertEqual(failed.retryDate(after: serverWait, now: clock), serverWait, "A reading to queue cannot shorten a server wait")
        XCTAssertEqual(shown(in: folder, at: clock), [100], "Widgets still show the reading that did go in")

        let retried = clock.addingTimeInterval(300)
        let stillBlocked = retry.queue([], in: folder, now: retried)
        XCTAssertEqual(stillBlocked.failures.map(\.snapshot), [money(80, at: at(130))], "Tried again, and reported again")
        XCTAssertEqual(stillBlocked.retryDate(after: nil, now: retried), retried)
        XCTAssertEqual(waiting(in: folder), [100])

        try allowWrites(in: folder)
        let recovered = retry.queue([], in: folder, now: retried.addingTimeInterval(300))
        XCTAssertEqual(recovered.queued, [money(80, at: at(130))])
        XCTAssertTrue(recovered.isComplete)
        XCTAssertNil(recovered.retryDate(after: nil, now: retried.addingTimeInterval(300)))
        XCTAssertEqual(waiting(in: folder), [80])
        XCTAssertEqual(shown(in: folder, at: clock), [80])
        XCTAssertTrue(retry.queue([], in: folder, now: retried.addingTimeInterval(600)).queued.isEmpty, "Written once")

        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80], "The app records the reading the retry queued")
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    func testOneReadingThatCannotBeWrittenDoesNotHoldBackAnother() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let retry = HistoryQueueRetry()
        let blocked = folder.appendingPathComponent(HistoryStore.pendingFolderName)
            .appendingPathComponent("\(Provider.moonshot.rawValue)-\(Int(hour.timeIntervalSince1970)).json")
        try FileManager.default.createDirectory(at: blocked.appendingPathComponent("held"), withIntermediateDirectories: true)

        let outcome = retry.queue([money(80, at: at(130)), weekly(35, at: at(140))], in: folder, now: clock)

        XCTAssertTrue(outcome.isPartial)
        XCTAssertEqual(outcome.queued, [weekly(35, at: at(140))])
        XCTAssertEqual(outcome.failures.map(\.snapshot), [money(80, at: at(130))])
        XCTAssertEqual(outcome.retryDate(after: nil, now: clock), clock)
        XCTAssertEqual(HistoryStore.loadWithPending(from: folder, now: clock)[weeklyKey]?.points.map(\.used), [35])

        try FileManager.default.removeItem(at: blocked)
        let recovered = retry.queue([], in: folder, now: clock)
        XCTAssertEqual(recovered.queued, [money(80, at: at(130))], "Only the one still owed")
        XCTAssertTrue(recovered.isComplete)
        XCTAssertEqual(shown(in: folder, at: clock), [80])
    }

    func testALaterReadingOfTheHourTakesThePlaceOfOneStillWaitingToBeWritten() throws {
        let folder = try makeFolder()
        let clock = at(2 * 3600)
        let retry = HistoryQueueRetry()
        XCTAssertTrue(retry.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        try blockWrites(in: folder)
        XCTAssertFalse(retry.queue([money(80, at: at(130))], in: folder, now: clock).isComplete)

        let second = retry.queue([money(70, at: at(200)), money(60, at: at(3700))], in: folder, now: clock)
        XCTAssertEqual(second.failures.map(\.snapshot), [money(70, at: at(200)), money(60, at: at(3700))], "One reading an hour, oldest first")

        try allowWrites(in: folder)
        XCTAssertEqual(retry.queue([], in: folder, now: clock).queued, [money(70, at: at(200)), money(60, at: at(3700))])
        XCTAssertEqual(waiting(in: folder), [70, 60])
    }

    func testAReadingWaitingToBeWrittenDoesNotReplaceALaterOneQueuedMeanwhile() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let retry = HistoryQueueRetry()
        XCTAssertTrue(retry.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        try blockWrites(in: folder)
        XCTAssertFalse(retry.queue([money(80, at: at(130))], in: folder, now: clock).isComplete)
        try allowWrites(in: folder)
        XCTAssertTrue(HistoryStore.queue([money(60, at: at(500))], in: folder, now: clock).isComplete)

        let outcome = retry.queue([], in: folder, now: clock)

        XCTAssertTrue(outcome.queued.isEmpty)
        XCTAssertTrue(outcome.isComplete, "Behind the reading queued since, so no longer owed")
        XCTAssertEqual(waiting(in: folder), [60])
    }

    func testAReadingNeverWrittenIsNotKeptAcrossARelaunch() throws {
        let folder = try makeFolder()
        let clock = at(900)
        XCTAssertTrue(HistoryStore.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        try blockWrites(in: folder)
        XCTAssertFalse(HistoryQueueRetry().queue([money(80, at: at(130))], in: folder, now: clock).isComplete)
        try allowWrites(in: folder)

        let relaunched = HistoryQueueRetry()
        XCTAssertTrue(relaunched.queue([], in: folder, now: clock).queued.isEmpty, "Held in memory only: a new process has nothing to write")
        XCTAssertEqual(waiting(in: folder), [100])
        XCTAssertEqual(relaunched.queue([money(78, at: at(600))], in: folder, now: clock).queued, [money(78, at: at(600))], "Its next reading goes in as usual")
        XCTAssertEqual(waiting(in: folder), [78])
    }

    func testMissingContainerReportsFailureAndAnotherGenerationCannotReplayIt() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let retry = HistoryQueueRetry()
        let outcome = retry.queue([money(80, at: clock)], in: nil, generation: "first", now: clock)
        XCTAssertFalse(outcome.isComplete)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(retry.queue([], in: folder, generation: "second", now: clock).isComplete)
        XCTAssertTrue(HistoryStore.pending(in: folder).isEmpty)
    }

    func testRepeatedSignOutKeepsThePendingLocalWriteUntilTheAccountChanges() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let retry = HistoryQueueRetry()
        PhoneCacheAccess.markSignedOut(in: defaults)
        let generation = PhoneCacheAccess.generation(in: defaults)
        XCTAssertFalse(retry.queue([money(80, at: clock)], in: nil, generation: generation, now: clock).isComplete)
        PhoneCacheAccess.markSignedOut(in: defaults)
        XCTAssertEqual(retry.queue([], in: folder, generation: PhoneCacheAccess.generation(in: defaults), now: clock).queued.count, 1)
        XCTAssertEqual(waiting(in: folder), [80])
        let active = PhoneCacheAccess.markAvailable(in: defaults, expecting: generation)
        XCTAssertNotEqual(active, generation)
        XCTAssertFalse(retry.queue([money(70, at: clock)], in: nil, generation: active, now: clock).isComplete)
        PhoneCacheAccess.markSignedOut(in: defaults)
        XCTAssertNotEqual(PhoneCacheAccess.generation(in: defaults), generation)
        XCTAssertTrue(retry.queue([], in: folder, generation: PhoneCacheAccess.generation(in: defaults), now: clock).queued.isEmpty)
        XCTAssertEqual(waiting(in: folder), [80])
    }

    func testAReadingStillUnwrittenAfterItsWeekIsDropped() throws {
        let folder = try makeFolder()
        let clock = at(900)
        let retry = HistoryQueueRetry()
        XCTAssertTrue(retry.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        try blockWrites(in: folder)
        XCTAssertFalse(retry.queue([money(80, at: at(130))], in: folder, now: clock).isComplete)
        try allowWrites(in: folder)

        let outcome = retry.queue([], in: folder, now: clock.addingTimeInterval(8 * 86_400))

        XCTAssertTrue(outcome.queued.isEmpty)
        XCTAssertTrue(outcome.isComplete, "Out of the week the history keeps, so no longer owed")
        XCTAssertEqual(waiting(in: folder), [100])
        XCTAssertTrue(retry.queue([], in: folder, now: clock).queued.isEmpty)
    }

    @MainActor
    func testAFullVolumeReportsOutOfSpaceAndTheReadingIsQueuedOnceThereIsRoom() throws {
        guard let path = ProcessInfo.processInfo.environment["TOKENROOM_ENOSPC_VOLUME"] else {
            throw XCTSkip("Set TOKENROOM_ENOSPC_VOLUME to a small throwaway volume to fill")
        }
        let volume = URL(fileURLWithPath: path, isDirectory: true)
        let values = try volume.resourceValues(forKeys: [.isVolumeKey, .volumeTotalCapacityKey])
        try XCTSkipUnless(values.isVolume == true && (values.volumeTotalCapacity ?? .max) < 80 * 1024 * 1024, "Only a small throwaway volume is filled")
        let folder = volume.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filler = volume.appendingPathComponent("filler-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: filler)
            try? FileManager.default.removeItem(at: folder)
        }
        let clock = at(900)
        let retry = HistoryQueueRetry()
        XCTAssertTrue(retry.queue([money(100, at: at(120))], in: folder, now: clock).isComplete)
        let file = try XCTUnwrap(queuedFiles(in: folder).first)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try fill(filler), ENOSPC)

        let failed = retry.queue([money(80, at: at(130))], in: folder, now: clock)

        XCTAssertEqual(failed.failures.map(\.snapshot), [money(80, at: at(130))])
        XCTAssertEqual(failed.failures.first?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(failed.failures.first?.code, CocoaError.fileWriteOutOfSpace.rawValue)
        XCTAssertEqual(failed.retryDate(after: nil, now: clock), clock)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(queuedFiles(in: folder), [file])
        XCTAssertEqual(shown(in: folder, at: clock), [100])

        try FileManager.default.removeItem(at: filler)
        let recovered = retry.queue([], in: folder, now: clock.addingTimeInterval(300))
        XCTAssertEqual(recovered.queued, [money(80, at: at(130))])
        XCTAssertEqual(shown(in: folder, at: clock), [80])
        HistoryStore(directory: folder).takePending(now: clock)
        XCTAssertEqual(HistoryStore.load(from: folder)[balanceKey]?.amountPoints.map(\.remaining), [80])
    }

    private func fill(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var reason: Int32 = 0
        for size in [64 * 1024, 4096, 512] {
            let block = [UInt8](repeating: 0xA5, count: size)
            for _ in 0..<4096 {
                let written = write(descriptor, block, size)
                if written < 0 || fsync(descriptor) != 0 {
                    reason = errno
                    break
                }
                if written < size { break }
            }
        }
        return reason
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

    private func blockWrites(in folder: URL) throws {
        XCTAssertEqual(chmod(folder.appendingPathComponent(HistoryStore.pendingFolderName).path, 0o555), 0)
    }

    private func allowWrites(in folder: URL) throws {
        XCTAssertEqual(chmod(folder.appendingPathComponent(HistoryStore.pendingFolderName).path, 0o755), 0)
    }

    private func waiting(in folder: URL) -> [Double] {
        HistoryStore.pending(in: folder).compactMap { $0.windows.first?.amount?.remaining }
    }

    private func shown(in folder: URL, at clock: Date) -> [Double]? {
        HistoryStore.loadWithPending(from: folder, now: clock)[balanceKey]?.amountPoints.map(\.remaining)
    }

    private func queuedFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(HistoryStore.pendingFolderName), includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
