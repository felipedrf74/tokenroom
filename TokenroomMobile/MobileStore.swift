import CloudKit
import Foundation
import Observation
import UserNotifications
import os

struct MobileRelayReads: Sendable {
    var accountStatus: @Sendable () async throws -> CKAccountStatus
    var contents: @Sendable () async throws -> CloudRelay.Contents
    var sources: (@Sendable ([String]) async throws -> CloudRelay.SourceRead)? = nil
}

@MainActor
private final class MobileCredentialDiscovery<Value: Sendable> {
    private struct Flight {
        let id = UUID()
        let generation: UUID
        let task: Task<Value, Never>
    }

    private var generation = UUID()
    private var flight: Flight?

    func invalidate() { generation = UUID() }

    func read(within budget: TimeInterval, operation: @escaping @Sendable () async -> Value) async -> Value? {
        let current: Flight
        if let flight {
            current = flight
        } else {
            current = Flight(generation: generation, task: Task { await operation() })
            flight = current
        }
        let result = await TimeLimit.run(budget, otherwise: Optional<Value>.none) {
            await current.task.value
        }
        guard let result else { return nil }
        if flight?.id == current.id { flight = nil }
        guard !Task.isCancelled, current.generation == generation else { return nil }
        return result
    }
}

@Observable
@MainActor
final class MobileStore {
    enum RelayPhase: Equatable {
        case idle
        case loading
        case ready
        case unavailable
        case noAccount
        case failed(String)
    }

    struct Reading: Identifiable, Equatable {
        var provider: RelayProvider
        var source: String
        var history: [String: UsageHistory]
        var pace: Pace?
        var origin: CollectorKind

        var id: String { provider.id }

        init(_ item: ReadingCache.Item, now: Date = .now) {
            provider = item.provider
            source = item.source
            history = item.history
            pace = ReadingAssembler.pace(for: item, now: now)
            origin = item.resolvedOrigin
        }
    }

    enum Keys {
        static let sourceID = "relaySourceID"
        static let sampleMode = "sampleMode"
        static let onboarded = "onboarded"
        static let budgets = "budgets"
        static let budgetReferences = BudgetReferencePreferences.referencesKey
        static let published = "relayPublished"
        static let alertPreferences = "alertPreferences"
        static let alertPreferencesShared = "alertPreferencesShared"
        static let alertPreferencesBase = "alertPreferencesBase"
        static let prunedAt = "eventsPrunedAt"
        static let alertsFiltered = "alertSubscriptionFiltered"
        static let unclaimedAlerts = "unclaimedAlerts"
        static let keyedProviders = "keyedProviders"
        static let sessionProviders = "sessionProviders"
        static let sessionNotOnPlan = "sessionNotOnPlan"
        static let followedTimeZone = "followedTimeZone"
    }

    static let localLabel = "This iPhone"
    static let foregroundInterval: TimeInterval = 60
    static let passWait: TimeInterval = 120
    static let backgroundTaskID = "app.tokenroom.refresh"
    static let backgroundInterval: TimeInterval = 30 * 60
    static let liveInterval: TimeInterval = 2 * 60
    static let connectionRetry: TimeInterval = 15

    private(set) var relayPhase: RelayPhase = .idle
    private(set) var relaySources: [CloudRelay.Source] = []
    private(set) var relayHistories: [String: RelayHistory] = [:]
    private(set) var localStatuses: [Provider: ProviderStatus] = [:]
    private(set) var localCheckedAt: [Provider: Date] = [:]
    private var storedReadings: [Reading] = []
    private var presentationNow = Date.now
    var readings: [Reading] {
        storedReadings.compactMap { reading in
            guard let provider = ReadingFreshness.present(reading.provider, fallback: lastRefresh ?? .distantPast, now: presentationNow) else { return nil }
            var result = reading
            result.provider = provider
            result.pace = ReadingAssembler.pace(for: .init(provider: provider, source: reading.source, history: reading.history, origin: reading.origin), now: presentationNow)
            return result
        }
    }
    private(set) var disconnected: [Reading] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var keyedProviders: [Provider] = []
    private(set) var sessionProviders: [Provider] = []
    private(set) var refusedSessions: Set<Provider> = []
    private(set) var pausedSessions: Set<Provider> = []
    var localProviders: [Provider] {
        Provider.allCases.filter { keyedProviders.contains($0) || sessionProviders.contains($0) }
    }
    private(set) var coverage: [PhoneConnect.CoveringSource] = []
    let connectOnIPhone: Bool

    var relayIsInThisBuild: Bool {
        relay != nil || relayReads != nil
    }

    var relayUnavailableText: String {
        relayIsInThisBuild ? "Tokenroom can't access iCloud." : "This build can't use iCloud."
    }

    var canSignInOnIPhone: Bool {
        connectOnIPhone && sessions != nil
    }

    var sampleMode: Bool {
        didSet {
            defaults.set(sampleMode, forKey: Keys.sampleMode)
            rebuild()
        }
    }

