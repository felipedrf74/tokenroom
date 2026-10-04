import XCTest
@testable import Tokenroom

/// The account fence must work independently of replacing or deleting the shared cache file.
final class PhoneCacheAccessTests: XCTestCase {
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        suites = []
        folders = []
        super.tearDown()
    }

    private func storage() throws -> (defaults: UserDefaults, url: URL) {
        let suite = "tokenroom.tests.phone-cache-access.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return (defaults, folder.appendingPathComponent(ReadingCache.fileName))
    }

    private func cache(generation: String? = nil) -> ReadingCache {
        let checked = Date(timeIntervalSince1970: 1_790_337_600)
        let provider = RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
                                     state: "live", checkedAt: checked, primaryWindowID: "weekly",
                                     windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: 42)])
        return ReadingCache(savedAt: checked, isSample: false, items: [.init(provider: provider, source: "Mac")], accountGeneration: generation)
    }

    func testOldFileIsRejectedWhenTheFileCannotBeCleared() throws {
        let storage = try storage()
        let old = cache()
        try old.save(to: storage.url)
        PhoneCacheAccess.invalidate(in: storage.defaults)

        // Leave the file untouched, as when deleting or replacing it fails. The durable fence
        // must reject it without depending on the clearing operation succeeding.
        XCTAssertEqual(ReadingCache.load(from: storage.url), old)
        XCTAssertNil(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))
    }

    func testLateWriterCannotReplaceTheNewAccountCache() throws {
        let storage = try storage()
        let oldGeneration = PhoneCacheAccess.generation(in: storage.defaults)
        let oldResult = cache(generation: oldGeneration)
        PhoneCacheAccess.invalidate(in: storage.defaults)
        let newGeneration = try XCTUnwrap(PhoneCacheAccess.generation(in: storage.defaults))
        var current = cache()
        current.savedAt = current.savedAt.addingTimeInterval(60)
        XCTAssertTrue(try PhoneCacheAccess.save(current, at: storage.url, defaults: storage.defaults, generation: newGeneration))
        let before = try Data(contentsOf: storage.url)

        XCTAssertFalse(try PhoneCacheAccess.save(oldResult, at: storage.url, defaults: storage.defaults, generation: oldGeneration))
        XCTAssertEqual(try Data(contentsOf: storage.url), before, "A superseded writer must not replace the current file")
        XCTAssertEqual(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults)?.savedAt, current.savedAt)
    }

    func testSuccessfulWriterStampsAndLoadsTheCurrentGeneration() throws {
        let storage = try storage()
        PhoneCacheAccess.invalidate(in: storage.defaults)
        let generation = try XCTUnwrap(PhoneCacheAccess.generation(in: storage.defaults))
        var result = cache()
        result.localSource = ReadingCache.SourceSnapshot(RelayMerge.Source(
            id: "phone-source", label: "This iPhone",
            envelope: RelayEnvelope(producer: "iphone", appVersion: "", checkedAt: result.savedAt, providers: []),
            kind: .thisPhone
        ))

        XCTAssertTrue(try PhoneCacheAccess.save(result, at: storage.url, defaults: storage.defaults, generation: generation))
        let saved = try XCTUnwrap(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))
        XCTAssertEqual(saved.accountGeneration, generation)
        XCTAssertEqual(saved.localSource?.accountGeneration, generation,
                       "The paired source retains its account fence after merging with a cloud cache")
        XCTAssertEqual(saved.items, result.items)
        XCTAssertEqual(saved.savedAt, result.savedAt)
    }

    func testLegacyNilGenerationIsCompatibleUntilAnAccountChange() throws {
        let storage = try storage()
        let legacy = cache()
        try legacy.save(to: storage.url)

        XCTAssertNil(PhoneCacheAccess.generation(in: storage.defaults))
        XCTAssertEqual(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults), legacy)
        XCTAssertTrue(try PhoneCacheAccess.save(legacy, at: storage.url, defaults: storage.defaults, generation: nil))
        PhoneCacheAccess.invalidate(in: storage.defaults)
        XCTAssertFalse(PhoneCacheAccess.accepts(legacy, defaults: storage.defaults))
        XCTAssertNil(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))
    }

    func testInvalidationRejectsAnAlreadyWrittenResultAndALateDiskWrite() throws {
        let storage = try storage()
        PhoneCacheAccess.invalidate(in: storage.defaults)
        let oldGeneration = try XCTUnwrap(PhoneCacheAccess.generation(in: storage.defaults))
        let old = cache(generation: oldGeneration)
        XCTAssertTrue(try PhoneCacheAccess.save(old, at: storage.url, defaults: storage.defaults, generation: oldGeneration))
        XCTAssertNotNil(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))

        PhoneCacheAccess.invalidate(in: storage.defaults)
        XCTAssertNil(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))
        // A write that had passed its preflight before the change may finish afterward. Its
        // stamped generation still quarantines the result, even with a freshly written file.
        try old.save(to: storage.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.url.path))
        XCTAssertNil(PhoneCacheAccess.load(at: storage.url, defaults: storage.defaults))
    }
}
