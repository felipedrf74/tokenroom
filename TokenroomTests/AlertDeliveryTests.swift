import CloudKit
import XCTest
@testable import Tokenroom

@MainActor final class AlertDeliveryTests: XCTestCase {
    func testResetRetainsTheEndedWindowKindForDeliveryIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = RelayWindow(id: "session", kind: "session", title: "Session", used: 90,
                              resetsAt: now.addingTimeInterval(-60), periodSec: 18_000)
        var current = old
        current.used = 2
        current.resetsAt = now.addingTimeInterval(18_000)
        func provider(_ window: RelayWindow) -> RelayProvider {
            RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#000000",
                          state: "live", checkedAt: now, fetchedAt: now, primaryWindowID: "session", windows: [window])
        }
        let reset = try XCTUnwrap(AlertRules.alerts(previous: provider(old), current: provider(current),
                                                  preferences: AlertPreferences(), now: now).first { $0.kind == .reset })
        XCTAssertEqual(reset.windowKind, "session", "A reset must retain its ended window identity, rather than adopt the next window")
        XCTAssertEqual(reset.identityResetAt, now.addingTimeInterval(-60))
        XCTAssertEqual(reset.resetsAt, now.addingTimeInterval(18_000), "Presentation still names the next reset")
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func alert(reset: Date, kind: UsageAlert.Kind = .threshold, level: Int = 80, windowKind: String = "session") -> UsageAlert {
        let bucket: TimeInterval = windowKind == "session" ? 600 : 3600
        let instance = String(Int((reset.timeIntervalSince1970 / bucket).rounded()) * Int(bucket / 600))
        let suffix = kind == .threshold ? String(level) : kind.rawValue
        return UsageAlert(id: "evt-claude-session-\(suffix)-\(instance)", provider: "claude", kind: kind, level: level,
                          title: "Usage", body: "Reading", resetsAt: reset, isUrgent: false, window: "session",
                          instance: instance, windowKind: windowKind)
    }
    private static func deliver(_ alert: UsageAlert, server: DeliveryServer, mode: AlertDeliveryCoordinator.Mode = .pushed,
                         at date: Date? = nil) async throws -> AlertDeliveryCoordinator.Receipt {
        let scope = try XCTUnwrap(AlertDeliveryCoordinator.scope(for: alert))
        return try await AlertDeliveryCoordinator.deliver(alert, scope: scope, mode: mode, now: date ?? Date(timeIntervalSince1970: 1_800_000_000),
            read: { try await server.read(scope.recordName) },
            legacy: { try await server.legacy($0) },
            write: { try await server.write($0, revision: $1, event: $2, alert: alert, scope: scope.recordName) },
            isConflict: { $0 is DeliveryServer.Conflict })
    }

    func testSimultaneousAdjacentBucketsCreateOneEvent() async throws {
        // 12:04:59 / 12:05:01 equivalent offsets around a 10-minute bucket boundary.
        let boundary = Date(timeIntervalSince1970: 1_800_004_500)
        let a = alert(reset: boundary.addingTimeInterval(-1))
        let b = alert(reset: boundary.addingTimeInterval(1))
        XCTAssertNotEqual(a.id, b.id, "Legacy names alone cannot coordinate this crossing")
        let server = DeliveryServer(barrier: true)
        async let left = Self.deliver(a, server: server, mode: .pushed)
        async let right = Self.deliver(b, server: server, mode: .shown)
        let receipts = try await [left, right]
        XCTAssertEqual(Set(receipts.map(\.eventID)).count, 1)
        XCTAssertEqual(receipts.filter(\.created).count, 1)
        XCTAssertEqual(receipts[0].mode, receipts[1].mode, "The losing phone must respect pushed/shown ownership")
        let count = await server.eventCount
        XCTAssertEqual(count, 1)
    }

    func testEitherWinningDeliveryModeSurvivesLaterCollectors() async throws {
        for mode in [AlertDeliveryCoordinator.Mode.pushed, .shown] {
            let server = DeliveryServer()
            let first = try await Self.deliver(alert(reset: now.addingTimeInterval(3600)), server: server, mode: mode)
            let later = try await Self.deliver(alert(reset: now.addingTimeInterval(3602)), server: server, mode: mode == .shown ? .pushed : .shown)
            XCTAssertTrue(first.created)
            XCTAssertFalse(later.created)
            XCTAssertEqual(later.mode, mode)
        }
    }

    func testLevelsRemainSeparateAndFixedAnchorDoesNotWalkWithJitter() async throws {
        let server = DeliveryServer()
        let first = try await Self.deliver(alert(reset: now.addingTimeInterval(3600)), server: server)
        let jitter = try await Self.deliver(alert(reset: now.addingTimeInterval(4800)), server: server)
        let next = try await Self.deliver(alert(reset: now.addingTimeInterval(6000)), server: server)
        let higher = try await Self.deliver(alert(reset: now.addingTimeInterval(3600), level: 95), server: server)
        XCTAssertEqual(first.eventID, jitter.eventID)
        XCTAssertNotEqual(first.eventID, next.eventID, "20-minute jitter cannot move the first anchor another 20 minutes")
        XCTAssertNotEqual(first.eventID, higher.eventID)
        let count = await server.eventCount
        XCTAssertEqual(count, 3)
    }

    func testResetCoordinationUsesEndedResetRatherThanNewPresentationReset() async throws {
        let server = DeliveryServer()
        var a = alert(reset: now.addingTimeInterval(-60), kind: .reset, level: 0)
        a.identityResetAt = a.resetsAt
        a.resetsAt = now.addingTimeInterval(18_000)
        var b = alert(reset: now.addingTimeInterval(-58), kind: .reset, level: 0)
        b.identityResetAt = b.resetsAt
        b.resetsAt = now.addingTimeInterval(36_000)
        let first = try await Self.deliver(a, server: server)
        let other = try await Self.deliver(b, server: server)
        XCTAssertEqual(first.eventID, other.eventID)
        XCTAssertFalse(other.created)
    }

    func testActiveMonthlyOwnershipSurvivesEventPruning() async throws {
        let server = DeliveryServer()
        let monthly = alert(reset: now.addingTimeInterval(29 * 86_400), windowKind: "monthly")
        let first = try await Self.deliver(monthly, server: server)
        await server.pruneEvents()
        let retry = try await Self.deliver(monthly, server: server, at: now.addingTimeInterval(20 * 86_400))
        XCTAssertEqual(first.eventID, retry.eventID)
        XCTAssertFalse(retry.created)
        let count = await server.eventCount
        XCTAssertEqual(count, 0, "Retained ownership must not recreate a pruned Event")
    }

    func testAdjacentLegacyEventIsAdoptedWithoutAnAliasOrRewrite() async throws {
        let server = DeliveryServer()
        let old = alert(reset: now.addingTimeInterval(299))
        let incoming = alert(reset: now.addingTimeInterval(301))
        await server.seed(old, mode: .shown)
        let adopted = try await Self.deliver(incoming, server: server)
        XCTAssertEqual(adopted.eventID, old.id)
        XCTAssertEqual(adopted.mode, .shown)
        XCTAssertFalse(adopted.created)
        let count = await server.eventCount
        let writes = await server.eventWrites
        XCTAssertEqual(count, 1)
        XCTAssertEqual(writes, 0)
    }

    func testUncertainCommittedResponseDoesNotCreateASecondEventOnRetry() async throws {
        let server = DeliveryServer(loseResponse: true)
        let value = alert(reset: now.addingTimeInterval(3600))
        do { _ = try await Self.deliver(value, server: server); XCTFail("The first response must be lost") } catch {}
        let retry = try await Self.deliver(value, server: server)
        XCTAssertFalse(retry.created)
        let count = await server.eventCount
        XCTAssertEqual(count, 1)
    }

    func testDelayedOldWindowDoesNotReplaceOwnershipOfTheNewWindow() async throws {
        let server = DeliveryServer()
        let old = try await Self.deliver(alert(reset: now.addingTimeInterval(3600)), server: server)
        let new = try await Self.deliver(alert(reset: now.addingTimeInterval(21_600)), server: server)
        let delayed = try await Self.deliver(alert(reset: now.addingTimeInterval(3602)), server: server)
        XCTAssertEqual(old.eventID, delayed.eventID)
        XCTAssertNotEqual(old.eventID, new.eventID)
        let count = await server.eventCount
        XCTAssertEqual(count, 2)
    }

    func testLegacyCustomSessionPeriodAdoptsAdjacentHourlyBucket() async throws {
        let server = DeliveryServer()
        let boundary = Date(timeIntervalSince1970: 1_800_005_400)
        var old = alert(reset: boundary.addingTimeInterval(-1), windowKind: "daily")
        var current = alert(reset: boundary.addingTimeInterval(1), windowKind: "daily")
        old.windowKind = "session"; current.windowKind = "session"
        old.identityPeriodSec = 86_400; current.identityPeriodSec = 86_400
        XCTAssertNotEqual(old.id, current.id)
        await server.seed(old, mode: .pushed)
        let receipt = try await Self.deliver(current, server: server)
        XCTAssertEqual(receipt.eventID, old.id, "Reported period takes precedence over kind for old reset buckets")
        XCTAssertFalse(receipt.created)
        let count = await server.eventCount
        XCTAssertEqual(count, 1)
    }

    func testDamageUnknownVersionAndExhaustedConflictsLeaveNoEvent() async throws {
        for data in [Data("broken".utf8), Data(#"{"version":2,"entries":[]}"#.utf8)] {
            let server = DeliveryServer(seedData: data)
            do { _ = try await Self.deliver(alert(reset: now), server: server); XCTFail("Damaged ownership must fail closed") } catch {}
            let count = await server.eventCount
            XCTAssertEqual(count, 0)
        }
        let server = DeliveryServer(alwaysConflict: true)
        do { _ = try await Self.deliver(alert(reset: now), server: server); XCTFail("Conflicts must remain pending") } catch {}
        let attempts = await server.writeAttempts
        let count = await server.eventCount
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(count, 0)
    }

    func testCancelledReadCannotCreateOwnershipOrEvent() async throws {
        let server = DeliveryServer(barrier: true)
        let value = alert(reset: now)
        let operation = Task { try await Self.deliver(value, server: server) }
        while await server.readCount == 0 { await Task.yield() }
        operation.cancel()
        await server.releaseBarrier()
        do { _ = try await operation.value; XCTFail("Cancelled claim must not write") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let count = await server.eventCount
        XCTAssertEqual(count, 0)
    }

    func testNilResetBalancesAndBankedAlertsKeepLegacyPath() {
        var value = alert(reset: now)
        value.resetsAt = nil
        XCTAssertNil(AlertDeliveryCoordinator.scope(for: value))
        value.kind = .lowBalance
        XCTAssertNil(AlertDeliveryCoordinator.scope(for: value))
        value.resetsAt = now
        value.kind = .bankedNew
        XCTAssertNil(AlertDeliveryCoordinator.scope(for: value))
    }

    func testAtomicSiblingFailureCannotHideTheRevisionConflict() {
        let conflict = CKError(.serverRecordChanged)
        let sibling = CKError(.batchRequestFailed)
        for failures: [Result<CKRecord, any Error>] in [[.failure(sibling), .failure(conflict)], [.failure(conflict), .failure(sibling)]] {
            let error = CloudRelay.prioritizedSaveFailure(failures)
            XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged)
        }
        let nested = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["record": conflict]])
        let error = CloudRelay.prioritizedSaveFailure([.failure(sibling), .failure(nested)])
        XCTAssertTrue(error.map(CloudRelay.isPreferenceConflict) == true)
    }

    func testResetBoundBudgetBoundaryCoordinatesLowBalanceOnce() async throws {
        let server = DeliveryServer(barrier: true)
        let boundary = Date(timeIntervalSince1970: 1_800_005_400)
        let a = alert(reset: boundary.addingTimeInterval(-1), kind: .lowBalance, windowKind: "monthly")
        let b = alert(reset: boundary.addingTimeInterval(1), kind: .lowBalance, windowKind: "monthly")
        XCTAssertNotEqual(a.id, b.id)
        async let first = Self.deliver(a, server: server)
        async let second = Self.deliver(b, server: server, mode: .shown)
        let receipts = try await [first, second]
        XCTAssertEqual(Set(receipts.map(\.eventID)).count, 1)
        let count = await server.eventCount
        XCTAssertEqual(count, 1)
    }
}