    var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Keys.onboarded) }
    }

    var widgetArrangement: WidgetArrangement {
        didSet {
            guard widgetArrangement != oldValue else { return }
            widgetArrangement.save(to: defaults)
            widgetArrangementReload?.cancel()
            guard allowsExternalEffects else { return }
            widgetArrangementReload = Task { [weak self] in
                try? await Task.sleep(for: Self.widgetArrangementSettle)
                guard !Task.isCancelled, let self else { return }
                self.widgetArrangementReload = nil
                self.platformEffects.reloadWidgets()
            }
        }
    }
    static let widgetArrangementSettle: Duration = .seconds(1.5)

    func flushWidgetArrangementReload() {
        guard let pending = widgetArrangementReload else { return }
        pending.cancel()
        widgetArrangementReload = nil
        guard allowsExternalEffects else { return }
        platformEffects.reloadWidgets()
    }
    @ObservationIgnored private var widgetArrangementReload: Task<Void, Never>?

    var alertPreferences: AlertPreferences {
        didSet {
            guard alertPreferences != oldValue, !stampingPreferences else { return }
            if !adoptingPreferences, !followingTimeZone {
                stampingPreferences = true
                alertPreferences.touch()
                stampingPreferences = false
            }
            if let data = try? JSONEncoder().encode(alertPreferences) {
                defaults.set(data, forKey: Keys.alertPreferences)
            }
            guard !adoptingPreferences else { return }
            defaults.set(false, forKey: Keys.alertPreferencesShared)
            let choicesChanged = !followingTimeZone
            Task {
                await shareAlertPreferences()
                if choicesChanged {
                    await prepareNotifications()
                }
            }
        }
    }
    @ObservationIgnored private var adoptingPreferences = false
    @ObservationIgnored private var stampingPreferences = false
    @ObservationIgnored private var followingTimeZone = false

    let keys: APIKeyStore
    let allowsExternalEffects: Bool
    var hasPersistentStorage: Bool { directory != nil }
    var preferencesDefaults: UserDefaults { defaults }
    var widgetReloadCount: Int { WidgetReloadLog.count(defaults: defaults) }
    let sessions: PhoneSessionStore?
    private let refresher: PhoneSessionRefresher?
    @ObservationIgnored private let sessionSend: @Sendable (Provider) -> PhoneSessionClient.Send
    let sourceID: String
    @ObservationIgnored private let notificationScheduler: @MainActor @Sendable (UNNotificationRequest) async throws -> Void
    @ObservationIgnored private let platformEffects: MobilePlatformEffects
    @ObservationIgnored private let claimOverride: (@MainActor @Sendable (UsageAlert, Date) async -> Claim)?
    private let relay: CloudRelay?
    private let relayReads: MobileRelayReads?
    private let defaults: UserDefaults
    private let history: HistoryStore
    private let cacheURL: URL?
    private var publishPolicy = RelayPublishPolicy()
    private var lastHistoryHour: Date?
    @ObservationIgnored private var lastSavedCache: ReadingCache?
    @ObservationIgnored private var changesGivenOut = 0
    private var rateLimitedUntil: [Provider: Date] = [:]
    private let keyGate: KeyFetchGate
    private let credentialDiscoveryBudget: TimeInterval
    @ObservationIgnored private let keyDiscovery = MobileCredentialDiscovery<[Provider: APIKeyStore.Lookup]>()
    @ObservationIgnored private let sessionDiscovery = MobileCredentialDiscovery<[Provider: PhoneSessionStore.Lookup]>()
    private var relayRetryAt: Date?
    private var relayConnectionFailed = false
    @ObservationIgnored private var relayRecovery: Task<Void, Never>?
    private var cloudReadAt: Date?
    private var relaySnapshot: ReadingCache.RelaySnapshot?
    private var alertLedger: AlertLedger
    @ObservationIgnored private var ownRecord: RelayEnvelope?
    @ObservationIgnored private var keysRead = false
    @ObservationIgnored private var subscriptionsCurrent = false
    @ObservationIgnored private var relayReadOnce = false
    @ObservationIgnored private var relayGeneration = UUID()
    @ObservationIgnored private var cacheGeneration: String?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var queuedReadsKeys = false
    @ObservationIgnored private var queuedNow: Date?
    @ObservationIgnored private var lastKeyRefresh: Date?
    @ObservationIgnored private var sharingPreferences: Task<Void, Never>?
    @ObservationIgnored private var shareAgain = false
    @ObservationIgnored private var preferencesSharedAt: Date?
    @ObservationIgnored private var lastHandoverRunOuts: [String: Date] = [:]
    @ObservationIgnored private var lastHandoverChecks: [String: Date] = [:]
    @ObservationIgnored private var queuedManual = false
    @ObservationIgnored private var localFailedAt: [Provider: Date] = [:]
    @ObservationIgnored private var liveActivityUpdate: Task<Void, Never>?
    private let directory: URL?
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "store")

    init(
        defaults: UserDefaults = AppGroup.defaults,
        containerIdentifier: String? = RelayAvailability.containerIdentifier,
        keys: APIKeyStore = APIKeyStore(accessGroup: AppGroup.keychainGroup),
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        connectOnIPhone: Bool = PhoneConnect.isEnabled(),
        notificationScheduler: @escaping @MainActor @Sendable (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        },
        claimAlert: (@MainActor @Sendable (UsageAlert, Date) async -> Claim)? = nil,
        allowsExternalEffects: Bool = true,
        platformEffects: MobilePlatformEffects = .system,
        launchDefaults: UserDefaults = .standard,
        sessions: PhoneSessionStore? = PhoneSessionAvailability.store(),
        sessionSend: @escaping @Sendable (Provider) -> PhoneSessionClient.Send = PhoneSessionClient.live,
        sessionRenew: @escaping PhoneSessionRefresher.Post = { await PhoneSignInClient().renew($0, $1) },
        relayReads: MobileRelayReads? = nil,
        credentialDiscoveryBudget: TimeInterval = TokenroomHTTP.fetchBudget
    ) {
        self.defaults = defaults
        self.allowsExternalEffects = allowsExternalEffects
        cacheGeneration = PhoneCacheAccess.generation(in: defaults)
        self.notificationScheduler = notificationScheduler
        self.platformEffects = platformEffects
        self.relayReads = relayReads
        self.credentialDiscoveryBudget = credentialDiscoveryBudget
        claimOverride = claimAlert
        self.connectOnIPhone = connectOnIPhone
        let sessions = connectOnIPhone && allowsExternalEffects ? sessions : nil
        self.sessions = sessions
        self.sessionSend = sessionSend
        refresher = sessions.map { PhoneSessionRefresher(store: $0, post: sessionRenew) }
        if allowsExternalEffects { platformEffects.setWatchConnectAvailable(connectOnIPhone) }
        self.keys = keys
        keyGate = allowsExternalEffects ? platformEffects.makeKeyFetchGate(defaults) : KeyFetchGate(defaults: defaults, lockDirectory: nil)
        if let existing = defaults.string(forKey: Keys.sourceID) {
            sourceID = existing
        } else {
            sourceID = "src-\(UUID().uuidString.lowercased())"
            defaults.set(sourceID, forKey: Keys.sourceID)
        }
        relay = containerIdentifier.map { CloudRelay(containerIdentifier: $0, zoneDeletion: RelayZoneDeletion(defaults: defaults),
                                                     zoneArchive: RelayZoneArchive.defaultURL(containerIdentifier: $0).map(RelayZoneArchive.init)) }
        relayPhase = relay == nil && relayReads == nil ? .unavailable : .idle
        history = HistoryStore(directory: directory)
        self.directory = directory
        alertLedger = AlertLedger.load(from: directory)
        alertPreferences = defaults.data(forKey: Keys.alertPreferences).flatMap { try? JSONDecoder().decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        cacheURL = directory?.appendingPathComponent(ReadingCache.fileName)
        sampleMode = defaults.bool(forKey: Keys.sampleMode)
        hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        widgetArrangement = WidgetArrangement.load(from: defaults)
        #if DEBUG
        let arguments = launchDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if let sample = arguments[Keys.sampleMode] as? String { sampleMode = sample == "YES" }
        if let onboarded = arguments[Keys.onboarded] as? String { hasOnboarded = onboarded == "YES" }
        #endif
        keyedProviders = (defaults.array(forKey: Keys.keyedProviders) as? [String] ?? []).compactMap(Provider.init(rawValue:))
        let savedSessions = (defaults.array(forKey: Keys.sessionProviders) as? [String] ?? []).compactMap(Provider.init(rawValue:))
        sessionProviders = sessions == nil ? [] : savedSessions.filter { PhoneConnect.productionAllowlist.contains($0) }
        if sessions == nil {
            defaults.removeObject(forKey: Keys.sessionProviders)
        } else if sessionProviders != savedSessions {
            defaults.set(sessionProviders.map(\.rawValue), forKey: Keys.sessionProviders)
        }
        showCachedReadings()
    }

    func refresh(force: Bool = false, includeKeys: Bool = true, manual: Bool = false, now fixedNow: Date? = nil) async {
        guard allowsExternalEffects else { return }
        let now = fixedNow ?? .now
        if manual, relayConnectionFailed {
            relayRetryAt = nil
        }
        if !sampleMode, cacheGeneration != PhoneCacheAccess.generation(in: defaults) {
            rebuild(now: now)
        }
        if !force, !isDue(readingKeys: includeKeys, now: now) { return }
        if let running {
            let next = queuePass(after: running, readsKeys: includeKeys, manual: manual, now: fixedNow)
            _ = await TimeLimit.run(Self.passWait, otherwise: ()) { await next.value }
            return
        }
        let previousKeyRefresh = lastKeyRefresh
        lastRefresh = now
        if includeKeys {
            lastKeyRefresh = now
        }
        let pass = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPass(readsKeys: includeKeys, manual: manual, now: now, clock: { fixedNow ?? .now })
        }
        running = pass
        isRefreshing = true
        await withTaskCancellationHandler {
            await pass.value
        } onCancel: {
            pass.cancel()
        }
        if pass.isCancelled, includeKeys, lastKeyRefresh == now {
            lastKeyRefresh = previousKeyRefresh
        }
        if running == pass {
            running = nil
            isRefreshing = false
        }
    }

    private func queuePass(after running: Task<Void, Never>, readsKeys: Bool, manual: Bool = false, now: Date?) -> Task<Void, Never> {
        queuedReadsKeys = queuedReadsKeys || readsKeys
        queuedManual = queuedManual || manual
        if let now {
            queuedNow = now
        }
        if let queued {
            return queued
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await running.value
            guard let self, !Task.isCancelled else { return }
            if self.running == running {
                self.running = nil
                self.isRefreshing = false
            }
            let readsKeys = self.queuedReadsKeys
            let manual = self.queuedManual
            let now = self.queuedNow
            self.queued = nil
            self.queuedReadsKeys = false
            self.queuedManual = false
            self.queuedNow = nil
            await self.refresh(force: true, includeKeys: readsKeys, manual: manual, now: now)
        }
        queued = task
        return task
    }

    func keepCurrent(
        interval: TimeInterval = MobileStore.liveInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        while !Task.isCancelled {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            await refresh()
        }
    }

    private func isDue(readingKeys: Bool, now: Date) -> Bool {
        guard let last = readingKeys ? lastKeyRefresh : lastRefresh else { return true }
        return !(0..<Self.foregroundInterval).contains(now.timeIntervalSince(last))
    }

    private func refreshPass(readsKeys: Bool, manual: Bool = false, now: Date, clock: @escaping @Sendable () -> Date) async {
        history.takePending(now: now)
        async let relayRead: Void = readRelayAndPresent(now: now, clock: clock)
        async let keyRead: Void = readsKeys ? readKeys(now: now) : ()
        async let sessionRead: Void = readsKeys ? readSessions(now: now, manual: manual) : ()
        _ = await (relayRead, keyRead, sessionRead)
        guard !Task.isCancelled else { return }

        followTimeZone()
        rebuild(now: clock())
        await liveActivityUpdate?.value
        await publish(now: now)
        await sendAlerts(now: now)
        history.saveIfNeeded()
        guard readsKeys else { return }
        await pruneEvents(now: now)
        if relayPhase == .ready, !subscriptionsCurrent {
            await prepareNotifications()
        }
    }

    private func readRelayAndPresent(now: Date, clock: @escaping @Sendable () -> Date) async {
        await readRelay(now: now, clock: clock)
        guard !Task.isCancelled, relay != nil || relayReads != nil else { return }
        rebuild(now: clock())
    }

    private func readRelay(now: Date, clock: @escaping @Sendable () -> Date) async {
        let known = RelaySourceRefresh.names(in: relaySnapshot) + [sourceID]
        guard let reads = relayReads ?? relay.map({ relay in
            MobileRelayReads(accountStatus: { try await relay.accountStatus() }, contents: { try await relay.contents(known: known) },
                             sources: { try await relay.sources(named: $0) })
        }) else {
            relayPhase = .unavailable
            return
        }
        if isWaitingForRelay(now) { return }
        let generation = relayGeneration
        if relaySources.isEmpty {
            relayPhase = .loading
        }
        var byName: Task<CloudRelay.SourceRead?, Never>?
        defer { byName?.cancel() }
        do {
            let account = try await Self.iCloud { try await reads.accountStatus() }
            guard relayGeneration == generation, !Task.isCancelled else { return }
            switch account {
            case .available:
                break
            case .noAccount:
                SyncHealthLog.record(.cloudRead, .noAccount, in: defaults)
                resetRelayAccount(phase: .noAccount)
                return
            default:
                SyncHealthLog.record(.cloudRead, .unavailable, in: defaults)
                relayPhase = .failed(RelayErrorPolicy.unusableAccount(account) ?? "Couldn't reach iCloud.")
                return
            }
            let names = RelaySourceRefresh.names(in: relaySnapshot)
            if let read = reads.sources, !names.isEmpty {
                byName = Task { try? await Self.iCloud { try await read(names) } }
            }
            let readStartedAt = Date()
            let contents = try await Self.iCloud { try await reads.contents() }
            guard relayGeneration == generation, !Task.isCancelled else { return }
            ownRecord = contents.sources.first { $0.id == sourceID }?.envelope
            relaySources = contents.sources.filter { $0.id != sourceID }
            relayHistories = contents.histories
            relayRetryAt = nil
            relayConnectionFailed = false
            let readAt = clock()
            cloudReadAt = readAt
            relaySnapshot = ReadingCache.RelaySnapshot(checkedAt: readAt, sources: contents.sources.compactMap { source in
                source.envelope.map { ReadingCache.SourceSnapshot(RelayMerge.Source(
                    id: source.id, label: source.label, envelope: $0, kind: CollectorKind(recordKind: source.kind)
                )) }
            })
            relayReadOnce = true
            guard !contents.deletedByUser else {
                handleRelayError(CKError(.userDeletedZone), now: clock())
                return
            }
            relayPhase = .ready
            SyncHealthLog.record(.cloudRead, .ok, in: defaults)
            adoptPreferences(contents.alertPreferences, readStartedAt: readStartedAt)
        } catch {
            guard relayGeneration == generation, !Task.isCancelled else { return }
            SyncHealthLog.record(.cloudRead, error is ICloudTimeout ? .timedOut : .failed, in: defaults)
            logger.error("relay read failed: \(String(describing: error), privacy: .public)")
            if Self.allowsSourcesByName(after: error), let read = await byName?.value,
               relayGeneration == generation, !Task.isCancelled, adoptSourcesByName(read, now: clock()) {
                SyncHealthLog.record(.cloudRead, .ok, in: defaults)
                scheduleRelayRecovery()
                return
            }
            handleRelayError(error, now: clock())
            scheduleRelayRecovery()
        }
    }

    private static func allowsSourcesByName(after error: any Error) -> Bool {
        if error is ICloudTimeout || error is RelayDirectRead.Incomplete { return true }
        guard let error = error as? CKError else { return false }
        return error.retryAfterSeconds == nil
            && ![.notAuthenticated, .requestRateLimited, .zoneBusy, .serviceUnavailable].contains(error.code)
    }

    private func adoptSourcesByName(_ read: CloudRelay.SourceRead, now: Date) -> Bool {
        guard let snapshot = relaySnapshot, !read.sources.isEmpty || !read.missing.isEmpty else { return false }
        let contents = RelaySourceRefresh.contents(from: snapshot, histories: relayHistories, read: read, now: now)
        if let own = contents.sources.first(where: { $0.id == sourceID }) {
            ownRecord = own.envelope
        } else if read.missing.contains(sourceID) {
            ownRecord = nil
        }
        relaySources = contents.sources.filter { $0.id != sourceID }
        relayHistories = contents.histories
        relaySnapshot = ReadingCache.RelaySnapshot(checkedAt: snapshot.checkedAt, sources: contents.sources.compactMap { source in
            source.envelope.map { ReadingCache.SourceSnapshot(RelayMerge.Source(
                id: source.id, label: source.label, envelope: $0, kind: CollectorKind(recordKind: source.kind)
            )) }
        }, removed: RelaySourceRefresh.removals(of: snapshot, after: read, now: now))
        cloudReadAt = now
        relayRetryAt = nil
        relayConnectionFailed = false
        relayReadOnce = true
        if case .failed = relayPhase { relayPhase = .ready }
        if relayPhase == .loading { relayPhase = .ready }
        return true
    }

    func accountChanged() {
        running?.cancel()
        queued?.cancel()
        queued = nil
        queuedReadsKeys = false
        queuedNow = nil
        lastKeyRefresh = nil
        resetRelayAccount(phase: relay == nil ? .unavailable : .idle)
        rebuild()
    }

    private func resetRelayAccount(phase: RelayPhase, invalidateCache: Bool = true) {
        let previous = cacheURL.flatMap(ReadingCache.load).flatMap {
            !$0.isSample && $0.accountGeneration == cacheGeneration ? $0 : nil
        }
        let retainedLocal = previous?.localSource?.envelope.providers
            ?? previous?.items.filter { $0.source == Self.localLabel }.map(\.provider) ?? []
        if invalidateCache { PhoneCacheAccess.invalidate(in: defaults) }
        cacheGeneration = PhoneCacheAccess.generation(in: defaults)
        relayGeneration = UUID()
        relaySources = []
        relayHistories = [:]
        ownRecord = retainedLocal.isEmpty ? nil : RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version,
                                                               checkedAt: .now, providers: retainedLocal)
        relayReadOnce = true
        relayRetryAt = nil
        relayConnectionFailed = false
        cloudReadAt = nil
        relaySnapshot = nil
        relayRecovery?.cancel()
        relayRecovery = nil
        preferencesBase = nil
        preferencesSharedAt = nil
        sharingPreferences?.cancel()
        sharingPreferences = nil
        shareAgain = false
        preparingNotifications?.cancel()
        preparingNotifications = nil
        subscriptionsCurrent = false
        publishPolicy.reset()
        lastHistoryHour = nil
        unclaimed = []
        defaults.set(false, forKey: Keys.published)
        defaults.set(false, forKey: Keys.alertPreferencesShared)
        defaults.set(false, forKey: Keys.alertsFiltered)
        defaults.removeObject(forKey: Keys.prunedAt)
        relayPhase = phase
    }

    var watchReadings: ReadingCache? {
        guard !sampleMode, let cache = PhoneCacheAccess.load(at: cacheURL, defaults: defaults), !cache.isSample else { return nil }
        return cache.applyingLocalBudgetReferences(in: defaults)
    }

    private var preferencesBase: AlertPreferences? {
        get { defaults.data(forKey: Keys.alertPreferencesBase).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? RelayEnvelope.encoder.encode($0) }, forKey: Keys.alertPreferencesBase) }
    }

    private func adoptPreferences(_ remote: AlertPreferences?, readStartedAt: Date) {
        guard sharingPreferences == nil else { return }
        if let preferencesSharedAt, readStartedAt < preferencesSharedAt { return }
        let resolution = AlertPreferencesSync.resolve(base: preferencesBase, local: alertPreferences, remote: remote)
        if resolution.needsPublish {
            defaults.set(false, forKey: Keys.alertPreferencesShared)
        } else if let remote, resolution.preferences.sameChoices(as: remote) {
            preferencesBase = remote
            defaults.set(true, forKey: Keys.alertPreferencesShared)
        }
        take(resolution.preferences)
    }

    private func take(_ preferences: AlertPreferences) {
        guard preferences != alertPreferences else { return }
        let subscriptionsChange = preferences.subscribedKeys != alertPreferences.subscribedKeys
        adoptingPreferences = true
        alertPreferences = preferences
        adoptingPreferences = false
        if subscriptionsChange {
            Task { await prepareNotifications() }
        }
    }

    private func followTimeZone() {
        let zone = TimeZone.current.identifier
        guard !sampleMode, defaults.string(forKey: Keys.followedTimeZone) != zone else { return }
        defaults.set(zone, forKey: Keys.followedTimeZone)
        guard alertPreferences.timeZoneID != zone else { return }
        followingTimeZone = true
        alertPreferences.timeZoneID = zone
        followingTimeZone = false
    }

    private var preferencesHere: AlertPreferences {
        var preferences = alertPreferences
        preferences.timeZoneID = TimeZone.current.identifier
        return preferences
    }

    static let iCloudBudget: TimeInterval = 20

    private struct ICloudTimeout: Error {}

    private static func iCloud<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = await TimeLimit.run(iCloudBudget, otherwise: Result<T, any Error>.failure(ICloudTimeout())) {
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        if case .failure(let error) = result, error is ICloudTimeout, Task.isCancelled {
            throw CancellationError()
        }
        return try result.get()
    }

    private func isWaitingForRelay(_ now: Date) -> Bool {
        guard let relayRetryAt, relayRetryAt > now else { return false }
        return relayRetryAt.timeIntervalSince(now) <= 3600
    }

    private func handleRelayError(_ error: Error, now: Date = .now) {
        relayConnectionFailed = error is ICloudTimeout || RelayErrorPolicy.isConnectionFailure(error)
        let outcome: RelayErrorPolicy.Outcome = error is ICloudTimeout
            ? .retry(after: Self.connectionRetry, message: "Couldn't reach iCloud. Trying again soon.")
            : RelayErrorPolicy.outcome(for: error, defaultRetry: RelayPublishPolicy.minimumInterval, networkRetry: Self.connectionRetry)
        switch outcome {
        case .noAccount:
            resetRelayAccount(phase: .noAccount)
        case .paused(let message), .failed(let message):
            relayPhase = .failed(message)
        case .retry(let after, let message):
            relayRetryAt = now.addingTimeInterval(after)
            relayPhase = .failed(message)
        case .unavailable:
            relayPhase = .unavailable
        case .cancelled:
            break
        }
    }

    private func scheduleRelayRecovery() {
        guard relayConnectionFailed, relayRecovery == nil, !platformEffects.applicationIsBackground() else { return }
        relayRecovery = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Self.connectionRetry)) } catch { return }
            guard let self else { return }
            defer { self.relayRecovery = nil }
            guard !Task.isCancelled, self.relayConnectionFailed, !self.platformEffects.applicationIsBackground() else { return }
            await self.refresh(force: true, includeKeys: false)
        }
    }

    private func readKeys(now: Date) async {
        let keys = self.keys
        guard let lookups = await keyDiscovery.read(within: credentialDiscoveryBudget, operation: {
            await BlockingIO.run {
                Provider.allCases.filter(\.readsWithKey).reduce(into: [Provider: APIKeyStore.Lookup]()) { lookups, provider in
                    lookups[provider] = keys.lookup(for: provider)
                }
            }
        }), !Task.isCancelled else { return }
        let unreadable = Set(lookups.filter { $0.value == .unreadable }.keys)
        let providers = Provider.allCases.filter { provider in
            if case .found = lookups[provider] { return true }
            return unreadable.contains(provider) && keyedProviders.contains(provider)
        }
        keyedProviders = providers
        keysRead = true
        defaults.set(providers.map(\.rawValue), forKey: Keys.keyedProviders)
        for provider in localStatuses.keys where provider.readsWithKey && !providers.contains(provider) {
            localStatuses[provider] = nil
            localCheckedAt[provider] = nil
            localFailedAt[provider] = nil
        }
        let gate = keyGate
        var claims: [Provider: KeyFetchGate.FetchClaim] = [:]
        for provider in providers where !unreadable.contains(provider) {
            if let until = rateLimitedUntil[provider], until > now { continue }
            claims[provider] = gate.claim(provider, at: now)
        }
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for (provider, claim) in claims {
                if localStatuses[provider] == nil {
                    localStatuses[provider] = .loading
                }
                group.addTask {
                    await (provider, APIKeyClient(provider: provider, keys: keys).fetchWithinBudget(onWorkFinished: { result in gate.complete(claim, result: result) }))
                }
            }
            for await (provider, result) in group {
                if Task.isCancelled, case .failure = result {
                    if let claim = claims[provider] { gate.restoreAttempt(claim) }
                    if localStatuses[provider] == .loading {
                        localStatuses[provider] = nil
                    }
                    continue
                }
                apply(provider, result: result, now: now)
            }
        }
    }

    private func readSessions(now: Date, manual: Bool = false) async {
        guard let sessions, let refresher else { return }
        let owners = Array(Set(PhoneSignIn.providers.map(PhoneSignIn.sessionOwner)))
        guard let lookups = await sessionDiscovery.read(within: credentialDiscoveryBudget, operation: {
            await BlockingIO.run {
                owners.reduce(into: [Provider: PhoneSessionStore.Lookup]()) { lookups, owner in
                    lookups[owner] = sessions.lookup(for: owner)
                }
            }
        }), !Task.isCancelled else { return }
        let unreadable = Set(lookups.filter { $0.value == .unreadable }.keys)
        let signedIn = PhoneSignIn.providers.filter { provider in
            let owner = PhoneSignIn.sessionOwner(for: provider)
            guard PhoneConnect.productionAllowlist.contains(provider) else { return false }
            if case .found = lookups[owner] { return true }
            return unreadable.contains(owner) && sessionProviders.contains(provider)
        }
        let skipped = notOnPlan.filter { signedIn.contains($0.key) }
        let gate = keyGate
        let heldOff = { [rateLimitedUntil] (provider: Provider) -> Bool in
            if let until = rateLimitedUntil[provider], until > now { return true }
            if let last = gate.lastAttempt(provider), (0..<PhoneSignIn.minimumInterval).contains(now.timeIntervalSince(last)) { return true }
            return gate.isResting(provider, now: now)
        }
        let wasPaused = Set((defaults.array(forKey: MacCoveragePause.defaultsKey) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        let coverage = coverage
        let decided = Set(signedIn.filter { provider in
            MacCoveragePause.remembered(macAge: PhoneConnect.macReadingAge(provider, sources: coverage, now: now),
                                        wasPaused: wasPaused.contains(provider))
        })
        let paused = manual ? [] : decided
        if decided != wasPaused {
            logger.notice("session reads paused for a Mac: \(decided.count, privacy: .public)")
        }
        pausedSessions = paused
        defaults.set(decided.isEmpty ? nil : decided.map(\.rawValue).sorted(), forKey: MacCoveragePause.defaultsKey)
        let plan = PhoneSignIn.plansToRead(signedIn: signedIn, notOnPlan: skipped, now: now, paused: paused, isHeldOff: heldOff)
        let providers = plan.listed
        let recheck = plan.rechecks
        setSessionProviders(providers)
        for provider in localStatuses.keys where PhoneSignIn.method(for: provider) != nil && !providers.contains(provider) {
            localStatuses[provider] = nil
            localCheckedAt[provider] = nil
            localFailedAt[provider] = nil
        }
        refusedSessions = Set(lookups.compactMap { owner, lookup -> Provider? in
            if case .found(let metadata) = lookup, metadata.state == .rejected { return owner }
            return nil
        })
        let clientRefused = Set(lookups.compactMap { owner, lookup -> Provider? in
            if case .found(let metadata) = lookup, metadata.state == .rejected, metadata.clientRefused == true { return owner }
            return nil
        })
        let refused = Set(providers.filter { refusedSessions.contains(PhoneSignIn.sessionOwner(for: $0)) })
        for provider in refused {
            let owner = PhoneSignIn.sessionOwner(for: provider)
            let message = clientRefused.contains(owner) ? PhoneSessionClient.clientRefused : PhoneSessionClient.needsSignIn
            apply(provider, result: .failure(.signedOut(message)), now: now)
        }
        var claims: [Provider: KeyFetchGate.FetchClaim] = [:]
        for provider in plan.due where !refused.contains(provider) && !unreadable.contains(PhoneSignIn.sessionOwner(for: provider)) {
            claims[provider] = gate.claim(provider, at: now)
        }
        guard !claims.isEmpty else { return }
        let endBackgroundWork = platformEffects.beginBackgroundWork("Plan readings")
        defer { endBackgroundWork() }
        var newlySkipped: [Provider: Date] = [:]
        var onPlanAgain: Set<Provider> = []
        let sessionSend = sessionSend
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for (provider, claim) in claims {
                if localStatuses[provider] == nil, !recheck.contains(provider) {
                    localStatuses[provider] = .loading
                }
                let client = PhoneSessionClient(provider: provider, store: sessions, send: sessionSend(provider))
                let reader = PhoneSessionReader(client: client, refresher: refresher)
                group.addTask {
                    await (provider, TimeLimit.run(2 * TokenroomHTTP.fetchBudget, otherwise: .failure(.unreachable)) {
                        let result = await reader.read(now: now)
                        gate.complete(claim, result: result, at: now)
                        return result
                    })
                }
            }
            for await (provider, result) in group {
                if Task.isCancelled, case .failure = result {
                    if let claim = claims[provider] { gate.restoreAttempt(claim) }
                    if localStatuses[provider] == .loading {
                        localStatuses[provider] = nil
                    }
                    continue
                }
                let notEntitled: Bool = if case .failure(.notEntitled) = result { true } else { false }
                let recheckFailed: Bool = if recheck.contains(provider), case .failure = result { true } else { false }
                if PhoneSignIn.sessionOwner(for: provider) != provider, notEntitled || recheckFailed {
                    newlySkipped[provider] = now
                    localStatuses[provider] = nil
                    localCheckedAt[provider] = nil
                    localFailedAt[provider] = nil
                    setSessionProviders(sessionProviders.filter { $0 != provider })
                    continue
                }
                if case .success = result {
                    onPlanAgain.insert(provider)
                }
                apply(provider, result: result, now: now)
            }
        }
        var current = notOnPlan
        current.merge(newlySkipped) { $1 }
        for provider in onPlanAgain { current[provider] = nil }
        notOnPlan = current
    }

    private var notOnPlan: [Provider: Date] {
        get {
            let saved = defaults.dictionary(forKey: Keys.sessionNotOnPlan) as? [String: Date] ?? [:]
            return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in Provider(rawValue: key).map { ($0, value) } })
        }
        set {
            defaults.set(newValue.isEmpty ? nil : Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) }), forKey: Keys.sessionNotOnPlan)
        }
    }

    private func setSessionProviders(_ providers: [Provider]) {
        sessionProviders = providers
        defaults.set(providers.map(\.rawValue), forKey: Keys.sessionProviders)
    }

    private func apply(_ provider: Provider, result: Result<QuotaSnapshot, ProviderError>, now: Date) {
        switch result {
        case .success(let raw):
            localStatuses[provider] = .live(raw)
            localCheckedAt[provider] = raw.fetchedAt
            localFailedAt[provider] = nil
            rateLimitedUntil[provider] = nil
            history.record(raw.applyingBudget(reference: budgetReference(for: provider)), now: now)
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: localStatuses[provider]?.snapshot, lastChecked: localCheckedAt[provider], now: now)
            if let until = ProviderStatus.retryDate(after: error, now: now) {
                rateLimitedUntil[provider] = until
            }
            localStatuses[provider] = next
            localFailedAt[provider] = now
        }
    }

    private func budgeted(_ status: ProviderStatus, for provider: Provider) -> ProviderStatus {
        let reference = budgetReference(for: provider)
        switch status {
        case .live(let snapshot):
            return .live(snapshot.applyingBudget(reference: reference))
        case .stale(let snapshot):
            return .stale(snapshot.applyingBudget(reference: reference))
        case .expired(let message, let cached):
            return .expired(message, cached: cached?.applyingBudget(reference: reference))
        case .rateLimited(let until, let cached):
            return .rateLimited(until: until, cached: cached?.applyingBudget(reference: reference))
        case .unreachable(let cached):
            return .unreachable(cached: cached?.applyingBudget(reference: reference))
        case .loading, .signedOut, .notEntitled:
            return status
        }
    }

    private func showCachedReadings() {
        if sampleMode {
            rebuild()
            return
        }
        guard let cacheURL, let saved = PhoneCacheAccess.load(at: cacheURL, defaults: defaults), !saved.isSample else { return }
        let cache = saved.applyingLocalBudgetReferences(in: defaults)
        storedReadings = cache.items.map { Reading($0) }
        coverage = cache.carriedSources(excluding: Self.localLabel).map(\.source).covering
        lastSavedCache = saved
        cloudReadAt = saved.cloudReadAt
        lastHandoverRunOuts = saved.runOuts
        lastHandoverChecks = WatchHandoffSchedule.checks(in: saved)
    }

    func ageReadings(at date: Date) { presentationNow = date }

    @discardableResult
    private func reconcileCachedRelay(now: Date) -> Bool {
        guard let cache = PhoneCacheAccess.load(at: cacheURL, defaults: defaults), !cache.isSample,
              let snapshot = cache.relaySnapshot
        else { return false }
        guard !relayReadOnce || (relaySnapshot?.checkedAt ?? cloudReadAt).map({
            ReadingFreshness.ownOrdering(snapshot.checkedAt, now: now) > ReadingFreshness.ownOrdering($0, now: now)
        }) ?? true else {
            return adoptNewerCopies(from: snapshot, cloudReadAt: cache.cloudReadAt, now: now)
        }
        relaySnapshot = snapshot
        cloudReadAt = [cloudReadAt, cache.cloudReadAt ?? snapshot.checkedAt].compactMap(\.self)
            .max { ReadingFreshness.ownOrdering($0, now: now) < ReadingFreshness.ownOrdering($1, now: now) }
        relayReadOnce = true
        ownRecord = snapshot.sources.first { $0.id == sourceID }?.envelope
        relaySources = snapshot.sources.filter { $0.id != sourceID }.map { source in
            CloudRelay.Source(id: source.id, kind: source.kind == .mac ? "mac" : "iphone", label: source.label,
                              modifiedAt: source.envelope.checkedAt, envelope: source.envelope, needsNewerApp: false)
        }
        let sourceIDs = Set(snapshot.sources.map(\.id))
        relayHistories = relayHistories.filter { sourceIDs.contains($0.key) }
        for item in cache.items {
            guard let sourceID = item.sourceID, sourceIDs.contains(sourceID) else { continue }
            for (window, history) in item.history {
                relayHistories[sourceID, default: RelayHistory(series: [:])].series[RelayHistory.key(provider: item.id, window: window)] = history
            }
        }
        return true
    }

    private func adoptNewerCopies(from snapshot: ReadingCache.RelaySnapshot, cloudReadAt cached: Date?, now: Date) -> Bool {
        let order = { (date: Date) in ReadingFreshness.ordering(date, now: now) }
        var changed = false
        for copy in snapshot.sources where copy.envelope.isReadable {
            if copy.id == sourceID {
                if let own = ownRecord, order(copy.envelope.checkedAt) > order(own.checkedAt) {
                    ownRecord = copy.envelope
                    changed = true
                }
                continue
            }
            guard let index = relaySources.firstIndex(where: { $0.id == copy.id }),
                  let kept = relaySources[index].envelope, order(copy.envelope.checkedAt) > order(kept.checkedAt)
            else { continue }
            relaySources[index].envelope = copy.envelope
            changed = true
        }
        let membershipAt = relaySnapshot?.checkedAt ?? snapshot.checkedAt
        var removed = relaySnapshot?.removals(after: membershipAt, now: now) ?? [:]
        for (id, date) in snapshot.removals(after: membershipAt, now: now) where id != sourceID {
            guard removed[id].map({ order(date) > order($0) }) ?? true else { continue }
            removed[id] = date
            if relaySources.contains(where: { $0.id == id }) {
                relaySources.removeAll { $0.id == id }
                relayHistories[id] = nil
                changed = true
            }
        }
        guard changed else { return false }
        if var current = relaySnapshot {
            current.sources = current.sources.compactMap { known in
                guard removed[known.id] == nil else { return nil }
                return snapshot.sources.first { $0.id == known.id && order($0.envelope.checkedAt) > order(known.envelope.checkedAt) } ?? known
            }
            current.removed = removed.isEmpty ? nil : removed
            relaySnapshot = current
        }
        if let cached, cloudReadAt.map({ ReadingFreshness.ownOrdering(cached, now: now) > ReadingFreshness.ownOrdering($0, now: now) }) ?? true {
            cloudReadAt = cached
        }
        return true
    }

    private func rebuild(now: Date = .now) {
        presentationNow = now
        if sampleMode {
            let cache = SampleData.cache(now: now)
            storedReadings = cache.items.map { Reading($0, now: now) }
            disconnected = []
            coverage = []
            saveCache(cache)
            return
        }

        if cacheGeneration != PhoneCacheAccess.generation(in: defaults) {
            running?.cancel()
            queued?.cancel()
            queued = nil
            queuedReadsKeys = false
            queuedNow = nil
            lastKeyRefresh = nil
            resetRelayAccount(phase: relay == nil ? .unavailable : .idle, invalidateCache: false)
        }
        reconcileCachedRelay(now: now)

        var sources = relaySources.compactMap { source in
            source.envelope.map { RelayMerge.Source(id: source.id, label: source.label, envelope: $0, kind: CollectorKind(recordKind: source.kind)) }
        }
        var histories = relayHistories
        if !relayReadOnce, let previous = PhoneCacheAccess.load(at: cacheURL, defaults: defaults) {
            for carried in previous.carriedSources(excluding: Self.localLabel) {
                sources.append(carried.source)
                histories[carried.source.id] = carried.history
            }
        }
        coverage = sources.covering
        let own = localEnvelope(now: now)
        if !own.providers.isEmpty {
            sources.append(RelayMerge.Source(id: sourceID, label: Self.localLabel, envelope: own, kind: .thisPhone))
            histories[sourceID] = RelayHistory(series: history.weeks)
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: histories, now: now)
        storedReadings = output.connected.map { Reading($0, now: now) }
        disconnected = output.disconnected.map { Reading($0, now: now) }
        var cache = ReadingCache(savedAt: now, isSample: false, items: output.connected)
        cache.cloudReadAt = cloudReadAt
        cache.relaySnapshot = relaySnapshot
        cache.localSource = ReadingCache.SourceSnapshot(RelayMerge.Source(
            id: sourceID, label: Self.localLabel, envelope: own, kind: .thisPhone
        ))
        saveCache(cache)
        guard allowsExternalEffects else { return }
        let providers = output.connected.map(\.provider)
        let preferences = preferencesHere
        let samples = recentSamples(for: providers)
        let previous = liveActivityUpdate
        let effects = platformEffects
        liveActivityUpdate = Task {
            await previous?.value
            await effects.updateLiveActivities(providers, preferences, samples, now)
        }
    }

    private func recentSamples(for providers: [RelayProvider]) -> [String: [String: [(date: Date, used: Double)]]] {
        var samples: [String: [String: [(date: Date, used: Double)]]] = [:]
        for provider in providers {
            guard let key = Provider(rawValue: provider.id) else { continue }
            for window in provider.windows where window.isMetered {
                let recent = history.samples(provider: key, window: window.id)
                if !recent.isEmpty {
                    samples[provider.id, default: [:]][window.id] = recent
                }
            }
        }
        return samples
    }

    private func saveCache(_ cache: ReadingCache) {
        guard allowsExternalEffects, let cacheURL else { return }
        var cache = cache
        cache.accountGeneration = cacheGeneration
        do {
            guard try PhoneCacheAccess.save(cache, at: cacheURL, defaults: defaults, generation: cacheGeneration) else { return }
        } catch {
            logger.error("cache save failed: \(String(describing: error), privacy: .public)")
            return
        }
        let previous = lastSavedCache
        lastSavedCache = cache
        let changed = cache.materialHash(at: cache.savedAt) != previous?.materialHash(at: cache.savedAt)
        let runOuts = cache.runOuts
        let checks = WatchHandoffSchedule.checks(in: cache)
        let handover = changed || RelayPublishPolicy.runOutsMoved(runOuts, since: lastHandoverRunOuts)
                || WatchHandoffSchedule.checksMoved(checks, since: lastHandoverChecks)
        if handover, !cache.isSample {
            if let saved = PhoneCacheAccess.load(at: cacheURL, defaults: defaults) {
                platformEffects.sendToWatch(saved.applyingLocalBudgetReferences(in: defaults))
            }
            lastHandoverRunOuts = runOuts
            lastHandoverChecks = checks
        }
        if changed { changesGivenOut += 1 }
        reloadWidgets(for: cache, at: cache.savedAt)
    }

    private func reloadWidgets(for cache: ReadingCache, at now: Date, background: Bool? = nil) {
        guard allowsExternalEffects else { return }
        guard WidgetReloadSchedule.needsReload(cache, since: WidgetReloadSchedule.load(from: defaults), at: now,
            background: background ?? platformEffects.applicationIsBackground(),
            reloads: WidgetReloadLog.count(lastDayBefore: now, defaults: defaults)) else { return }
        platformEffects.reloadWidgets()
        WidgetReloadSchedule.record(cache, at: now, in: defaults)
    }

    func becameActive(now: Date = .now) {
        guard allowsExternalEffects else { return }
        if relayConnectionFailed {
            relayRetryAt = nil
            lastRefresh = nil
            lastKeyRefresh = nil
        }
        if reconcileCachedRelay(now: now) {
            rebuild(now: now)
        }
        if let cache = PhoneCacheAccess.load(at: cacheURL, defaults: defaults) {
            reloadWidgets(for: cache, at: now, background: false)
        }
    }

    func reading(id: String) -> Reading? {
        readings.first { $0.id == id } ?? disconnected.first { $0.id == id }
    }

    var lastChecked: Date? {
        readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min()
    }

    var latestChecked: Date? {
        readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max()
    }

    var sourceSummary: String? {
        UsageBoard.sourceSummary(readings.map(\.source))
    }

    func connectAction(for provider: Provider, now: Date = .now) -> PhoneConnect.Action {
        PhoneConnect.action(for: provider, sources: coverage, now: now)
    }

    func connectList(now: Date = .now) -> [(provider: Provider, action: PhoneConnect.Action)] {
        PhoneConnect.connectList(sources: coverage, now: now)
    }

    var needsNewerApp: Bool {
        relaySources.contains(where: \.needsNewerApp)
    }

    private static let standInLimit = RelayMerge.maxSourceAge

    private func localEnvelope(now: Date) -> RelayEnvelope {
        let saved = savedOwnReadings(now: now)
        let owned = keysRead || defaults.array(forKey: Keys.keyedProviders) != nil
            ? localProviders
            : Provider.allCases.filter { saved.readings[$0.rawValue] != nil || saved.statuses[$0.rawValue] != nil }
        let providers = owned.map { provider -> RelayProvider in
            let standIn = saved.readings[provider.rawValue]?.applyingBudget(reference: budgetReference(for: provider))
            guard let status = localStatuses[provider], status != .loading else {
                return standIn ?? saved.statuses[provider.rawValue] ?? RelayProvider(provider: provider, status: .loading, checkedAt: nil)
            }
            let mine = RelayProvider(provider: provider, status: budgeted(status, for: provider), checkedAt: localCheckedAt[provider])
            guard var standIn, !["signedOut", "expired", "notEntitled"].contains(mine.state),
                  let standInTime = Self.readingTime(standIn),
                  Self.readingTime(mine).map({ ReadingFreshness.ownOrdering(standInTime, now: now) > $0 }) ?? true
            else { return mine }
            if !mine.isLive, let failedAt = localFailedAt[provider], failedAt > standInTime {
                standIn.state = mine.state
                standIn.message = mine.message
            }
            return standIn
        }
        return RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: providers)
    }

    private func savedOwnReadings(now: Date) -> (readings: [String: RelayProvider], statuses: [String: RelayProvider]) {
        let cache = PhoneCacheAccess.load(at: cacheURL, defaults: defaults)
        let cached = cache.map {
            $0.isSample ? [] : ($0.localSource?.envelope.providers
                ?? $0.items.filter { $0.source == Self.localLabel }.map(\.provider))
        } ?? []
        var newest: [String: RelayProvider] = [:]
        for provider in (ownRecord?.providers ?? []) + cached {
            guard let time = Self.readingTime(provider), now.timeIntervalSince(time) < Self.standInLimit else { continue }
            if let kept = newest[provider.id], let keptTime = Self.readingTime(kept),
               ReadingFreshness.ownOrdering(keptTime, now: now) >= ReadingFreshness.ownOrdering(time, now: now) { continue }
            newest[provider.id] = provider
        }
        let envelopes = [ownRecord, cache?.isSample == false ? cache?.localSource?.envelope : nil]
            .compactMap { $0 }
            .filter { (0..<Self.standInLimit).contains(now.timeIntervalSince($0.checkedAt)) }
            .sorted { $0.checkedAt > $1.checkedAt }
        var statuses: [String: RelayProvider] = [:]
        for envelope in envelopes {
            for provider in envelope.providers where Self.readingTime(provider) == nil && !provider.isAwaitingFirstReading
                && newest[provider.id] == nil && statuses[provider.id] == nil {
                statuses[provider.id] = provider
            }
        }
        return (newest, statuses)
    }

    private static func readingTime(_ provider: RelayProvider) -> Date? {
        provider.checkedAt ?? provider.fetchedAt
    }

    private func publish(now: Date) async {
        let generation = relayGeneration
        guard let relay, relayPhase == .ready, !sampleMode, keysRead else { return }
        let published = defaults.bool(forKey: Keys.published)
        guard !localProviders.isEmpty || published else { return }
        var sending = localEnvelope(now: now)
        sending.providers.removeAll(where: \.isAwaitingFirstReading)
        let envelope = sending
        if let relayRetryAt, relayRetryAt > now { return }
        if publishPolicy.isDue(envelope, now: now) {
            do {
                let sourceID = sourceID
                try await Self.iCloud { try await relay.publish(sourceID: sourceID, kind: "iphone", label: "iPhone", envelope: envelope) }
                guard generation == relayGeneration, !Task.isCancelled else { return }
                publishPolicy.didSend(envelope, at: now)
                defaults.set(true, forKey: Keys.published)
                SyncHealthLog.record(.cloudWrite, .ok, in: defaults)
            } catch {
                guard generation == relayGeneration, !Task.isCancelled else { return }
                SyncHealthLog.record(.cloudWrite, error is ICloudTimeout ? .timedOut : .failed, in: defaults)
                logger.error("relay publish failed: \(String(describing: error), privacy: .public)")
                handleRelayError(error, now: now)
                return
            }
        }
        guard generation == relayGeneration, !Task.isCancelled else { return }
        let hour = UsageHistory.hourStart(now)
        let relayHistory = history.relayHistory(for: localProviders)
        guard lastHistoryHour != hour, !relayHistory.series.isEmpty else { return }
        do {
            let sourceID = sourceID
            try await Self.iCloud { try await relay.publishHistory(sourceID: sourceID, history: relayHistory) }
            guard generation == relayGeneration, !Task.isCancelled else { return }
            lastHistoryHour = hour
        } catch {
            logger.error("relay history failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendAlerts(now: Date) async {
        guard !sampleMode, !localStatuses.isEmpty else { return }
        await claimShownAlerts(now: now)
        let windowKey = { (provider: String, window: String) in
            provider + "/" + CopilotBilling.currentWindowID(provider: provider, window: window)
        }
        var coveredWindows = Set<String>()
        var coveredProviders = Set<String>()
        for envelope in relaySources.compactMap(\.envelope) where envelope.producer == "mac" && now.timeIntervalSince(envelope.checkedAt) < 3600 {
            for provider in envelope.providers where provider.isLive {
                coveredProviders.insert(provider.id)
                for window in provider.windows where window.isMetered {
                    coveredWindows.insert(windowKey(provider.id, window.id))
                }
            }
        }
        let isCovered = { (alert: UsageAlert) -> Bool in
            guard let window = alert.window else { return coveredProviders.contains(alert.provider) }
            return coveredWindows.contains(windowKey(alert.provider, window))
        }
        let preferences = preferencesHere
        let read = localProviders.compactMap { provider in
            localStatuses[provider].map { RelayProvider(provider: provider, status: budgeted($0, for: provider), checkedAt: localCheckedAt[provider]) }
        }
        alertLedger.process(read, preferences: preferences, samples: recentSamples(for: read), now: now)
        let due = alertLedger.due(preferences: preferences, now: now).filter { !isCovered($0) }
        alertLedger.save(to: directory)
        _ = await deliverAlerts(due, now: now)
    }

    func deliverAlerts(_ due: [UsageAlert], now: Date) async -> [String] {
        guard allowsExternalEffects else { return [] }
        let generation = relayGeneration
        var accepted: [String] = []
        for alert in due {
            guard generation == relayGeneration else { return accepted }
            guard !Task.isCancelled else { return accepted }
            guard alertLedger.sent[alert.id] == nil else { continue }
            let claimed = await claim(alert, now: now)
            guard !Task.isCancelled || generation != relayGeneration else { return accepted }
            let delivered: Bool
            let needsClaim: Bool
            switch claimed {
            case .ours:
                delivered = await notify(alert)
                needsClaim = generation != relayGeneration
            case .taken:
                delivered = true
                needsClaim = false
            case .unasked:
                delivered = await notify(alert)
                needsClaim = true
            }
            if delivered {
                if needsClaim {
                    var shown = unclaimed
                    if !shown.contains(where: { $0.alert.id == alert.id }) {
                        shown.append(ShownAlert(alert: alert, shownAt: now))
                        unclaimed = shown
                    }
                }
                accepted.append(alert.id)
                alertLedger.markSent([alert.id], at: now)
                alertLedger.save(to: directory)
            }
        }
        return accepted
    }

    enum Claim: Sendable {
        case ours
        case taken
        case unasked
    }

    private func claim(_ alert: UsageAlert, now: Date) async -> Claim {
        if let claimOverride { return await claimOverride(alert, now) }
        guard let relay, relayPhase == .ready, defaults.bool(forKey: Keys.alertsFiltered) else { return .unasked }
        do {
            if try await Self.iCloud({ try await relay.wentOutOnANeighbouringDay(alert, now: now) }) {
                return .taken
            }
            switch try await Self.iCloud({ try await relay.claimAlert(alert) }) {
            case .created, .shownElsewhere:
                return .ours
            case .pushed:
                return .taken
            }
        } catch {
            logger.error("alert claim failed: \(String(describing: error), privacy: .public)")
            return .unasked
        }
    }

    private struct ShownAlert: Codable {
        var alert: UsageAlert
        var shownAt: Date
    }

    private var unclaimed: [ShownAlert] {
        get { defaults.data(forKey: Keys.unclaimedAlerts).flatMap { try? JSONDecoder().decode([ShownAlert].self, from: $0) } ?? [] }
        set { defaults.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), forKey: Keys.unclaimedAlerts) }
    }

    private func claimShownAlerts(now: Date) async {
        let generation = relayGeneration
        let shown = unclaimed.filter { now.timeIntervalSince($0.shownAt) < AlertLedger.pendingLifetime }
        guard let relay, relayPhase == .ready, defaults.bool(forKey: Keys.alertsFiltered), !shown.isEmpty else {
            unclaimed = shown
            return
        }
        var left: [ShownAlert] = []
        for item in shown {
            guard generation == relayGeneration, !Task.isCancelled else { return }
            do {
                let alert = item.alert
                _ = try await Self.iCloud { try await relay.claimAlert(alert) }
            } catch {
                left.append(item)
            }
        }
        guard generation == relayGeneration, !Task.isCancelled else { return }
        unclaimed = left
    }

    private func notify(_ alert: UsageAlert) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.provider
        content.interruptionLevel = .active
        do {
            try await notificationScheduler(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
            return true
        } catch {
            logger.error("notification not scheduled: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func shareAlertPreferences() async {
        if let sharingPreferences {
            shareAgain = true
            await sharingPreferences.value
            return
        }
        let generation = relayGeneration
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                guard self.relayGeneration == generation, !Task.isCancelled else { return }
                self.shareAgain = false
                await self.sharePreferencesOnce()
            } while self.shareAgain && !Task.isCancelled
            if self.relayGeneration == generation { self.sharingPreferences = nil }
        }
        sharingPreferences = task
        await task.value
    }

    private func sharePreferencesOnce() async {
        let generation = relayGeneration
        guard let relay, relayPhase == .ready, !defaults.bool(forKey: Keys.alertPreferencesShared) else { return }
        let local = alertPreferences
        do {
            let base = preferencesBase
            let resolution = try await Self.iCloud { try await relay.syncAlertPreferences(base: base, local: local) }
            guard relayGeneration == generation, !Task.isCancelled else { return }
            if resolution.needsPublish {
                preferencesSharedAt = Date()
            }
            preferencesBase = resolution.preferences
            if alertPreferences.sameChoices(as: local) {
                defaults.set(true, forKey: Keys.alertPreferencesShared)
                take(resolution.preferences)
            } else {
                take(AlertPreferences.merged(base: local, local: alertPreferences, remote: resolution.preferences))
                shareAgain = true
            }
        } catch {
            logger.error("alert preferences not shared: \(String(describing: error), privacy: .public)")
        }
    }

    private func pruneEvents(now: Date) async {
        await shareAlertPreferences()
        let generation = relayGeneration
        guard let relay, relayPhase == .ready else { return }
        if let pruned = defaults.object(forKey: Keys.prunedAt) as? Date, now.timeIntervalSince(pruned) < 86_400 { return }
        do {
            try await Self.iCloud { try await relay.pruneEvents(now: now) }
            guard generation == relayGeneration, !Task.isCancelled else { return }
            defaults.set(now, forKey: Keys.prunedAt)
        } catch {
            logger.error("alert pruning failed: \(String(describing: error), privacy: .public)")
        }
    }

    func deleteICloudData() async throws {
        guard let relay else { return }
        try await relay.deleteAllData()
        relaySources = []
        relayHistories = [:]
        relayReadOnce = true
        let now = Date.now
        cloudReadAt = now
        relaySnapshot = .init(checkedAt: now, sources: [])
        publishPolicy.reset()
        lastHistoryHour = nil
        ownRecord = nil
        subscriptionsCurrent = false
        preferencesBase = nil
        defaults.set(false, forKey: Keys.published)
        defaults.set(false, forKey: Keys.alertPreferencesShared)
        rebuild()
        await prepareNotifications()
    }

    func backgroundRefresh() async {
        await scheduleBackgroundRefresh()
        await refresh(force: true)
        SyncHealthLog.record(.backgroundRefresh, Task.isCancelled ? .timedOut : .ok, in: defaults)
    }

    func refreshForPush() async -> Bool {
        let before = changesGivenOut
        await refresh(force: true, includeKeys: false)
        return changesGivenOut != before
    }

    func scheduleBackgroundRefresh(now: Date = .now) async {
        guard allowsExternalEffects else { return }
        do {
            try await platformEffects.scheduleBackgroundRefresh(now)
        } catch {
            logger.error("background refresh not scheduled: \(String(describing: error), privacy: .public)")
        }
    }

    @ObservationIgnored private var preparingNotifications: Task<Void, Never>?

    func prepareNotifications() async {
        guard allowsExternalEffects else { return }
        if let preparingNotifications { await preparingNotifications.value; return }
        guard let relay else { return }
        let generation = relayGeneration
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.relayGeneration == generation { self.preparingNotifications = nil } }
            repeat {
                guard self.relayGeneration == generation, !Task.isCancelled else { return }
                let keys = self.alertPreferences.subscribedKeys
                do {
                    let filtered = try await Self.iCloud { try await relay.ensureSubscriptions(alertKeys: keys) }
                    guard self.relayGeneration == generation, !Task.isCancelled else { return }
                    guard keys == self.alertPreferences.subscribedKeys else { continue }
                    self.defaults.set(filtered, forKey: Keys.alertsFiltered)
                    self.subscriptionsCurrent = true
                    return
                } catch {
                    guard self.relayGeneration == generation, !Task.isCancelled else { return }
                    self.subscriptionsCurrent = false
                    self.logger.error("subscriptions failed: \(String(describing: error), privacy: .public)")
                    return
                }
            } while !Task.isCancelled
        }
        preparingNotifications = task
        await task.value
    }

    func metadata(for provider: Provider) async -> APIKeyStore.Metadata? {
        let keys = self.keys
        return await BlockingIO.run { keys.metadata(for: provider) }
    }

    func saveKey(_ key: String, for provider: Provider, region: String?, warning: String? = nil, now: Date? = nil) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.save(key, for: provider, region: region, warning: warning, now: now ?? .now) }
        keyDiscovery.invalidate()
        keyedProviders = Provider.allCases.filter { $0 == provider || keyedProviders.contains($0) }
        defaults.set(keyedProviders.map(\.rawValue), forKey: Keys.keyedProviders)
        keyGate.reset(provider)
        rateLimitedUntil[provider] = nil
        publishPolicy.reset()
        hasOnboarded = true
        if sampleMode {
            sampleMode = false
        }
        await refresh(force: true, now: now)
    }

    func removeKey(for provider: Provider, now: Date? = nil) async throws {
        let keys = self.keys
        try await BlockingIO.run { try keys.remove(for: provider) }
        keyDiscovery.invalidate()
        localStatuses[provider] = nil
        localCheckedAt[provider] = nil
        localFailedAt[provider] = nil
        keyGate.reset(provider)
        rateLimitedUntil[provider] = nil
        keyedProviders.removeAll { $0 == provider }
        defaults.set(keyedProviders.map(\.rawValue), forKey: Keys.keyedProviders)
        publishPolicy.reset()
        await refresh(force: true, now: now)
    }

    func sessionMetadata(for provider: Provider) async -> PhoneSessionMetadata? {
        guard let sessions else { return nil }
        let owner = PhoneSignIn.sessionOwner(for: provider)
        return await BlockingIO.run { sessions.metadata(for: owner) }
    }

    func saveSession(_ session: PhoneSession, for provider: Provider, now: Date? = nil) async throws {
        guard let refresher, PhoneConnect.productionAllowlist.contains(provider) else { throw PhoneSessionStore.SessionError.encoding }
        let owner = PhoneSignIn.sessionOwner(for: provider)
        try await refresher.replace(owner, with: session, now: now ?? .now)
        sessionDiscovery.invalidate()
        let covered = PhoneSignIn.sharingSession(with: provider)
        setSessionProviders(PhoneSignIn.providers.filter { covered.contains($0) || sessionProviders.contains($0) })
        refusedSessions.remove(owner)
        notOnPlan = notOnPlan.filter { !covered.contains($0.key) }
        for plan in covered {
            localStatuses[plan] = nil
            localFailedAt[plan] = nil
            keyGate.reset(plan)
            rateLimitedUntil[plan] = nil
        }
        publishPolicy.reset()
        hasOnboarded = true
        if sampleMode {
            sampleMode = false
        }
        Task { await refresh(force: true, now: now) }
    }

    func removeSession(for provider: Provider, now: Date? = nil) async throws {
        guard let refresher else { return }
        let owner = PhoneSignIn.sessionOwner(for: provider)
        try await refresher.replace(owner, with: nil)
        sessionDiscovery.invalidate()
        let covered = PhoneSignIn.sharingSession(with: provider)
        for plan in covered {
            localStatuses[plan] = nil
            localCheckedAt[plan] = nil
            localFailedAt[plan] = nil
            keyGate.reset(plan)
            rateLimitedUntil[plan] = nil
        }
        refusedSessions.remove(owner)
        notOnPlan = notOnPlan.filter { !covered.contains($0.key) }
        setSessionProviders(sessionProviders.filter { !covered.contains($0) })
        publishPolicy.reset()
        await refresh(force: true, now: now)
    }

    func budgetUnit(for provider: Provider, region: String? = nil) -> String {
        let shown = (readings + disconnected).first { $0.id == provider.rawValue }?.provider
        return BudgetReferencePreferences.editorUnit(for: provider, region: region,
            readingUnit: localStatuses[provider]?.snapshot?.budgetUnit
                ?? shown?.windows.first { $0.amount != nil }?.amount?.unit)
    }

    func budgetCurrency(for provider: Provider, region: String? = nil) -> String {
        budgetUnit(for: provider, region: region).uppercased()
    }

    func budget(for provider: Provider) -> Double? {
        BudgetReferencePreferences.amount(in: defaults, for: provider)
    }

    func budgetReference(for provider: Provider) -> BudgetReference? {
        BudgetReferencePreferences.reference(in: defaults, for: provider)
    }

    func setBudget(_ value: Double?, for provider: Provider, unit: String? = nil) {
        var budgets = (defaults.dictionary(forKey: Keys.budgets) as? [String: Double]) ?? [:]
        if let value, (!value.isFinite || value <= 0) { return }
        let unit = unit ?? budgetUnit(for: provider)
        let reference = value.map { BudgetReference(amount: $0, unit: unit) }
        if let reference, !reference.isValid { return }
        var references = defaults.dictionary(forKey: Keys.budgetReferences) ?? [:]
        references[provider.rawValue] = reference?.propertyList
        budgets[provider.rawValue] = value
        defaults.set(budgets, forKey: Keys.budgets)
        defaults.set(references, forKey: Keys.budgetReferences)
        rebuild()
        Task { await publish(now: .now) }
    }

    var relayStatusText: String {
        switch relayPhase {
        case .idle, .loading: "Checking…"
        case .ready: "Connected"
        case .unavailable: relayIsInThisBuild ? "Can't access iCloud" : "Not available in this build"
        case .noAccount: "Sign in to iCloud in Settings"
        case .failed(let message): message
        }
    }
}
