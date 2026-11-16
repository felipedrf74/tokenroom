import CloudKit
import XCTest
@testable import Tokenroom

final class RelayDirectReadTests: XCTestCase {
    private typealias Answers = [String: Result<String?, any Error>]
    private enum Failure: Error { case unavailable, rejected }

    private actor Cloud {
        var discovered: Result<Set<String>, any Error>
        var records: Answers
        var fetches: [[String]] = []

        init(discovered: Result<Set<String>, any Error>, records: Answers) {
            self.discovered = discovered
            self.records = records
        }

        func discover() throws -> Set<String> {
            try discovered.get()
        }

        func fetch(_ names: [String]) -> Answers {
            fetches.append(names)
            return Dictionary(uniqueKeysWithValues: names.compactMap { name in records[name].map { (name, $0) } })
        }
    }

    private func read(_ cloud: Cloud, known: Set<String>) async throws -> [String] {
        try await RelayDirectRead.records(
            known: known,
            companions: { ["hist-" + $0] },
            always: ["prefs"],
            discover: { try await cloud.discover() },
            fetch: { await cloud.fetch($0) }
        )
    }

    func testFirstReadFindsEveryCollectorWithoutKnowingAny() async throws {
        let cloud = Cloud(discovered: .success(["mac", "phone"]), records: [
            "mac": .success("mac"), "hist-mac": .success("mac week"),
            "phone": .success("phone"), "hist-phone": .success(nil),
            "prefs": .success(nil),
        ])
        let records = try await read(cloud, known: [])
        let fetches = await cloud.fetches
        XCTAssertEqual(records, ["mac", "phone", "mac week"])
        XCTAssertEqual(fetches, [["prefs"], ["mac", "phone", "hist-mac", "hist-phone"]])
    }

    func testKnownCollectorsNeedOneFetchAndNewOnesASecond() async throws {
        let cloud = Cloud(discovered: .success(["mac", "new"]), records: [
            "mac": .success("mac"), "hist-mac": .success("mac week"),
            "new": .success("new"), "hist-new": .success("new week"),
            "prefs": .success("choices"),
        ])
        let records = try await read(cloud, known: ["mac"])
        let fetches = await cloud.fetches
        XCTAssertEqual(records, ["mac", "new", "mac week", "new week", "choices"])
        XCTAssertEqual(fetches, [["mac", "hist-mac", "prefs"], ["new", "hist-new"]])

        let settled = Cloud(discovered: .success(["mac"]), records: ["mac": .success("mac"), "hist-mac": .success(nil), "prefs": .success(nil)])
        _ = try await read(settled, known: ["mac"])
        let once = await settled.fetches
        XCTAssertEqual(once.count, 1, "Nothing new: the first request already holds every record")
    }

    func testCollectorTheQueryLeavesOutStaysWhileItsRecordIsThere() async throws {
        let cloud = Cloud(discovered: .success([]), records: [
            "mac": .success("mac"), "hist-mac": .success(nil), "prefs": .success(nil),
        ])
        let records = try await read(cloud, known: ["mac"])
        XCTAssertEqual(records, ["mac"], "An index that lags behind a save must not remove a collector")
    }

    func testCollectorIsGoneOnlyWhenItsRecordIsConfirmedMissing() async throws {
        let cloud = Cloud(discovered: .success(["mac", "gone"]), records: [
            "mac": .success("mac"), "hist-mac": .success(nil),
            "gone": .success(nil), "hist-gone": .success(nil),
            "prefs": .success(nil),
        ])
        let records = try await read(cloud, known: ["mac", "gone"])
        XCTAssertEqual(records, ["mac"])
    }

    func testRecordThatCouldNotBeReadFailsTheWholeRead() async {
        let cloud = Cloud(discovered: .success(["mac", "phone"]), records: [
            "mac": .success("mac"), "hist-mac": .success(nil),
            "phone": .failure(Failure.rejected), "hist-phone": .success(nil),
            "prefs": .success(nil),
        ])
        do {
            _ = try await read(cloud, known: ["mac", "phone"])
            XCTFail("A collector neither read nor confirmed missing must not be dropped from a complete read")
        } catch {
            XCTAssertEqual(error as? Failure, .rejected)
        }
    }

    func testNameWithoutAnAnswerFailsTheWholeRead() async {
        let cloud = Cloud(discovered: .success(["mac"]), records: ["mac": .success("mac"), "prefs": .success(nil)])
        do {
            _ = try await read(cloud, known: ["mac"])
            XCTFail("The history request went unanswered")
        } catch {
            XCTAssertEqual(error as? RelayDirectRead.Incomplete, .init(name: "hist-mac"))
        }
    }

    func testDiscoveryFailureFailsTheReadEvenWhenRecordsAnswered() async {
        let cloud = Cloud(discovered: .failure(Failure.unavailable), records: [
            "mac": .success("mac"), "hist-mac": .success(nil), "prefs": .success(nil),
        ])
        do {
            _ = try await read(cloud, known: ["mac"])
            XCTFail("Without the query, membership isn't complete")
        } catch {
            XCTAssertEqual(error as? Failure, .unavailable)
        }
    }

    func testQueryThatTheSchemaRefusesFallsBackToTheZoneRead() {
        XCTAssertTrue(CloudRelay.isQueryUnsupported(CKError(.invalidArguments)))
        XCTAssertTrue(CloudRelay.isQueryUnsupported(CKError(.serverRejectedRequest)))
        XCTAssertFalse(CloudRelay.isQueryUnsupported(CKError(.networkUnavailable)))
        XCTAssertFalse(CloudRelay.isQueryUnsupported(CKError(.requestRateLimited)))
        XCTAssertFalse(CloudRelay.isQueryUnsupported(Failure.unavailable))
    }
}
