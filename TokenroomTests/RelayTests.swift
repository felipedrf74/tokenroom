import CloudKit
import Synchronization
import XCTest
@testable import Tokenroom

final class RelayTests: XCTestCase {
    private func envelope(used: Double = 42, checkedAt: Date = Date(timeIntervalSince1970: 1_000)) -> RelayEnvelope {
        RelayEnvelope(
            producer: "mac",
            appVersion: "2.0.0",
            checkedAt: checkedAt,
            providers: [
                RelayProvider(
                    id: "claude",
                    name: "Claude",
                    shortName: "Claude",
                    monogram: "C",
                    tint: "#D97757",
                    state: "live",
                    message: nil,
                    checkedAt: checkedAt,
                    fetchedAt: checkedAt,
                    plan: nil,
                    primaryWindowID: "weekly",
                    windows: [
                        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: Date(timeIntervalSince1970: 90_000)),
                        RelayWindow(id: "session", kind: "session", title: "Session", used: 12, resetsAt: nil),
                    ]
                ),
            ]
        )
    }

    func testEnvelopeRoundTripsWithEpochDates() throws {
        let original = envelope()
        let data = try original.encoded()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["checkedAt"] as? Double, 1_000, "Dates travel as epoch seconds")
        XCTAssertEqual(try RelayEnvelope.decode(data), original)
    }

    func testUnknownFieldsAreIgnored() throws {
        var object = try JSONSerialization.jsonObject(with: envelope().encoded()) as! [String: Any]
        object["futureTopLevel"] = ["x": 1]
        var providers = object["providers"] as! [[String: Any]]
        providers[0]["futureField"] = "y"
        var windows = providers[0]["windows"] as! [[String: Any]]
        windows[0]["kind"] = "someFutureKind"
        providers[0]["windows"] = windows
        object["providers"] = providers
        let decoded = try RelayEnvelope.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.providers.first?.windows.first?.kind, "someFutureKind")
        XCTAssertTrue(decoded.isReadable)
    }

    func testNewerFormatIsDetected() throws {
        var newer = envelope()
        newer.v = 7
        newer.minReader = 5
        let decoded = try RelayEnvelope.decode(newer.encoded())
        XCTAssertFalse(decoded.isReadable)
    }

    func testMaterialHashIgnoresCheckTimesButSeesUsage() {
        let base = envelope()
        XCTAssertEqual(base.materialHash, envelope(checkedAt: Date(timeIntervalSince1970: 5_000)).materialHash)
        XCTAssertEqual(base.materialHash, envelope(used: 42.3).materialHash, "Sub-percent noise isn't a change")
        XCTAssertNotEqual(base.materialHash, envelope(used: 43).materialHash)
    }

    func testPrimaryWindowFallsBackToFirst() {
        var provider = envelope().providers[0]
        XCTAssertEqual(provider.primaryWindow?.id, "weekly")
        provider.primaryWindowID = "missing"
        XCTAssertEqual(provider.primaryWindow?.id, "weekly")
    }

    @MainActor
    func testStoreEnvelopeHasEnabledProvidersAndNoIdentity() throws {
        // A fixed name: macOS keeps an empty preferences file for every name used.
        let suite = "tokenroom.tests.\(Self.self)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["claude", "grokBot"], forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = QuotaStore(
            settings: AppSettings(defaults: defaults),
            clients: [],
            cache: SnapshotCache(directory: folder)
        )
        let relayed = store.relayEnvelope(at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(Set(relayed.providers.map(\.id)), ["claude", "grokBot"])
        XCTAssertEqual(relayed.producer, "mac")

        let json = String(decoding: try relayed.encoded(), as: UTF8.self).lowercased()
        for forbidden in ["token", "email", "@", "user_id", "account", "/users/"] {
            XCTAssertFalse(json.contains(forbidden), "Relay payload must not contain \(forbidden)")
        }
    }

    // MARK: Tokenroom's data deleted in iCloud settings

    /// Deleted in iCloud settings and seen once: a later launch, which starts with nothing in
    /// memory, still knows, so its first save doesn't make the zone again. Only the user's own
    /// choice ends it.
    func testADeletedZoneIsRememberedAcrossLaunchesUntilTheUserStartsAgain() throws {
        let suite = "tokenroom.tests.\(Self.self).zone"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(RelayZoneDeletion(defaults: defaults).stands(for: "acct-a"))
        RelayZoneDeletion(defaults: defaults).mark(for: "acct-a")
        XCTAssertTrue(RelayZoneDeletion(defaults: defaults).stands(for: "acct-a"), "Saved on the device, not in memory")
        RelayZoneDeletion(defaults: defaults).clear()
        XCTAssertFalse(RelayZoneDeletion(defaults: defaults).isRecorded)

        XCTAssertTrue(RelayZoneDeletion.isUserDeletedZone(CKError(.userDeletedZone)))
        let record = CKRecord.ID(recordName: "src-mac", zoneID: CloudRelay.zoneID)
        let batch = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [record: CKError(.userDeletedZone)]])
        XCTAssertTrue(RelayZoneDeletion.isUserDeletedZone(batch), "One record of a batch says so")
        XCTAssertFalse(RelayZoneDeletion.isUserDeletedZone(CKError(.zoneNotFound)), "Never made, or deleted by Tokenroom itself")
        XCTAssertFalse(RelayZoneDeletion.isUserDeletedZone(URLError(.notConnectedToInternet)))
        guard case .paused = RelayErrorPolicy.outcome(for: CKError(.userDeletedZone), defaultRetry: 300) else {
            return XCTFail("A save refused for it pauses, with how to start again")
        }
    }

    /// A throwaway stand-in for a device's defaults.
    private func zoneDefaults(_ name: String) throws -> UserDefaults {
        let suite = "tokenroom.tests.\(Self.self).\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// The user deletes Tokenroom's data in iCloud settings and the iPhone, which has no keys and
    /// so never saves, sees it. Then, as its message says, the user turns the Mac's sync off and
    /// on: the zone is back with the Mac's readings. The iPhone's next read finds them, which ends
    /// the deletion there, so its push subscriptions go in again.
    func testAReadThatFindsTheZoneBackEndsTheDeletion() async throws {
        let deletion = RelayZoneDeletion(defaults: try zoneDefaults("read"))
        let deleted = try await deletion.read(account: { "acct-a" }, { () async throws -> [String: Int] in throw CKError(.userDeletedZone) })
        XCTAssertNil(deleted, "An empty read")
        XCTAssertTrue(deletion.stands(for: "acct-a"))

        let missing = try await deletion.read(account: { "acct-a" }, { [String: Int]() })
        XCTAssertEqual(missing, [:])
        XCTAssertTrue(deletion.stands(for: "acct-a"), "An empty read may be a zone still missing")

        let back = try await deletion.read(account: { "acct-a" }, { ["src-mac": 1] })
        XCTAssertEqual(back, ["src-mac": 1])
        XCTAssertFalse(deletion.isRecorded, "Records there: the zone is back, by the user's choice on the Mac")
    }

    /// Recorded under account A, then account B signs in on this device (it never used Tokenroom,
    /// so it has no zone). B's first save makes the zone as usual, rather than pausing with
    /// "Tokenroom's iCloud data was deleted"; A's deletion still holds for A.
    func testADeletionRecordedForAnotherAccountDoesntStand() async throws {
        let deletion = RelayZoneDeletion(defaults: try zoneDefaults("account"))
        let calls = Mutex<[String]>([])
        let zone = Mutex(false)
        func save(as account: String?) async throws {
            try await deletion.save(
                account: { account },
                ensureZone: { calls.withLock { $0.append("ensure") }; zone.withLock { $0 = true } },
                modify: {
                    calls.withLock { $0.append("modify") }
                    guard zone.withLock({ $0 }) else { throw CKError(.zoneNotFound) }
                },
                zoneBack: { calls.withLock { $0.append("back") } },
                zoneGone: { calls.withLock { $0.append("gone") } }
            )
        }

        deletion.mark(for: "acct-a")
        do {
            try await save(as: "acct-a")
            XCTFail("A's deletion holds for A")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .userDeletedZone)
        }
        XCTAssertEqual(calls.withLock { $0 }, ["modify"], "The zone isn't made again for A")

        calls.withLock { $0 = [] }
        try await save(as: "acct-b")
        XCTAssertEqual(calls.withLock { $0 }, ["ensure", "modify"], "B's zone is made as for any account")
        XCTAssertFalse(deletion.isRecorded, "Recorded for another account, so forgotten")

        deletion.mark(for: nil)
        XCTAssertTrue(deletion.stands(for: "acct-b"), "Recorded without knowing the account: it stands, to be safe")
        deletion.mark(for: "acct-a")
        XCTAssertTrue(deletion.stands(for: nil), "Nor when the account signed in can't be told")
    }

    /// After the user deletes Tokenroom's data in iCloud settings, the zone reads as empty: the
    /// Watch and complications drop what was deleted rather than keep showing it.
    func testAReadOfADeletedZoneEmptiesTheWatchsReadings() async throws {
        let now = Date(timeIntervalSince1970: 1_790_337_600)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        var provider = envelope().providers[0]
        provider.checkedAt = now.addingTimeInterval(-600)
        try ReadingCache(savedAt: now.addingTimeInterval(-600), isSample: false, items: [ReadingCache.Item(provider: provider, source: "Mac")]).save(to: url)

        let deleted = CloudRelay.Contents(sources: [], histories: [:], deletedByUser: true)
        XCTAssertFalse(CloudRelay.Contents(sources: [], histories: [:]).deletedByUser)
        let shown = await RelayReadings.cache(at: url, maxAge: 0, budget: 1, now: now, defaults: nil,
                                              readOutcome: { .readings(RelayReadings.cache(from: deleted, now: now)) })
        XCTAssertEqual(shown?.items.map(\.id), [], "Not the reading that was deleted")
        XCTAssertEqual(ReadingCache.load(from: url)?.items.map(\.id), [], "Nor the next time a complication draws")
    }
}
