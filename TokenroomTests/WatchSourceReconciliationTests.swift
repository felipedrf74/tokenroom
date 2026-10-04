import XCTest
@testable import Tokenroom

final class WatchSourceReconciliationTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_790_337_600)

    private func source(_ id: String, providers: [String], at date: Date, kind: CollectorKind = .mac) -> RelayMerge.Source {
        let readings = providers.map { id in
            let window = RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 40,
                                     resetsAt: now.addingTimeInterval(86_400), periodSec: 7 * 86_400)
            return RelayProvider(id: id, name: id, shortName: id, monogram: "X", tint: "#000000",
                                 state: "live", checkedAt: date, primaryWindowID: window.id, windows: [window])
        }
        return .init(id: id, label: kind == .thisPhone ? "This iPhone" : "Mac", envelope:
                        .init(producer: kind == .mac ? "mac" : "iphone", appVersion: "1", checkedAt: date, providers: readings), kind: kind)
    }

    private func phone(_ source: RelayMerge.Source, savedAt date: Date, other: [RelayMerge.Source] = [], generation: String = "generation-current") -> ReadingCache {
        var local = ReadingCache.SourceSnapshot(source)
        local.accountGeneration = generation
        return .init(savedAt: date, isSample: false,
                     items: ReadingAssembler.assemble(sources: [source] + other, histories: [:], now: date).connected,
                     accountGeneration: generation, localSource: local)
    }

    private func cloud(_ sources: [RelayMerge.Source], at date: Date) -> ReadingCache {
        .init(savedAt: date, isSample: false,
              items: ReadingAssembler.assemble(sources: sources, histories: [:], now: date).connected,
              relaySnapshot: .init(checkedAt: date, sources: sources.map(ReadingCache.SourceSnapshot.init)))
    }

    func testUnpublishedPhoneSourceSurvivesNewerWholeCloudReadInEitherOrder() {
        let local = source("paired", providers: ["phone-only"], at: now, kind: .thisPhone)
        let handover = phone(local, savedAt: now)
        let relay = cloud([], at: now.addingTimeInterval(60))
        for result in [handover.mergingUpdate(relay), relay.mergingUpdate(handover)] {
            XCTAssertEqual(result.items.map(\.id), ["phone-only"])
            XCTAssertEqual(result.items.first?.provider.checkedAt, now)
            XCTAssertEqual(result.localSource?.accountGeneration, "generation-current")
        }
    }

    func testNewerPhoneRemovalIsNotUndoneByOlderCloudSourceInLaterRead() {
        let old = source("paired", providers: ["removed"], at: now, kind: .thisPhone)
        let removal = source("paired", providers: [], at: now.addingTimeInterval(30), kind: .thisPhone)
        let removed = phone(removal, savedAt: now.addingTimeInterval(30))
        let laterRead = cloud([old], at: now.addingTimeInterval(60))
        XCTAssertTrue(removed.mergingUpdate(laterRead).items.isEmpty)
        XCTAssertTrue(laterRead.mergingUpdate(removed).items.isEmpty)
    }

    func testNewerPublishedRemovalRejectsDelayedPhoneSourceDespiteNewCacheDate() {
        let old = source("paired", providers: ["removed"], at: now, kind: .thisPhone)
        let removal = source("paired", providers: [], at: now.addingTimeInterval(30), kind: .otherPhone)
        let publishedRemoval = cloud([removal], at: now.addingTimeInterval(60))
        let delayed = phone(old, savedAt: now.addingTimeInterval(90))
        XCTAssertTrue(publishedRemoval.mergingUpdate(delayed).items.isEmpty)
    }

    func testUnrelatedSourceDeletionKeepsCloudAuthorityWhilePhoneSourceSurvives() {
        let local = source("paired", providers: ["local"], at: now, kind: .thisPhone)
        let deleted = source("deleted-mac", providers: ["deleted"], at: now)
        let handover = phone(local, savedAt: now, other: [deleted])
        let retained = source("retained-mac", providers: ["retained"], at: now.addingTimeInterval(30))
        let result = handover.mergingUpdate(cloud([retained], at: now.addingTimeInterval(60)))
        XCTAssertEqual(Set(result.items.map(\.id)), ["local", "retained"])
        XCTAssertFalse(result.items.contains { $0.id == "deleted" })
    }

    func testLegacyCacheDecodeAndMembershipBehaviorRemain() throws {
        let old = ReadingCache(savedAt: now, isSample: false,
                               items: ReadingAssembler.assemble(sources: [source("mac", providers: ["old"], at: now)], histories: [:], now: now).connected)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: RelayEnvelope.encoder.encode(old)) as? [String: Any])
        var items = try XCTUnwrap(json["items"] as? [[String: Any]])
        for index in items.indices {
            items[index].removeValue(forKey: "sourceID")
        }
        json["items"] = items
        json.removeValue(forKey: "accountGeneration")
        json.removeValue(forKey: "localSource")
        json.removeValue(forKey: "relaySnapshot")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try RelayEnvelope.decoder.decode(ReadingCache.self, from: data)
        XCTAssertNil(decoded.localSource)
        XCTAssertNil(decoded.relaySnapshot)
        XCTAssertNil(decoded.accountGeneration)
        XCTAssertNil(decoded.items.first?.sourceID)
        XCTAssertTrue(decoded.mergingUpdate(ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: [])).items.isEmpty)
        XCTAssertTrue(ReadingCache(savedAt: now.addingTimeInterval(10), isSample: false, items: []).mergingUpdate(decoded).items.isEmpty)
    }

    func testOptionalSnapshotFieldsDecodeWithoutKindOrGeneration() throws {
        let handover = phone(source("paired", providers: ["local"], at: now, kind: .thisPhone), savedAt: now)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: RelayEnvelope.encoder.encode(handover)) as? [String: Any])
        var local = try XCTUnwrap(json["localSource"] as? [String: Any])
        local.removeValue(forKey: "kind")
        local.removeValue(forKey: "accountGeneration")
        json["localSource"] = local
        let decoded = try RelayEnvelope.decoder.decode(ReadingCache.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.localSource?.kind)
        XCTAssertNil(decoded.localSource?.accountGeneration)
        let merged = decoded.mergingUpdate(cloud([], at: now.addingTimeInterval(60)))
        XCTAssertEqual(merged.items.map(\.id), ["local"])
        XCTAssertEqual(merged.localSource?.accountGeneration, "generation-current")
        let updated = phone(source("paired", providers: ["updated"], at: now.addingTimeInterval(30), kind: .thisPhone),
                            savedAt: now.addingTimeInterval(30))
        XCTAssertEqual(merged.mergingUpdate(updated).items.map(\.id), ["updated"])
    }

    func testNewPhoneCheckReplacesOnlyItsOlderPublishedSource() {
        let old = source("paired", providers: ["local"], at: now, kind: .otherPhone)
        var fresh = source("paired", providers: ["local"], at: now.addingTimeInterval(30), kind: .thisPhone)
        fresh.envelope.providers[0].windows[0].used = 70
        let unrelated = source("mac", providers: ["unrelated"], at: now.addingTimeInterval(20))
        let result = cloud([old, unrelated], at: now.addingTimeInterval(60))
            .mergingUpdate(phone(fresh, savedAt: now.addingTimeInterval(30)))
        XCTAssertEqual(Set(result.items.map(\.id)), ["local", "unrelated"])
        XCTAssertEqual(result.items.first { $0.id == "local" }?.provider.primaryWindow?.used, 70)
        XCTAssertEqual(result.items.first { $0.id == "local" }?.provider.checkedAt, now.addingTimeInterval(30))
        XCTAssertEqual(result.items.first { $0.id == "local" }?.sourceID, "paired")
    }

    func testCompleteCloudSnapshotsWithoutPhoneMetadataKeepDeletionPolicy() {
        let first = cloud([source("mac", providers: ["removed"], at: now)], at: now)
        let removed = cloud([], at: now.addingTimeInterval(60))
        XCTAssertTrue(first.mergingUpdate(removed).items.isEmpty)
        XCTAssertTrue(removed.mergingUpdate(first).items.isEmpty)
    }

    func testDifferentPhoneGenerationDoesNotInheritPreviousCloudMembership() {
        let old = phone(source("paired", providers: ["old-local"], at: now, kind: .thisPhone), savedAt: now, generation: "old-generation")
            .mergingUpdate(cloud([source("old-mac", providers: ["old-cloud"], at: now)], at: now.addingTimeInterval(10)))
        let current = phone(source("paired", providers: ["new-local"], at: now.addingTimeInterval(20), kind: .thisPhone),
                            savedAt: now.addingTimeInterval(20), generation: "new-generation")
        let changed = old.mergingUpdate(current)
        XCTAssertEqual(changed.items.map(\.id), ["new-local"])
        XCTAssertNil(changed.relaySnapshot)
        XCTAssertEqual(changed.localSource?.accountGeneration, "new-generation")
        XCTAssertEqual(changed.mergingUpdate(old), changed, "A delayed previous-generation cache cannot reopen its membership")
    }

    func testWinningCollectorHistoryIsKeptWithReconciledReading() {
        let local = source("paired", providers: ["local"], at: now, kind: .thisPhone)
        var handover = phone(local, savedAt: now)
        var week = UsageHistory(endingAt: now)
        week.record(40, at: now)
        handover.items[0].history = ["weekly": week]
        let result = handover.mergingUpdate(cloud([], at: now.addingTimeInterval(60)))
        XCTAssertEqual(result.items.first?.history["weekly"], week)
    }
}