/// Only the external atomic record database is replaced; production coordination is exercised.
private actor DeliveryServer {
    struct Conflict: Error {}
    struct LostResponse: Error {}
    struct Revision: Sendable { var name: String; var number: Int }
    private var documents: [String: (Data, Int)] = [:]
    private var events: [String: AlertDeliveryCoordinator.LegacyEvent] = [:]
    private var seedData: Data?
    private var barrier: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private var loseResponse: Bool
    private var alwaysConflict: Bool
    private(set) var readCount = 0
    private(set) var writeAttempts = 0
    private(set) var eventWrites = 0
    var eventCount: Int { events.count }
    init(barrier: Bool = false, loseResponse: Bool = false, seedData: Data? = nil, alwaysConflict: Bool = false) {
        self.barrier = barrier; self.loseResponse = loseResponse; self.seedData = seedData; self.alwaysConflict = alwaysConflict
    }
    func read(_ name: String) async throws -> AlertDeliveryCoordinator.Versioned<Revision> {
        let snapshot = AlertDeliveryCoordinator.Versioned(data: documents[name]?.0 ?? seedData,
                                                         revision: Revision(name: name, number: documents[name]?.1 ?? 0))
        readCount += 1
        if barrier && readCount == 1 { await withCheckedContinuation { waiter = $0 } }
        else if barrier { releaseBarrier() }
        return snapshot
    }
    func releaseBarrier() { barrier = false; waiter?.resume(); waiter = nil }
    func legacy(_ ids: [String]) -> [AlertDeliveryCoordinator.LegacyEvent] { ids.compactMap { events[$0] } }
    func seed(_ alert: UsageAlert, mode: AlertDeliveryCoordinator.Mode) {
        events[alert.id] = .init(id: alert.id, provider: alert.provider, kind: alert.kind.rawValue, level: alert.level,
                               key: mode == .shown ? alert.shownKey : alert.key, resetsAt: alert.resetsAt)
    }
    func pruneEvents() { events = [:] }
    func write(_ data: Data, revision: Revision, event: AlertDeliveryCoordinator.Receipt?, alert: UsageAlert, scope: String) throws {
        writeAttempts += 1
        guard !alwaysConflict, revision.name == scope, revision.number == (documents[scope]?.1 ?? 0),
              event.map({ events[$0.eventID] == nil }) ?? true else { throw Conflict() }
        documents[scope] = (data, revision.number + 1)
        if let event { seed(alert, mode: event.mode); eventWrites += 1 }
        if loseResponse { loseResponse = false; throw LostResponse() }
    }
}
