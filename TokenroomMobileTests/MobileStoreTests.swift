import SwiftUI
import Security
import Synchronization
import UserNotifications
import XCTest
@testable import TokenroomMobile

/// What only the iPhone app does: its store, and the state it shares with its widgets. Shared
/// logic is tested on the Mac in TokenroomTests.
final class MobileStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_337_600) // 2026-09-25 12:00 UTC
    private var suites: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites = []
        folders = []
        super.tearDown()
    }

    /// A throwaway stand-in for the App Group's defaults, named by the class and a count so runs
    /// reuse a few preferences files instead of leaving one behind per test.
    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    /// A complete store pass with no iCloud, in-memory missing credentials, isolated storage
    /// and inert device SDK effects. Refresh/cache/alert logic still executes.
    @MainActor
    private func makeStore(defaults: UserDefaults, folder: URL) -> MobileStore {
        MobileStore(
            defaults: defaults,
            containerIdentifier: nil,
            keys: MobileFixtureKeychain().keys,
            directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in XCTFail("This fixture must not schedule a real notification") },
            platformEffects: .inert, launchDefaults: defaults,
            // Never this device's real plan sign-ins.
            sessions: nil
        )
    }

    // MARK: Store

    @MainActor
    func testInertPlatformAdapterPreservesRefreshPersistenceAndMockAlertDelivery() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let keychain = MobileFixtureKeychain()
        let schedules = Mutex(0)
        let store = MobileStore(defaults: defaults, containerIdentifier: nil, keys: keychain.keys,
            directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in schedules.withLock { $0 += 1 } },
            platformEffects: .inert, launchDefaults: defaults)
        XCTAssertTrue(store.allowsExternalEffects, "Explicit store tests execute collection and persistence")

        await store.refresh(force: true, now: now)
        XCTAssertEqual(store.lastRefresh, now)
        XCTAssertEqual(keychain.copyCount, Provider.allCases.filter(\.readsWithKey).count,
                       "The real refresh pass checks every provider through the injected missing-item Keychain")
        let saved = try XCTUnwrap(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName)))
        XCTAssertEqual(saved.savedAt, now)
        XCTAssertTrue(saved.items.isEmpty)
        XCTAssertFalse(saved.isSample)

        let alert = UsageAlert(id: "isolated-platform-delivery", provider: "openrouter", kind: .threshold,
            level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        let accepted = await store.deliverAlerts([alert], now: now)
        XCTAssertEqual(accepted, [alert.id])
        XCTAssertEqual(schedules.withLock { $0 }, 1)
        XCTAssertEqual(AlertLedger.load(from: folder).sent[alert.id], now,
                       "A mocked accepted delivery still writes the real isolated acknowledgement")
        await store.scheduleBackgroundRefresh(now: now)
    }

    @MainActor
    func testPlatformEffectsRouteThroughInjectedHandlersWithoutDisablingRefresh() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let calls = Mutex<[String]>([])
        let effects = MobilePlatformEffects(
            setWatchConnectAvailable: { value in calls.withLock { $0.append("connect:\(value)") } },
            sendToWatch: { _ in calls.withLock { $0.append("watch") } },
            reloadWidgets: { calls.withLock { $0.append("widgets") } },
            applicationIsBackground: { calls.withLock { $0.append("application-state") }; return false },
            updateLiveActivities: { _, _, _, _ in calls.withLock { $0.append("activities") } },
            makeKeyFetchGate: { defaults in
                calls.withLock { $0.append("gate") }
                return KeyFetchGate(defaults: defaults, lockDirectory: nil)
            },
            scheduleBackgroundRefresh: { _ in calls.withLock { $0.append("background") } }
        )
        let store = MobileStore(defaults: defaults, containerIdentifier: nil, keys: MobileFixtureKeychain().keys,
            directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in XCTFail("No alert exists in this refresh") },
            platformEffects: effects, launchDefaults: defaults)
        await store.refresh(force: true, now: now)
        await store.scheduleBackgroundRefresh(now: now)
        let first = calls.withLock { $0 }
        for hook in ["connect:false", "gate", "watch", "widgets", "application-state", "activities", "background"] {
            XCTAssertEqual(first.filter { $0 == hook }.count, 1, "\(hook) must use the injected handler once")
        }
        let cache = try XCTUnwrap(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName)))
        XCTAssertEqual(cache.savedAt, now)
        await store.refresh(force: true, now: now.addingTimeInterval(60))
        let second = calls.withLock { $0 }
        XCTAssertEqual(second.filter { $0 == "watch" }.count, 1, "An unchanged cache is not handed over again")
        XCTAssertEqual(second.filter { $0 == "widgets" }.count, 1, "An unchanged cache does not reload widgets")
        XCTAssertEqual(second.filter { $0 == "activities" }.count, 2, "Activity updates still follow complete refreshes")
    }

    /// A store with no iCloud whose widget reloads and Watch handovers are counted, as from the
    /// background. The Mac's readings reach it as a widget's refresh saved them (`fromMac`).
    @MainActor
    private func countingStore(defaults: UserDefaults, folder: URL, calls: EffectCalls) -> MobileStore {
        let effects = MobilePlatformEffects(
            setWatchConnectAvailable: { _ in }, sendToWatch: { _ in calls.append("watch") },
            reloadWidgets: { calls.append("widgets") }, applicationIsBackground: { true },
            updateLiveActivities: { _, _, _, _ in }, makeKeyFetchGate: { KeyFetchGate(defaults: $0, lockDirectory: nil) },
            scheduleBackgroundRefresh: { _ in }
        )
        return MobileStore(defaults: defaults, containerIdentifier: nil, keys: MobileFixtureKeychain().keys,
            directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in XCTFail("No alert exists in this refresh") },
            platformEffects: effects, launchDefaults: defaults)
    }

    private func fromMac(checked: Date) -> ReadingCache {
        let provider = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: checked, fetchedAt: checked, primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 42, resetsAt: now.addingTimeInterval(3 * 86_400))]
        )
        return ReadingCache(savedAt: checked, isSample: false, items: [ReadingCache.Item(provider: provider, source: "Mac")])
    }

    /// A Mac awake with unchanged usage sends a heartbeat (`RelayPublishPolicy.heartbeat`), and the iPhone, in
    /// the background, takes each one. Widgets already show every one of them live: no reload is
    /// spent on WidgetKit's budget, and the Watch isn't handed the same numbers again.
    @MainActor
    func testHeartbeatsWithTheSameNumbersReloadNothingFromTheBackground() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let cacheURL = folder.appendingPathComponent(ReadingCache.fileName)
        try fromMac(checked: now).save(to: cacheURL)
        let calls = EffectCalls()
        let store = countingStore(defaults: defaults, folder: folder, calls: calls)
        for beat in 1...8 {
            let date = now.addingTimeInterval(Double(beat) * 30 * 60)
            try fromMac(checked: date.addingTimeInterval(-60)).save(to: cacheURL)
            await store.refresh(force: true, now: date)
        }
        XCTAssertEqual(calls.all, [], "Four hours of heartbeats: nothing to reload or hand over")
    }

    /// The same from a Mac whose clock runs six minutes fast: its readings are live, not "dated
    /// ahead", so each heartbeat isn't a reading come back to life.
    @MainActor
    func testHeartbeatsFromAMacWithAFastClockReloadNothing() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let cacheURL = folder.appendingPathComponent(ReadingCache.fileName)
        try fromMac(checked: now.addingTimeInterval(6 * 60)).save(to: cacheURL)
        let calls = EffectCalls()
        let store = countingStore(defaults: defaults, folder: folder, calls: calls)
        for beat in 1...8 {
            let date = now.addingTimeInterval(Double(beat) * 30 * 60)
            try fromMac(checked: date.addingTimeInterval(6 * 60)).save(to: cacheURL)
            await store.refresh(force: true, now: date)
        }
        XCTAssertEqual(calls.all, [], "Four hours of heartbeats: nothing to reload or hand over")
        XCTAssertEqual(store.readings.first?.provider.state, "live")
    }

    /// Widgets and the Watch were given the Mac's live reading; the Mac sleeps for 90 minutes, and
    /// a refresh meanwhile saves it stale. When it wakes with the same numbers, live again, that's
    /// one reload from the background and one handover.
    @MainActor
    func testAReadingLiveAgainWithTheSameNumbersReloadsWidgetsAndReachesTheWatch() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let cacheURL = folder.appendingPathComponent(ReadingCache.fileName)
        try fromMac(checked: now).save(to: cacheURL)
        let calls = EffectCalls()
        let store = countingStore(defaults: defaults, folder: folder, calls: calls)
        await store.refresh(force: true, now: now.addingTimeInterval(70 * 60))
        XCTAssertEqual(calls.all, [], "Saved stale, as widgets already draw it")
        let woke = now.addingTimeInterval(90 * 60)
        try fromMac(checked: woke).save(to: cacheURL)
        await store.refresh(force: true, now: woke)
        let made = calls.all
        XCTAssertEqual(made.filter { $0 == "watch" }, ["watch"], "The Watch still shows it stale")
        XCTAssertEqual(made.filter { $0 == "widgets" }, ["widgets"], "Worth a reload from the background")
    }

    @MainActor
    func testSharedAccountInvalidationCannotStampOldMemoryWithTheNewGeneration() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        let provider = RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757",
            state: "live", checkedAt: now, primaryWindowID: "weekly",
            windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: 42)])
        try ReadingCache(savedAt: now, isSample: false, items: [.init(provider: provider, source: "Mac")]).save(to: url)
        let store = makeStore(defaults: defaults, folder: folder)
        await store.refresh(force: true, now: now)
        XCTAssertEqual(store.readings.map(\.id), ["claude"])

        // A widget/account observer closes the shared gate before this store's queued main
        // actor accountChanged callback. A local UI rebuild must not reopen that gate.
        PhoneCacheAccess.invalidate(in: defaults)
        store.setBudget(50, for: .deepseek)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(PhoneCacheAccess.load(at: url, defaults: defaults)?.items, [])

        store.accountChanged()
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertEqual(PhoneCacheAccess.load(at: url, defaults: defaults)?.items, [])
        // A second process may observe the same event after the store. It must recover on its
        // next rebuild, with cleared membership, rather than permanently failing every save.
        PhoneCacheAccess.invalidate(in: defaults)
        store.setBudget(60, for: .deepseek)
        XCTAssertEqual(PhoneCacheAccess.load(at: url, defaults: defaults)?.items, [])
    }

    @MainActor
    func testSampleModeShowsLabelledSamplesAndSavesThemForWidgets() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileStore.Keys.sampleMode)
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)

        XCTAssertTrue(store.sampleMode)
        XCTAssertEqual(store.relayPhase, .unavailable, "No iCloud container")
        XCTAssertEqual(Set(store.readings.map(\.id)), Set(SampleData.cache().items.map(\.id)))
        XCTAssertTrue(store.readings.allSatisfy { $0.source == SampleData.sourceLabel })
        XCTAssertEqual(store.sourceSummary, SampleData.sourceLabel)
        XCTAssertNotNil(store.reading(id: "claude")?.history["weekly"])
        XCTAssertTrue(store.disconnected.isEmpty)

        let saved = try XCTUnwrap(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName)))
        XCTAssertTrue(saved.isSample, "Widgets show the same samples, labelled")
        XCTAssertEqual(saved.items.map(\.id), store.readings.map(\.id))
    }

    @MainActor
    func testALaunchThatCantReadICloudKeepsTheOtherDevicesReadings() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let fromMac = RelayProvider(
            id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: now, fetchedAt: now, primaryWindowID: "weekly",
            windows: [RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: 42, resetsAt: now.addingTimeInterval(86_400))]
        )
        let cacheURL = folder.appendingPathComponent(ReadingCache.fileName)
        try ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: fromMac, source: "Mac")]).save(to: cacheURL)

        // No iCloud in this store, like a launch that's offline.
        let store = makeStore(defaults: defaults, folder: folder)
        await store.refresh(force: true, now: now.addingTimeInterval(60))
        XCTAssertEqual(store.readings.map(\.id), ["claude"], "The Mac's reading stays until iCloud answers")
        XCTAssertEqual(store.readings.first?.source, "Mac")
        let saved = try XCTUnwrap(ReadingCache.load(from: cacheURL))
        XCTAssertEqual(saved.items.map(\.id), ["claude"], "Widgets and the Watch keep it too")
    }

    @MainActor
    func testLeavingSampleModeWithNothingConnectedShowsNothing() async throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: MobileStore.Keys.sampleMode)
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        store.sampleMode = false
        XCTAssertFalse(defaults.bool(forKey: MobileStore.Keys.sampleMode))
        XCTAssertTrue(store.readings.isEmpty)

        await store.refresh(force: true)
        XCTAssertTrue(store.readings.isEmpty)
        XCTAssertTrue(store.keyedProviders.isEmpty)
        XCTAssertEqual(store.relayStatusText, "Not available in this build")
        XCTAssertNotNil(store.lastRefresh)
        XCTAssertEqual(ReadingCache.load(from: folder.appendingPathComponent(ReadingCache.fileName))?.isSample, false, "Widgets stop showing samples")
    }

    @MainActor
    func testBudgetsAreInDollarsUntilABalanceSaysOtherwise() throws {
        let store = makeStore(defaults: makeDefaults(), folder: try makeFolder())
        XCTAssertEqual(store.budgetCurrency(for: .deepseek), "USD")
        XCTAssertEqual(store.budgetCurrency(for: .moonshot), "USD")
        XCTAssertNil(store.budget(for: .deepseek))
    }

    @MainActor
    func testInvalidBudgetPreservesTheSavedAmountUntilExplicitlyCleared() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        store.setBudget(50, for: .deepseek)
        for invalid in [0.0, -1, .infinity, .nan] {
            store.setBudget(invalid, for: .deepseek)
            XCTAssertEqual(store.budget(for: .deepseek), 50)
        }
        XCTAssertEqual(makeStore(defaults: defaults, folder: folder).budget(for: .deepseek), 50)
        store.setBudget(nil, for: .deepseek)
        XCTAssertNil(store.budget(for: .deepseek))
    }

    @MainActor
    func testRetainedReadingsAgeWhileTheUsagePageStaysOpen() async throws {
        let folder = try makeFolder()
        let checked = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let provider = RelayProvider(id: "claude", name: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", state: "live",
            checkedAt: checked, primaryWindowID: "weekly", windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: 42)])
        try ReadingCache(savedAt: checked, isSample: false, items: [.init(provider: provider, source: "Mac")])
            .save(to: folder.appendingPathComponent(ReadingCache.fileName))
        let store = makeStore(defaults: makeDefaults(), folder: folder)
        await store.refresh(force: true, now: checked)
        XCTAssertEqual(store.readings.first?.provider.state, "live")
        store.ageReadings(at: checked.addingTimeInterval(3601))
        XCTAssertEqual(store.readings.first?.provider.state, "stale")
        XCTAssertEqual(store.lastChecked, checked, "Aging does not invent a successful check")
        store.ageReadings(at: checked.addingTimeInterval(7 * 86_400 + 1))
        XCTAssertTrue(store.readings.isEmpty)
    }

    /// While Usage is on screen: nothing before the first wait (coming forward already refreshed),
    /// an ordinary refresh after each one, and nothing more once the wait is cancelled because the
    /// tab or the app went away.
    @MainActor
    func testKeepCurrentRefreshesAfterEachWaitUntilCancelled() async throws {
        let store = makeStore(defaults: makeDefaults(), folder: try makeFolder())
        let waits = Mutex(0)
        XCTAssertNil(store.lastRefresh)
        await store.keepCurrent(interval: 120) { interval in
            XCTAssertEqual(interval, 120)
            let count = waits.withLock { value in
                value += 1
                return value
            }
            if count == 3 { throw CancellationError() }
        }
        XCTAssertEqual(waits.withLock { $0 }, 3, "Two waits each followed by a refresh, then the cancelled one")
        XCTAssertNotNil(store.lastRefresh)
        XCTAssertNil(store.latestChecked, "No readings: nothing to say how current they are")
    }

    @MainActor
    func testAlertChoicesMadeOnTheIPhoneAreStampedAndKept() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let store = makeStore(defaults: defaults, folder: folder)
        XCTAssertNil(store.alertPreferences.updatedAt)
        store.alertPreferences.lowBalance = false
        XCTAssertNotNil(store.alertPreferences.updatedAt, "Stamped, so the newer copy wins against a Mac's")
        XCTAssertFalse(defaults.bool(forKey: MobileStore.Keys.alertPreferencesShared), "Waiting to reach iCloud")
        XCTAssertEqual(makeStore(defaults: defaults, folder: folder).alertPreferences, store.alertPreferences)
    }

    @MainActor
    func testQuietHoursFollowThisIPhoneOnlyWhenItsZoneChanges() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        var elsewhere = AlertPreferences()
        elsewhere.timeZoneID = TimeZone.current.identifier == "Pacific/Auckland" ? "Europe/Madrid" : "Pacific/Auckland"
        defaults.set(try JSONEncoder().encode(elsewhere), forKey: MobileStore.Keys.alertPreferences)

        let store = makeStore(defaults: defaults, folder: folder)
        await store.refresh(force: true)
        XCTAssertEqual(store.alertPreferences.timeZoneID, TimeZone.current.identifier, "The shared choices take this iPhone's zone")
        XCTAssertNil(store.alertPreferences.updatedAt, "Not a change of choices")

        // Another iPhone in its own zone set it since; this one hasn't moved.
        defaults.set(try JSONEncoder().encode(elsewhere), forKey: MobileStore.Keys.alertPreferences)
        let again = makeStore(defaults: defaults, folder: folder)
        await again.refresh(force: true)
        XCTAssertEqual(again.alertPreferences.timeZoneID, elsewhere.timeZoneID, "Two iPhones don't take turns rewriting it")
    }

    /// Anthropic's report is 15 minutes apart: a budget changed before the next call shows on
    /// the saved reading at once.
    @MainActor
    func testABudgetShowsOnASavedReadingAtOnce() throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let checked = Date()
        let balance = QuotaWindow(id: "balance-cny", kind: .pool, title: "Balance", usedPercent: 0, resetsAt: nil, amount: QuotaAmount(remaining: 12.4, unit: "cny"), metered: false)
        let snapshot = QuotaSnapshot(provider: .deepseek, usedPercent: 0, resetsAt: nil, fetchedAt: checked, primaryTitle: "Balance", windows: [balance])
        let saved = RelayProvider(provider: .deepseek, status: .live(snapshot.applyingBudget(50)), checkedAt: checked)
        try ReadingCache(savedAt: checked, isSample: false, items: [ReadingCache.Item(provider: saved, source: MobileStore.localLabel)])
            .save(to: folder.appendingPathComponent(ReadingCache.fileName))
        defaults.set([Provider.deepseek.rawValue], forKey: MobileStore.Keys.keyedProviders)

        let store = makeStore(defaults: defaults, folder: folder)
        XCTAssertEqual(store.budgetCurrency(for: .deepseek), "CNY", "From the saved reading, before this launch reads it")
        store.setBudget(100, for: .deepseek)
        let window = try XCTUnwrap(store.reading(id: Provider.deepseek.rawValue)?.provider.windows.first)
        XCTAssertEqual(window.used, 87.6, accuracy: 0.001, "12.40 left of 100")
        XCTAssertEqual(window.amount?.limit, 100)
    }

    func testLiveActivityResetRetainsMeasurementAndSuppressesHeadlineAndPace() throws {
        let original = SessionActivityAttributes.ContentState(used: 96, resetsAt: now, isStale: false, warnedRunsOut: true)
        let decoded = try RelayEnvelope.decoder.decode(SessionActivityAttributes.ContentState.self, from: RelayEnvelope.encoder.encode(original))
        XCTAssertNil(decoded.awaitingReading, "Activities created before this field remain readable")
        let pending = decoded.shown(isStale: false, now: now)
        XCTAssertEqual(pending.used, 96)
        XCTAssertEqual(pending.percentText, "—")
        XCTAssertTrue(pending.isStale)
        XCTAssertEqual(pending.warnedRunsOut, true)
        let attributes = SessionActivityAttributes(providerID: "claude", providerName: "Claude", shortName: "Claude", monogram: "C", tint: "#D97757", windowID: "session", windowTitle: "5-hour", windowSeconds: 5 * 3600)
        XCTAssertNil(attributes.paceMark(for: pending))
        var future = original
        future.resetsAt = now.addingTimeInterval(3600)
        XCTAssertEqual(future.shown(isStale: false, now: now).used, 96)
        XCTAssertEqual(future.shown(isStale: false, now: now).percentText, "96%")
        XCTAssertEqual(future.shown(isStale: true, now: now).percentText, "—", "ActivityKit stale dates also produce a pending reading")
        XCTAssertEqual(future.shown(isStale: true, now: now).used, 96)
    }

    func testPinnedWidgetNeverSubstitutesAnAbsentOrExpiredProvider() {
        func reading(_ id: String, age: TimeInterval) -> ReadingCache.Item {
            .init(provider: RelayProvider(id: id, name: id, shortName: id, monogram: "X", tint: "#000000", state: "live", checkedAt: now.addingTimeInterval(-age), primaryWindowID: "weekly", windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: 40)]), source: "Mac")
        }
        let cache = ReadingCache(savedAt: now, isSample: false, items: [reading("cursor", age: 0), reading("claude", age: 7 * 86_400 + 1)])
        let pinned = ReadingsEntry.make(cache, choice: .claude, date: now)
        XCTAssertTrue(pinned.items.isEmpty)
        XCTAssertEqual(pinned.unavailableProvider, .claude)
        XCTAssertNil(pinned.checkedAt)
        XCTAssertEqual(ReadingsEntry.make(cache, choice: .automatic, date: now).items.first?.id, "cursor")
        XCTAssertEqual(ReadingsEntry.make(cache, choice: .cursor, date: now).items.first?.id, "cursor")
        XCTAssertNil(ReadingsEntry.make(cache, choice: .cursor, date: now).unavailableProvider)
        XCTAssertEqual(ReadingsEntry.make(nil, choice: .claude, date: now).unavailableProvider, .claude)
        XCTAssertTrue(ReadingsEntry.make(cache, choice: .openai, date: now).items.isEmpty)
    }

    @MainActor
    func testAccountChangePurgesRemoteCacheAndRetainsDeviceLocalReadings() throws {
        let defaults = makeDefaults()
        defaults.set([Provider.openrouter.rawValue], forKey: MobileStore.Keys.keyedProviders)
        let folder = try makeFolder()
        func item(_ provider: Provider, source: String) -> ReadingCache.Item {
            .init(provider: RelayProvider(id: provider.rawValue, name: provider.rawValue, shortName: provider.rawValue,
                monogram: "X", tint: "#000000", state: "live", checkedAt: .now, primaryWindowID: "weekly",
                windows: [.init(id: "weekly", kind: "weekly", title: "Weekly", used: 42)]), source: source)
        }
        let url = folder.appendingPathComponent(ReadingCache.fileName)
        try ReadingCache(savedAt: .now, isSample: false,
            items: [item(.claude, source: "Mac"), item(.openrouter, source: MobileStore.localLabel)]).save(to: url)
        let store = makeStore(defaults: defaults, folder: folder)
        XCTAssertEqual(store.readings.count, 2)
        store.accountChanged()
        XCTAssertEqual(store.readings.map(\.id), [Provider.openrouter.rawValue])
        XCTAssertEqual(PhoneCacheAccess.load(at: url, defaults: defaults)?.items.map(\.id), [Provider.openrouter.rawValue])
        XCTAssertEqual(makeStore(defaults: defaults, folder: folder).readings.map(\.id), [Provider.openrouter.rawValue])
    }

    @MainActor
    func testFailedNotificationSchedulingRemainsRetryableAndIsNotClaimedAsShown() async throws {
        let defaults = makeDefaults()
        let calls = Mutex(0)
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: MobileFixtureKeychain().keys, directory: try makeFolder(), connectOnIPhone: false,
            notificationScheduler: { _ in
                let attempt = calls.withLock { count in count += 1; return count }
                if attempt == 1 { throw NSError(domain: "mock.notification", code: 1) }
            }, platformEffects: .inert, launchDefaults: defaults)
        let alert = UsageAlert(id: "test-alert", provider: "openrouter", kind: .threshold, level: 80,
            title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        let failed = await store.deliverAlerts([alert], now: now)
        XCTAssertTrue(failed.isEmpty, "The ledger must not mark a rejected notification as sent")
        XCTAssertNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts), "No notification was shown to claim later")
        let retried = await store.deliverAlerts([alert], now: now.addingTimeInterval(60))
        XCTAssertEqual(retried, [alert.id])
        XCTAssertNotNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts))
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    // MARK: Shared with the widgets

    func testWidgetsSeeTheAppsCallsThroughTheSharedGate() {
        let defaults = makeDefaults()
        KeyFetchGate(defaults: defaults, lockDirectory: nil).recordAttempt(.anthropicOrg, at: now)
        let widget = KeyFetchGate(defaults: defaults, lockDirectory: nil)
        XCTAssertTrue(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(60)), "Anthropic's cost report allows a call every 15 minutes")
        XCTAssertFalse(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(15 * 60)))

        widget.block(.openrouter, until: now.addingTimeInterval(600))
        XCTAssertTrue(KeyFetchGate(defaults: defaults, lockDirectory: nil).isResting(.openrouter, now: now), "A 429 in a widget holds the app off too")
        XCTAssertFalse(KeyFetchGate(defaults: makeDefaults(), lockDirectory: nil).isResting(.openrouter, now: now))
    }

    @MainActor
    func testResetCountdownTicksWithinADay() {
        XCTAssertEqual(ResetCountdown.text(resetsAt: now.addingTimeInterval(-60), date: now), Text("now"))
        XCTAssertEqual(ResetCountdown.text(resetsAt: now.addingTimeInterval(3 * 86_400 + 3600), date: now), Text(String("3d 1h")))
        let ticking = ResetCountdown.text(resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60), date: now)
        XCTAssertNotEqual(ticking, Text("now"))
        XCTAssertNotEqual(ticking, Text(String("2h 13m")), "Within a day the clock counts down by itself, without reloads")
    }

    @MainActor
    func testAcceptedNotificationSurvivesCancellationAndIsNotReplayedAfterRelaunch() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let alert = UsageAlert(id: "accepted-before-cancellation", provider: "openrouter", kind: .threshold,
            level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        var ledger = AlertLedger()
        ledger.pending = [.init(alert: alert, raisedAt: now)]
        ledger.save(to: folder)
        let calls = Mutex(0)
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: MobileFixtureKeychain().keys, directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in
                calls.withLock { $0 += 1 }
                // The scheduler accepted the request as the background deadline expired.
                withUnsafeCurrentTask { $0?.cancel() }
            }, platformEffects: .inert, launchDefaults: defaults)
        let delivery = Task { @MainActor in await store.deliverAlerts([alert], now: now) }
        let accepted = await delivery.value
        XCTAssertTrue(delivery.isCancelled)
        XCTAssertEqual(accepted, [alert.id])
        let saved = AlertLedger.load(from: folder)
        XCTAssertEqual(saved.sent[alert.id], now)
        XCTAssertTrue(saved.pending.isEmpty)
        let shown = try XCTUnwrap(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: shown) as? [Any])?.count, 1,
                       "A successful offline schedule must still be claimed when iCloud returns")
        let ledgerURL = folder.appendingPathComponent(AlertLedger.fileName)
        let acknowledged = try Data(contentsOf: ledgerURL)

        let relaunched = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: MobileFixtureKeychain().keys, directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in calls.withLock { $0 += 1 } }, platformEffects: .inert, launchDefaults: defaults)
        let replay = await relaunched.deliverAlerts([alert], now: now.addingTimeInterval(60))
        XCTAssertTrue(replay.isEmpty, "Already persisted incoming alert IDs are skipped")
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), acknowledged, "A retry must not rewrite an existing acknowledgement")
    }

    @MainActor
    func testCancellationAfterFirstScheduleLeavesSecondAlertPendingUntilNextPass() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        func alert(_ id: String) -> UsageAlert {
            .init(id: id, provider: "openrouter", kind: .threshold, level: 80,
                  title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        }
        let first = alert("first-accepted")
        let second = alert("second-pending")
        var ledger = AlertLedger()
        ledger.pending = [first, second].map { .init(alert: $0, raisedAt: now) }
        ledger.save(to: folder)
        let calls = Mutex<[String]>([])
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: MobileFixtureKeychain().keys, directory: folder, connectOnIPhone: false,
            notificationScheduler: { request in
                let count = calls.withLock { calls in calls.append(request.identifier); return calls.count }
                if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }, platformEffects: .inert, launchDefaults: defaults)
        let delivery = Task { @MainActor in await store.deliverAlerts([first, second], now: now) }
        let accepted = await delivery.value
        XCTAssertEqual(accepted, [first.id])
        XCTAssertEqual(calls.withLock { $0 }, [first.id], "Cancellation prevents the second physical schedule")
        let interrupted = AlertLedger.load(from: folder)
        XCTAssertEqual(interrupted.sent[first.id], now)
        XCTAssertNil(interrupted.sent[second.id])
        XCTAssertEqual(interrupted.pending.map(\.alert.id), [second.id])

        let retried = await store.deliverAlerts([first, second], now: now.addingTimeInterval(60))
        XCTAssertEqual(retried, [second.id])
        XCTAssertEqual(calls.withLock { $0 }, [first.id, second.id])
        let completed = AlertLedger.load(from: folder)
        XCTAssertTrue(completed.pending.isEmpty)
        XCTAssertEqual(completed.sent[first.id], now)
        XCTAssertEqual(completed.sent[second.id], now.addingTimeInterval(60))
    }

    @MainActor
    private final class AccountChangingStore {
        weak var store: MobileStore?
    }

    private func mockNotificationKeys() -> APIKeyStore {
        MobileFixtureKeychain().keys
    }

    @MainActor
    func testAcceptedScheduleIsNotReplayedWhenTheAccountChangesDuringTheAwait() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let alert = UsageAlert(id: "accepted-before-account-change", provider: "openrouter", kind: .threshold,
            level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        var ledger = AlertLedger()
        ledger.pending = [.init(alert: alert, raisedAt: now)]
        ledger.save(to: folder)
        let changing = AccountChangingStore()
        let calls = Mutex(0)
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: mockNotificationKeys(), directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in
                let count = calls.withLock { calls in calls += 1; return calls }
                await Task.yield()
                if count == 1 { changing.store?.accountChanged() }
                // iOS accepted the request even though the account changed while awaiting it.
            }, platformEffects: .inert, launchDefaults: defaults)
        changing.store = store
        let accepted = await store.deliverAlerts([alert], now: now)
        XCTAssertEqual(accepted, [alert.id])
        let saved = AlertLedger.load(from: folder)
        XCTAssertEqual(saved.sent[alert.id], now)
        XCTAssertTrue(saved.pending.isEmpty)
        let shown = defaults.data(forKey: MobileStore.Keys.unclaimedAlerts)
        XCTAssertNotNil(shown, "The physically scheduled alert remains claimable in the new account")
        if let shown {
            XCTAssertEqual((try JSONSerialization.jsonObject(with: shown) as? [Any])?.count, 1)
        }
        let generation = try XCTUnwrap(PhoneCacheAccess.generation(in: defaults))
        XCTAssertEqual(PhoneCacheAccess.load(at: folder.appendingPathComponent(ReadingCache.fileName), defaults: defaults)?.accountGeneration,
                       generation, "Acknowledgement must not restore the previous account's cache marker")

        let nextPass = await store.deliverAlerts([alert], now: now.addingTimeInterval(60))
        XCTAssertTrue(nextPass.isEmpty)
        let relaunched = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: mockNotificationKeys(), directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in calls.withLock { $0 += 1 } }, platformEffects: .inert, launchDefaults: defaults)
        let replay = await relaunched.deliverAlerts([alert], now: now.addingTimeInterval(120))
        XCTAssertTrue(replay.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 1, "One accepted physical schedule remains one schedule across retries and relaunch")
    }

    @MainActor
    func testAccountChangeAfterAcceptedOwnClaimKeepsSecondAlertPending() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        func alert(_ id: String) -> UsageAlert {
            .init(id: id, provider: "openrouter", kind: .threshold, level: 80,
                  title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        }
        let first = alert("own-claim-accepted")
        let second = alert("own-claim-not-scheduled")
        var ledger = AlertLedger()
        ledger.pending = [first, second].map { .init(alert: $0, raisedAt: now) }
        ledger.save(to: folder)
        let changing = AccountChangingStore()
        let calls = Mutex<[String]>([])
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: mockNotificationKeys(), directory: folder, connectOnIPhone: false,
            notificationScheduler: { request in
                let count = calls.withLock { calls in calls.append(request.identifier); return calls.count }
                if count == 1 { changing.store?.accountChanged() }
            }, claimAlert: { _, _ in .ours }, platformEffects: .inert, launchDefaults: defaults)
        changing.store = store
        let accepted = await store.deliverAlerts([first, second], now: now)
        XCTAssertEqual(accepted, [first.id])
        XCTAssertEqual(calls.withLock { $0 }, [first.id], "No second schedule can start under a superseded account")
        let interrupted = AlertLedger.load(from: folder)
        XCTAssertEqual(interrupted.sent[first.id], now)
        XCTAssertNil(interrupted.sent[second.id])
        XCTAssertEqual(interrupted.pending.map(\.alert.id), [second.id])
        XCTAssertNotNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts),
                        "The old account's claim cannot stand for a notification accepted after the switch")

        let retried = await store.deliverAlerts([first, second], now: now.addingTimeInterval(60))
        XCTAssertEqual(retried, [second.id])
        XCTAssertEqual(calls.withLock { $0 }, [first.id, second.id])
        XCTAssertTrue(AlertLedger.load(from: folder).pending.isEmpty)
    }

    @MainActor
    func testAccountChangeDuringClaimAwaitAcknowledgesTakenAndSchedulesOwnClaim() async throws {
        for result in [MobileStore.Claim.taken, .ours] {
            let defaults = makeDefaults()
            let folder = try makeFolder()
            let first = UsageAlert(id: "claim-in-flight", provider: "openrouter", kind: .threshold,
                level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
            let second = UsageAlert(id: "claim-not-started", provider: "openrouter", kind: .threshold,
                level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
            var ledger = AlertLedger()
            ledger.pending = [first, second].map { .init(alert: $0, raisedAt: now) }
            ledger.save(to: folder)
            let changing = AccountChangingStore()
            let calls = Mutex(0)
            let store = MobileStore(defaults: defaults, containerIdentifier: nil,
                keys: mockNotificationKeys(), directory: folder, connectOnIPhone: false,
                notificationScheduler: { _ in calls.withLock { $0 += 1 } }, claimAlert: { _, _ in
                    await Task.yield()
                    changing.store?.accountChanged()
                    return result
                }, platformEffects: .inert, launchDefaults: defaults)
            changing.store = store
            let accepted = await store.deliverAlerts([first, second], now: now)
            XCTAssertEqual(accepted, [first.id], "Finish the current device-local alert and stop later alerts")
            let saved = AlertLedger.load(from: folder)
            XCTAssertEqual(saved.sent[first.id], now)
            XCTAssertNil(saved.sent[second.id])
            XCTAssertEqual(saved.pending.map(\.alert.id), [second.id])
            switch result {
            case .taken:
                XCTAssertEqual(calls.withLock { $0 }, 0, "A confirmed prior delivery must never be scheduled locally")
                XCTAssertNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts))
            case .ours:
                XCTAssertEqual(calls.withLock { $0 }, 1, "An own claim needs accepted physical scheduling before acknowledgement")
                XCTAssertNotNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts),
                                "The old account's claim cannot stand for the new account's local notification")
            case .unasked:
                XCTFail("This control uses only confirmed claim outcomes")
            }
        }
    }

    @MainActor
    func testFailedScheduleAcrossAccountChangeStaysPendingAndRetryable() async throws {
        let defaults = makeDefaults()
        let folder = try makeFolder()
        let alert = UsageAlert(id: "rejected-after-account-change", provider: "openrouter", kind: .threshold,
            level: 80, title: "Usage", body: "Limit", resetsAt: nil, isUrgent: false)
        var ledger = AlertLedger()
        ledger.pending = [.init(alert: alert, raisedAt: now)]
        ledger.save(to: folder)
        let changing = AccountChangingStore()
        let calls = Mutex(0)
        let store = MobileStore(defaults: defaults, containerIdentifier: nil,
            keys: mockNotificationKeys(), directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in
                let count = calls.withLock { calls in calls += 1; return calls }
                if count == 1 {
                    changing.store?.accountChanged()
                    throw NSError(domain: "mock.notification", code: 1)
                }
            }, platformEffects: .inert, launchDefaults: defaults)
        changing.store = store
        let failed = await store.deliverAlerts([alert], now: now)
        XCTAssertTrue(failed.isEmpty)
        let saved = AlertLedger.load(from: folder)
        XCTAssertNil(saved.sent[alert.id])
        XCTAssertEqual(saved.pending.map(\.alert.id), [alert.id])
        XCTAssertNil(defaults.data(forKey: MobileStore.Keys.unclaimedAlerts))
        let retried = await store.deliverAlerts([alert], now: now.addingTimeInterval(60))
        XCTAssertEqual(retried, [alert.id])
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }
}

/// What a store asked of the device, in order.
private final class EffectCalls: Sendable {
    private let calls = Mutex<[String]>([])
    func append(_ call: String) { calls.withLock { $0.append(call) } }
    var all: [String] { calls.withLock { $0 } }
}
