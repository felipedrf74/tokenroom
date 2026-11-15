import CloudKit
import XCTest
@testable import Tokenroom

final class UsageIngestionTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach(TestDefaults.remove)
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let (name, defaults) = TestDefaults.make(owner: "\(Self.self)", index: suites.count)
        suites.append(name)
        return defaults
    }

    private func envelope(used: Double, at date: Date, producer: String = "mac", provider: String = "claude") -> RelayEnvelope {
        let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used,
                                 resetsAt: now.addingTimeInterval(86_400), periodSec: 7 * 86_400)
        return RelayEnvelope(producer: producer, appVersion: "1", checkedAt: date, providers: [
            RelayProvider(id: provider, name: provider, shortName: provider, monogram: "X", tint: "#000000",
                          state: "live", checkedAt: date, primaryWindowID: window.id, windows: [window])
        ])
    }

    private func snapshotSource(_ id: String, used: Double, at date: Date, kind: CollectorKind = .mac, provider: String = "claude") -> ReadingCache.SourceSnapshot {
        .init(RelayMerge.Source(id: id, label: kind == .mac ? "Mac" : "iPhone", envelope: envelope(used: used, at: date, provider: provider), kind: kind))
    }

    private func cloudSource(_ id: String, used: Double, at date: Date) -> CloudRelay.Source {
        .init(id: id, kind: "mac", label: "Mac", modifiedAt: date, envelope: envelope(used: used, at: date), needsNewerApp: false)
    }


    func testReadByNameKeepsMembershipTakesNewerCopiesAndDropsConfirmedGone() {
        let snapshot = ReadingCache.RelaySnapshot(checkedAt: now, sources: [
            snapshotSource("src-newer", used: 10, at: now),
            snapshotSource("src-unanswered", used: 20, at: now),
            snapshotSource("src-gone", used: 30, at: now),
            snapshotSource("src-older", used: 40, at: now),
        ])
        let read = CloudRelay.SourceRead(sources: [
            cloudSource("src-newer", used: 60, at: now.addingTimeInterval(300)),
            cloudSource("src-older", used: 5, at: now.addingTimeInterval(-300)),
            cloudSource("src-unknown", used: 99, at: now),
        ], missing: ["src-gone"])
        let histories = ["src-newer": RelayHistory(series: [:]), "src-gone": RelayHistory(series: [:])]
        let contents = RelaySourceRefresh.contents(from: snapshot, histories: histories, read: read, now: now.addingTimeInterval(600))
        XCTAssertEqual(contents.sources.map(\.id), ["src-newer", "src-unanswered", "src-older"],
                       "Membership is the last complete read's, less the confirmed gone; no new collector is claimed")
        let used = Dictionary(uniqueKeysWithValues: contents.sources.map { ($0.id, $0.envelope?.providers.first?.windows.first?.used) })
        XCTAssertEqual(used["src-newer"], 60)
        XCTAssertEqual(used["src-unanswered"], 20, "A record the request couldn't read keeps the copy held")
        XCTAssertEqual(used["src-older"], 40, "An older copy never replaces a newer one")
        XCTAssertEqual(Set(contents.histories.keys), ["src-newer"])
        XCTAssertEqual(RelaySourceRefresh.names(in: snapshot), ["src-newer", "src-unanswered", "src-gone", "src-older"])
        XCTAssertEqual(RelaySourceRefresh.recordKind(.otherPhone), "iphone")
        XCTAssertEqual(RelaySourceRefresh.recordKind(nil), "mac")
    }

    func testConfirmedRemovalIsKeptApartFromTheMembershipItWasReadAgainst() {
        let snapshot = ReadingCache.RelaySnapshot(checkedAt: now, sources: [
            snapshotSource("src-stays", used: 10, at: now), snapshotSource("src-gone", used: 20, at: now),
        ])
        let later = now.addingTimeInterval(600)
        let unchanged = CloudRelay.SourceRead(sources: [cloudSource("src-stays", used: 15, at: later)], missing: ["src-unknown"])
        XCTAssertNil(RelaySourceRefresh.removals(of: snapshot, after: unchanged, now: later))
        let removal = CloudRelay.SourceRead(sources: [cloudSource("src-stays", used: 15, at: later)], missing: ["src-gone"])
        XCTAssertEqual(RelaySourceRefresh.removals(of: snapshot, after: removal, now: later), ["src-gone": later])
    }

    func testReconcileAppliesRemovalsConfirmedAfterTheNewerMembershipAndKeepsItsNewCollectors() {
        let local = ReadingCache.SourceSnapshot(RelayMerge.Source(id: "src-phone", label: "This iPhone",
            envelope: RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: []), kind: .thisPhone))
        let t1 = now.addingTimeInterval(60)
        let t2 = now.addingTimeInterval(120)
        let phone = ReadingCache(savedAt: t1, isSample: false, items: [], relaySnapshot: .init(checkedAt: t1, sources: [
            snapshotSource("src-a", used: 10, at: now), snapshotSource("src-b", used: 20, at: now), snapshotSource("src-c", used: 30, at: t1),
        ]), localSource: local)
        let watchSnapshot = ReadingCache.RelaySnapshot(checkedAt: now, sources: [
            snapshotSource("src-a", used: 10, at: now), snapshotSource("src-b", used: 20, at: now),
        ])
        let read = CloudRelay.SourceRead(sources: [cloudSource("src-b", used: 25, at: t2)], missing: ["src-a"])
        let contents = RelaySourceRefresh.contents(from: watchSnapshot, histories: [:], read: read, now: t2)
        let watch = ReadingCache(savedAt: t2, isSample: false, items: [], relaySnapshot: .init(
            checkedAt: watchSnapshot.checkedAt,
            sources: contents.sources.compactMap { source in source.envelope.map {
                ReadingCache.SourceSnapshot(RelayMerge.Source(id: source.id, label: source.label, envelope: $0, kind: CollectorKind(recordKind: source.kind)))
            } },
            removed: RelaySourceRefresh.removals(of: watchSnapshot, after: read, now: t2)), localSource: local)
        for merged in [phone.mergingUpdate(watch, now: t2), watch.mergingUpdate(phone, now: t2)] {
            XCTAssertEqual(merged.relaySnapshot?.checkedAt, t1)
            XCTAssertEqual(merged.relaySnapshot?.sources.map(\.id), ["src-b", "src-c"], "The collector found at t1 stays; the one confirmed gone at t2 doesn't come back")
            XCTAssertEqual(merged.relaySnapshot?.sources.first?.envelope.providers.first?.windows.first?.used, 25)
            XCTAssertEqual(merged.relaySnapshot?.removed, ["src-a": t2])
        }

        let laterComplete = ReadingCache(savedAt: t2.addingTimeInterval(60), isSample: false, items: [], relaySnapshot: .init(
            checkedAt: t2.addingTimeInterval(60), sources: [snapshotSource("src-a", used: 5, at: t2.addingTimeInterval(60))]), localSource: local)
        let back = phone.mergingUpdate(watch, now: t2).mergingUpdate(laterComplete, now: t2.addingTimeInterval(60))
        XCTAssertEqual(back.relaySnapshot?.sources.map(\.id), ["src-a"], "A complete read after the removal is the newer word")
        XCTAssertNil(back.relaySnapshot?.removed)
    }

    func testWatchCachesWithoutAPhoneHandoverReconcileMembershipAndRemovalsToo() {
        let t1 = now.addingTimeInterval(60)
        let t2 = now.addingTimeInterval(120)
        func cache(_ sources: [ReadingCache.SourceSnapshot], membershipAt: Date, savedAt: Date, removed: [String: Date]? = nil) -> ReadingCache {
            ReadingCache(savedAt: savedAt, isSample: false,
                         items: ReadingAssembler.assemble(sources: sources.map(\.source), histories: [:], now: savedAt).connected,
                         relaySnapshot: .init(checkedAt: membershipAt, sources: sources, removed: removed))
        }
        let app = cache([snapshotSource("src-a", used: 10, at: now, provider: "grok"), snapshotSource("src-b", used: 20, at: now),
                         snapshotSource("src-c", used: 30, at: t1, provider: "cursor")], membershipAt: t1, savedAt: t1)
        let complication = cache([snapshotSource("src-b", used: 25, at: t2)], membershipAt: now, savedAt: t2, removed: ["src-a": t2])
        for merged in [app.mergingUpdate(complication, now: t2), complication.mergingUpdate(app, now: t2)] {
            XCTAssertNil(merged.localSource)
            XCTAssertEqual(merged.relaySnapshot?.sources.map(\.id), ["src-b", "src-c"])
            XCTAssertEqual(Set(merged.items.compactMap(\.sourceID)), ["src-b", "src-c"])
            XCTAssertEqual(merged.items.first { $0.sourceID == "src-b" }?.provider.windows.first?.used, 25)
        }
    }

    func testSnapshotsWithoutRemovalsStillDecode() throws {
        let data = Data(#"{"checkedAt":0,"sources":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ReadingCache.RelaySnapshot.self, from: data)
        XCTAssertNil(snapshot.removed)
    }

    func testCacheHistoriesAreKeyedByTheCollectorTheyCameFrom() {
        let week = UsageHistory(endingAt: now)
        var item = ReadingCache.Item(provider: envelope(used: 10, at: now).providers[0], source: "Mac")
        item.sourceID = "src-mac"
        item.history = ["weekly": week]
        let unattributed = ReadingCache.Item(provider: envelope(used: 10, at: now, provider: "grok").providers[0], source: "Mac",
                                             history: ["weekly": week])
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item, unattributed])
        XCTAssertEqual(Array(cache.historiesBySource.keys), ["src-mac"])
        XCTAssertEqual(cache.historiesBySource["src-mac"]?.series.keys.sorted(), [RelayHistory.key(provider: "claude", window: "weekly")])
    }


    func testReconcileTakesMembershipFromTheNewerReadAndEachCollectorAtItsNewestCopy() {
        let local = ReadingCache.SourceSnapshot(RelayMerge.Source(id: "src-phone", label: "This iPhone",
            envelope: RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: []), kind: .thisPhone))
        func cache(_ sources: [ReadingCache.SourceSnapshot], membershipAt: Date, savedAt: Date) -> ReadingCache {
            var cache = ReadingCache(savedAt: savedAt, isSample: false,
                                     items: ReadingAssembler.assemble(sources: sources.map(\.source), histories: [:], now: savedAt).connected,
                                     relaySnapshot: .init(checkedAt: membershipAt, sources: sources), localSource: local)
            cache.cloudReadAt = savedAt
            return cache
        }
        let app = cache([snapshotSource("src-mac", used: 10, at: now), snapshotSource("src-new", used: 50, at: now.addingTimeInterval(60))],
                        membershipAt: now.addingTimeInterval(60), savedAt: now.addingTimeInterval(60))
        let widget = cache([snapshotSource("src-mac", used: 70, at: now.addingTimeInterval(120))],
                           membershipAt: now, savedAt: now.addingTimeInterval(120))
        for merged in [app.mergingUpdate(widget, now: now.addingTimeInterval(130)), widget.mergingUpdate(app, now: now.addingTimeInterval(130))] {
            XCTAssertEqual(merged.relaySnapshot?.checkedAt, now.addingTimeInterval(60))
            XCTAssertEqual(merged.relaySnapshot?.sources.map(\.id).sorted(), ["src-mac", "src-new"], "The new collector stays")
            let mac = merged.relaySnapshot?.sources.first { $0.id == "src-mac" }
            XCTAssertEqual(mac?.envelope.providers.first?.windows.first?.used, 70, "The newer copy wins source by source")
            XCTAssertEqual(merged.items.first { $0.sourceID == "src-mac" }?.provider.windows.first?.used, 70)
        }
    }


    func testZoneArchiveRoundTripsForItsAccountOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RelayZoneArchive(url: directory.appendingPathComponent("zone.archive"))
        let record = CKRecord(recordType: CloudRelay.RecordType.source,
                              recordID: CKRecord.ID(recordName: "src-mac", zoneID: CloudRelay.zoneID))
        record[CloudRelay.Field.payload] = Data("{}".utf8)
        let quarantined = CKRecord.ID(recordName: "hist-src-mac", zoneID: CloudRelay.zoneID)
        archive.save(.init(records: [record.recordID: record], quarantined: [quarantined], token: nil, pass: [record.recordID]),
                     account: "account-a")

        let restored = try XCTUnwrap(archive.load(account: "account-a"))
        XCTAssertEqual(restored.records.keys.map(\.recordName), ["src-mac"])
        XCTAssertEqual(restored.records.values.first?[CloudRelay.Field.payload] as? Data, Data("{}".utf8))
        XCTAssertEqual(restored.quarantined, [quarantined])
        XCTAssertEqual(restored.pass, [record.recordID])
        XCTAssertNil(restored.token)

        XCTAssertNil(archive.load(account: "account-b"), "Another account's copy is never read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path), "and is deleted")

        archive.save(.init(records: [:], quarantined: [], token: nil, pass: nil), account: "account-a")
        archive.save(nil, account: "account-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.url.path))
    }

    func testZoneArchiveRejectsRecordsFromAnotherZone() {
        let record = CKRecord(recordType: "Source", recordID: CKRecord.ID(recordName: "x", zoneID: CKRecordZone.ID(zoneName: "Other")))
        let data = RelayZoneArchive.encode(.init(records: [record.recordID: record], quarantined: [], token: nil, pass: nil), account: "a")
        XCTAssertNotNil(data)
        XCTAssertNil(data.flatMap { RelayZoneArchive.decode($0, account: "a") })
    }

    func testExtensionsKeepNoSavedZone() {
        XCTAssertNotNil(RelayZoneArchive.defaultURL(containerIdentifier: "iCloud.test"))
        let appex = Bundle(url: FileManager.default.temporaryDirectory.appendingPathComponent("Widgets.appex"))
        if let appex {
            XCTAssertNil(RelayZoneArchive.defaultURL(containerIdentifier: "iCloud.test", bundle: appex))
        }
    }


    @MainActor
    func testFailedPruningWaitsItsOwnRetryAndNeverPausesSharing() async {
        let cloud = PruningCloud()
        cloud.pruneFailure = CKError(.networkFailure)
        let publisher = RelayPublisher(defaults: makeDefaults(), cloud: cloud)
        await publisher.pruneEventsIfDue(now: now)
        await publisher.pruneEventsIfDue(now: now.addingTimeInterval(300))
        XCTAssertEqual(cloud.prunes, 1, "A failed pruning isn't tried again every round")
        await publisher.publish(envelope(used: 10, at: now), now: now.addingTimeInterval(301))
        XCTAssertEqual(cloud.envelopes.count, 1, "Pruning's failure sets no retry for sharing")

        cloud.pruneFailure = nil
        await publisher.pruneEventsIfDue(now: now.addingTimeInterval(RelayPublisher.pruneRetry + 1))
        XCTAssertEqual(cloud.prunes, 2)
        await publisher.pruneEventsIfDue(now: now.addingTimeInterval(RelayPublisher.pruneRetry + 600))
        XCTAssertEqual(cloud.prunes, 2, "Once it succeeds, once a day")
    }

    @MainActor
    func testPruningThatNeverAnswersDoesNotHoldSharingOrTheNextCheck() async throws {
        let cloud = PruningCloud()
        cloud.holdsPrunes = true
        let publisher = RelayPublisher(defaults: makeDefaults(), cloud: cloud)
        let store = QuotaStore(settings: AppSettings(defaults: makeDefaults()), clients: [], cache: SnapshotCache(directory: temporaryDirectory()),
                               relay: publisher)
        let finished = expectation(description: "Sharing finished while pruning hangs")
        Task { @MainActor in
            await store.share()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNotNil(store.maintenance, "Pruning runs apart, after the round")
        store.willSleep()
        XCTAssertNil(store.maintenance)
        cloud.release()
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private final class PruningCloud: RelayCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var pruneCalls = 0
    private var failure: CKError?
    private var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var sent: [RelayEnvelope] = []

    var prunes: Int { lock.withLock { pruneCalls } }
    var envelopes: [RelayEnvelope] { lock.withLock { sent } }
    var pruneFailure: CKError? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }
    var holdsPrunes: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }

    func release() {
        let resumed = lock.withLock {
            holds = false
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }

    func accountStatus() async throws -> CKAccountStatus { .available }
    func accountFingerprint() async throws -> String { "test" }
    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws {
        lock.withLock { sent.append(envelope) }
    }
    func publishHistory(sourceID: String, history: RelayHistory) async throws {}
    func alertPreferences() async throws -> AlertPreferences? { nil }
    func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution {
        AlertPreferencesSync.Resolution(preferences: local, needsPublish: false)
    }
    func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date) async throws -> Bool { false }
    func saveAlert(_ alert: UsageAlert) async throws -> Bool { true }
    func pruneEvents(now: Date) async throws {
        let (holding, failure) = lock.withLock { () -> (Bool, CKError?) in
            pruneCalls += 1
            return (holds, self.failure)
        }
        if holding {
            await withCheckedContinuation { continuation in
                let now = lock.withLock {
                    guard holds else { return true }
                    waiting.append(continuation)
                    return false
                }
                if now { continuation.resume() }
            }
        }
        if let failure { throw failure }
    }
    func saveEvent(id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String) async throws {}
    func resetZone() async {}
}
