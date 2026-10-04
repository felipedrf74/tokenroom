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

    /// A store with no iCloud, a Keychain prefix no real key uses, and its own folder.
    @MainActor
    private func makeStore(defaults: UserDefaults, folder: URL) -> MobileStore {
        MobileStore(
            defaults: defaults,
            containerIdentifier: nil,
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests.\(UUID().uuidString)."),
            directory: folder
        )
    }

    // MARK: Store

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
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests." + UUID().uuidString), directory: try makeFolder(),
            notificationScheduler: { _ in
                let attempt = calls.withLock { count in count += 1; return count }
                if attempt == 1 { throw NSError(domain: "mock.notification", code: 1) }
            })
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
        KeyFetchGate(defaults: defaults).recordAttempt(.anthropicOrg, at: now)
        let widget = KeyFetchGate(defaults: defaults)
        XCTAssertTrue(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(60)), "Anthropic's cost report allows a call every 15 minutes")
        XCTAssertFalse(widget.isResting(.anthropicOrg, now: now.addingTimeInterval(15 * 60)))

        widget.block(.openrouter, until: now.addingTimeInterval(600))
        XCTAssertTrue(KeyFetchGate(defaults: defaults).isResting(.openrouter, now: now), "A 429 in a widget holds the app off too")
        XCTAssertFalse(KeyFetchGate(defaults: makeDefaults()).isResting(.openrouter, now: now))
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
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests." + UUID().uuidString), directory: folder,
            notificationScheduler: { _ in
                calls.withLock { $0 += 1 }
                // The scheduler accepted the request as the background deadline expired.
                withUnsafeCurrentTask { $0?.cancel() }
            })
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
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests." + UUID().uuidString), directory: folder,
            notificationScheduler: { _ in calls.withLock { $0 += 1 } })
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
            keys: APIKeyStore(servicePrefix: "app.tokenroom.tests." + UUID().uuidString), directory: folder,
            notificationScheduler: { request in
                let count = calls.withLock { calls in calls.append(request.identifier); return calls.count }
                if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
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
        APIKeyStore(servicePrefix: "app.tokenroom.tests." + UUID().uuidString, keychain: .init(
            copy: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecInteractionNotAllowed },
            update: { _, _ in errSecInteractionNotAllowed },
            delete: { _ in errSecItemNotFound }
        ))
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
            keys: mockNotificationKeys(), directory: folder,
            notificationScheduler: { _ in
                let count = calls.withLock { calls in calls += 1; return calls }
                await Task.yield()
                if count == 1 { changing.store?.accountChanged() }
                // iOS accepted the request even though the account changed while awaiting it.
            })
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
            keys: mockNotificationKeys(), directory: folder,
            notificationScheduler: { _ in calls.withLock { $0 += 1 } })
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
            keys: mockNotificationKeys(), directory: folder,
            notificationScheduler: { request in
                let count = calls.withLock { calls in calls.append(request.identifier); return calls.count }
                if count == 1 { changing.store?.accountChanged() }
            }, claimAlert: { _, _ in .ours })
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
                keys: mockNotificationKeys(), directory: folder,
                notificationScheduler: { _ in calls.withLock { $0 += 1 } }, claimAlert: { _, _ in
                    await Task.yield()
                    changing.store?.accountChanged()
                    return result
                })
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
            keys: mockNotificationKeys(), directory: folder,
            notificationScheduler: { _ in
                let count = calls.withLock { calls in calls += 1; return calls }
                if count == 1 {
                    changing.store?.accountChanged()
                    throw NSError(domain: "mock.notification", code: 1)
                }
            })
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
