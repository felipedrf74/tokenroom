import XCTest
@testable import Tokenroom

/// QA4 regression sources only: not compiled or executed in the no-tests fix pass.
@MainActor final class NewsFourthQAFixTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    private func defaults() -> UserDefaults {
        let name = "tokenroom.tests.news-qa4." + UUID().uuidString
        suites.append(name)
        let value = UserDefaults(suiteName: name)!
        value.set([], forKey: NewsStore.Keys.sources)
        value.set(FeedSource.catalog.map(\.id), forKey: NewsStore.Keys.knownSources)
        value.set([], forKey: NewsStore.Keys.vendors)
        value.set(Array(ModelFeed.defaultVendors), forKey: NewsStore.Keys.knownVendors)
        return value
    }
    private func bookmark(_ id: String, aliases: Set<String> = [], date: Double = 10) -> NewsBookmark {
        .init(id: id, aliases: aliases, kind: .story, title: id, publisher: "Publisher", url: nil,
              summary: nil, publishedAt: nil, updatedAt: nil, savedAt: Date(timeIntervalSince1970: date))
    }
    private func queuedPreferences(_ latest: AlertPreferences) async -> ([AlertPreferences], [TimeInterval?], [Set<String>]) {
        let probe = FourthQARefreshProbe()
        var notifications: [AlertPreferences] = []
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { await probe.fetch($0) },
                             notify: { _, preferences, _ in notifications.append(preferences) })
        let first = Task { await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: true, forcedSources: ["manual"])
        await news.refresh(maxAge: 900, preferences: latest, notifies: false)
        await probe.release(); await first.value
        return (notifications, await probe.ages, await probe.forcedSources)
    }
    func testSlowerCachedRequestUpdatesQueuedNewModelPreference() async {
        var latest = AlertPreferences(); latest.newModels = false
        let (notifications, ages, forced) = await queuedPreferences(latest)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(ages.count, 2); XCTAssertEqual(ages[1], 0)
        XCTAssertEqual(forced[1], ["manual"])
    }
    func testSlowerRequestKeepsQueuedNotificationIntentAndLatestQuietHours() async {
        var latest = AlertPreferences(); latest.quietHours = false
        let (notifications, ages, _) = await queuedPreferences(latest)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.quietHours, latest.quietHours)
        XCTAssertEqual(ages.count, 2)
    }
    func testSlowerRequestDoesNotReplaceQueuedPermission() async {
        let probe = FourthQARefreshProbe()
        let allowed = LockedBox(true)
        let news = NewsStore(defaults: defaults(), directory: nil, fetch: { await probe.fetch($0) }, notify: { _, _, _ in })
        let first = Task { await news.refresh(maxAge: 0, preferences: AlertPreferences(), notifies: false) }
        await probe.waitUntilStarted()
        await news.refresh(maxAge: 0, preferences: AlertPreferences(), isAllowed: { allowed.value })
        await news.refresh(maxAge: 900, preferences: AlertPreferences(), isAllowed: { true })
        allowed.value = false
        await probe.release(); await first.value
        let ages = await probe.ages
        XCTAssertEqual(ages.count, 1)
    }
    func testPairedEntryBridgingLinkAndTitleFoldsEveryGroupAndUnsaveCopy() throws {
        let primary = FeedSource(id: "primary", name: "Primary", url: URL(string: "https://example.com/feed")!)
        var sibling = FeedSource(id: "paired", name: "Paired", url: URL(string: "https://example.com/releases")!)
        sibling.partOf = primary.id
        let a = FeedItem(id: "a", title: "Patch details", link: URL(string: "https://example.com/alpha"), published: Date(timeIntervalSince1970: 30), source: primary.name)
        let b = FeedItem(id: "b", title: "Release details", link: URL(string: "https://example.com/beta"), published: Date(timeIntervalSince1970: 20), source: primary.name)
        let c = FeedItem(id: "c", title: "Patch details", link: b.link, published: Date(timeIntervalSince1970: 10), source: sibling.name)
        var cache = NewsCache(); cache.items = [primary.id: [a, b], sibling.id: [c]]
        let groups = cache.announcements(from: [primary, sibling], limit: .max)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.id, "a", "Keep the newest snapshot")
        XCTAssertEqual(group.newsDate, c.published, "Keep the earliest arrival")
        XCTAssertTrue(group.aliasIDs.isSuperset(of: ["primary|a", "primary|b", "paired|c"]))
        let library = NewsLibrary(directory: nil)
        XCTAssertTrue(library.save(bookmark("primary|a"))); XCTAssertTrue(library.save(bookmark("primary|b")))
        var undo = NewsRemovalUndo()
        XCTAssertTrue(undo.remove(id: group.stableID, aliases: group.aliasIDs, from: library))
        XCTAssertTrue(library.saved.isEmpty); XCTAssertEqual(undo.items.count, 2)
        XCTAssertTrue(undo.restore(in: library)); XCTAssertEqual(library.saved.count, 2)
        // Persist all identities onto the remaining raw item when the sibling rotates out.
        var next = NewsCache(); next.items = [primary.id: [a], sibling.id: []]
        next.retainFoldedIdentities(from: cache, sources: [primary, sibling])
        XCTAssertTrue(next.announcements(from: [primary, sibling]).first!.aliasIDs.isSuperset(of: group.aliasIDs))
    }
    func testFoldedRemovalAndUndoRestoreBothOriginalSnapshots() {
        let library = NewsLibrary(directory: nil)
        let a = bookmark("a", date: 10), b = bookmark("b", date: 20)
        XCTAssertTrue(library.save(a)); XCTAssertTrue(library.save(b))
        var undo = NewsRemovalUndo()
        XCTAssertTrue(undo.remove(id: "folded", aliases: ["a", "b"], from: library))
        XCTAssertFalse(library.isSaved(id: "folded", aliases: ["a", "b"]))
        XCTAssertEqual(Set(undo.items.map(\.id)), ["a", "b"])
        XCTAssertTrue(undo.restore(in: library))
        XCTAssertEqual(library.saved, [b, a]); XCTAssertNil(undo.item)
    }
    func testTransitiveRemovalRestoresExactSnapshotsWithoutFolding() {
        let library = NewsLibrary(directory: nil)
        let original = [bookmark("a", aliases: ["b"]), bookmark("b", aliases: ["c"], date: 20), bookmark("c", date: 30)]
        XCTAssertTrue(library.restore(original))
        let removed = library.remove(id: "a", aliases: [])
        XCTAssertEqual(removed, original); XCTAssertTrue(library.saved.isEmpty)
        XCTAssertTrue(library.restore(removed!))
        XCTAssertEqual(library.saved, Array(original.reversed()))
    }
    func testSaveBridgeConsolidatesSnapshotsAndKeepsOriginalSavedDate() {
        let library = NewsLibrary(directory: nil)
        let a = bookmark("a", date: 10), b = bookmark("b", date: 20)
        XCTAssertTrue(library.save(a)); XCTAssertTrue(library.save(b))
        XCTAssertTrue(library.save(bookmark("bridge", aliases: ["a", "b"], date: 99)))
        XCTAssertEqual(library.saved.count, 1); XCTAssertEqual(library.saved.first?.savedAt, a.savedAt)
        XCTAssertTrue(library.isSaved(id: "b")); XCTAssertTrue(library.isSaved(id: "bridge"))
    }
    func testGroupWriteFailuresPreserveLibraryAndPendingUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fails = false
        let library = NewsLibrary(directory: directory, writer: { _, _ in if fails { throw CocoaError(.fileWriteUnknown) } })
        let a = bookmark("a"), b = bookmark("b", date: 20), older = bookmark("older")
        XCTAssertTrue(library.restore([a, b, older]))
        var undo = NewsRemovalUndo(); XCTAssertTrue(undo.remove(id: "older", from: library))
        fails = true
        XCTAssertFalse(undo.remove(id: "folded", aliases: ["a", "b"], from: library))
        XCTAssertEqual(undo.items, [older]); XCTAssertEqual(library.saved, [b, a])
        XCTAssertFalse(undo.save(bookmark("bridge", aliases: ["a", "b"]), in: library))
        XCTAssertFalse(undo.restore(in: library)); XCTAssertEqual(undo.items, [older])
        XCTAssertEqual(library.saved, [b, a])
    }
    func testBatchRestoreConflictIsAtomicAndLeavesUndoAvailable() {
        let library = NewsLibrary(directory: nil)
        let a = bookmark("a"), b = bookmark("b", date: 20)
        XCTAssertTrue(library.restore([a, b]))
        var undo = NewsRemovalUndo(); XCTAssertTrue(undo.remove(id: "bridge", aliases: ["a", "b"], from: library))
        let replacement = bookmark("b", date: 99); XCTAssertTrue(library.save(replacement))
        XCTAssertFalse(undo.restore(in: library)); XCTAssertEqual(library.saved, [replacement])
        XCTAssertEqual(undo.items, [a, b])
    }
    func testAliasOverflowPreservesAllOriginalSnapshots() {
        let library = NewsLibrary(directory: nil)
        let a = bookmark("a", aliases: Set((0..<60).map { "a-\($0)" }))
        let b = bookmark("b", aliases: Set((0..<60).map { "b-\($0)" }), date: 20)
        XCTAssertTrue(library.restore([a, b]))
        XCTAssertFalse(library.save(bookmark("bridge", aliases: ["a", "b"])))
        XCTAssertEqual(library.saved, [b, a])
    }
    func testRestoreCapacityFailureKeepsGroupUndoAndFullLibrary() {
        let library = NewsLibrary(directory: nil)
        XCTAssertTrue(library.restore([bookmark("a"), bookmark("b")]))
        var undo = NewsRemovalUndo(); XCTAssertTrue(undo.remove(id: "group", aliases: ["a", "b"], from: library))
        XCTAssertTrue(library.restore((0..<500).map { bookmark("full-\($0)") }))
        XCTAssertFalse(undo.restore(in: library)); XCTAssertEqual(library.saved.count, 500)
        XCTAssertEqual(undo.items.count, 2)
        XCTAssertTrue(library.save(bookmark("merge", aliases: ["full-0", "full-1"])))
        XCTAssertEqual(library.saved.count, 499)
    }
    func testSourceSearchFiltersCompletePairedFamilyBeyondShelfCaps() throws {
        let parent = try XCTUnwrap(FeedSource.catalog.first { $0.id == "claude-code" })
        let family = NewsDiscovery.familyIDs(for: parent)
        let child = try XCTUnwrap(family.first { $0 != parent.id })
        var items = (0..<50).map { FeedItem(id: "item-\($0)", title: "Release \($0)", source: parent.name, sourceID: parent.id) }
        items.append(FeedItem(id: "target", title: "Needle release", source: "Paired", sourceID: child))
        items.append(FeedItem(id: "other", title: "Needle unrelated", source: "Other", sourceID: "other"))
        XCTAssertEqual(NewsDiscovery.stories(items, source: parent, query: "needle").map(\.id), ["target"])
        XCTAssertEqual(NewsDiscovery.stories(items, source: parent).count, 51)
        XCTAssertTrue(NewsDiscovery.stories(items, source: parent, query: "missing").isEmpty)
    }
    func testInertNewsFixtureRefreshDoesNotRewriteItsDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cache = NewsCache(); cache.modelsFetchedAt = Date(timeIntervalSince1970: 100)
        cache.save(to: directory)
        let file = directory.appendingPathComponent(NewsCache.fileName)
        let before = try Data(contentsOf: file)
        let launch = defaults(), preferences = defaults()
        launch.set(file.path, forKey: "TokenroomSnapshotNews")
        let news = NewsRuntime.newsStore(launchDefaults: launch, isUnitTestHost: false, inertDefaults: preferences)
        XCTAssertEqual(news.cache, cache)
        await news.refresh(maxAge: 0, preferences: AlertPreferences())
        XCTAssertEqual(try Data(contentsOf: file), before)
        news.followedVoices = ["profile-only"]
        XCTAssertEqual(preferences.stringArray(forKey: NewsStore.Keys.voices), ["profile-only"])
        XCTAssertNil(launch.object(forKey: NewsStore.Keys.voices))
    }
}

private actor FourthQARefreshProbe {
    var ages: [TimeInterval?] = []
    var forcedSources: [Set<String>] = []
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func fetch(_ request: NewsFetcher.Request) async -> NewsFetcher.Result {
        ages.append(request.maxAge); forcedSources.append(request.forcedSources)
        if ages.count == 1 {
            await withCheckedContinuation { continuation in blocked = continuation; started?.resume(); started = nil }
        }
        let model = ModelRelease(id: "lab/model", name: "Model", vendor: "lab", created: .now, contextLength: nil, promptPrice: nil, completionPrice: nil, expires: nil)
        return .init(cache: request.cache, newModels: ages.count > 1 ? [model] : [])
    }
    func waitUntilStarted() async { if !ages.isEmpty { return }; await withCheckedContinuation { started = $0 } }
    func release() { blocked?.resume(); blocked = nil }
}
