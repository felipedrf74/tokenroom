import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class QuotaStore {
    var statuses: [Provider: ProviderStatus] = [:] { didSet { schedulePresentationClock() } }
    var checkedAt: [Provider: Date] = [:] { didSet { schedulePresentationClock() } }
    private(set) var presentationNow = Date.now
    var lastAttempt: Date?
    private(set) var nextTimedCheck: Date?
    var isRefreshing = false
    var settings: AppSettings
    var showsLegacyNotice: Bool
    var pendingKeyProvider: Provider?
    let signIn: SignInCoordinator
    let relay: RelayPublisher?
    let history: HistoryStore
    let news: NewsStore?
    private var alertLedger: AlertLedger

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var rateLimitedUntil: [Provider: Date] = [:]
    private var lastAttemptAt: [Provider: Date] = [:]
    private var rawSnapshots: [Provider: QuotaSnapshot] = [:]
    private var loopTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var timeZoneTask: Task<Void, Never>?
    @ObservationIgnored var currentTimeZone: () -> TimeZone = {
        NSTimeZone.resetSystemTimeZone()
        return .current
    }
    private var inFlight: Task<Void, Never>?
    private var followUp: Task<Void, Never>?
    private var followUpProviders: Set<Provider>? = []
    private var sharing: Task<Void, Never>?
    private var deferredSharing: Task<Void, Never>?
    private(set) var maintenance: Task<Void, Never>?
    private var maintenanceID: UUID?
    @ObservationIgnored var sharingClock: () -> Date = { .now }
    @ObservationIgnored var waitBeforeSharing: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    private var liveNews: Task<Void, Never>?
    private var newsLoop: Task<Void, Never>?
    @ObservationIgnored var waitForNextNewsCheck: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(for: .seconds($0))
    }
    private(set) var offlineRetry: Task<Void, Never>?
    nonisolated static let offlineRetryDelay: TimeInterval = 45
    var waitBeforeOfflineRetry: @Sendable () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(QuotaStore.offlineRetryDelay * 1_000_000_000))
    }
    private var shareAgain = false
    private var snapshotsDirty = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "refresh")

    init(
        settings: AppSettings = AppSettings(),
        clients: [any ProviderClient] = QuotaStore.defaultClients,
        cache: SnapshotCache = SnapshotCache(),
        relay: RelayPublisher? = nil,
        news: NewsStore? = nil,
        showsLegacyNotice: Bool = false
    ) {
        self.settings = settings
        self.clients = Dictionary(uniqueKeysWithValues: clients.map { ($0.provider, $0) })
        self.cache = cache
        self.relay = relay
        self.news = news
        self.history = HistoryStore(directory: cache.directory)
        self.alertLedger = AlertLedger.load(from: cache.directory)
        self.showsLegacyNotice = showsLegacyNotice
        self.signIn = SignInCoordinator()
        let cached = cache.load()
        checkedAt = cache.loadChecked()
        for provider in Provider.allCases {
            if let snapshot = cached[provider] {
                rawSnapshots[provider] = snapshot.applyingBudget(reference: nil)
                statuses[provider] = .stale(snapshot.applyingBudget(reference: settings.budgetReference(for: provider)))
            } else {
                statuses[provider] = .loading
            }
        }
        signIn.onConnected = { [weak self] provider in
            guard let self else { return }
            self.settings.setEnabled(provider, true)
            Task { await self.credentialsChanged(for: provider) }
        }
        news?.allowsRefresh = { [weak self] in self?.settings.newsEnabled == true }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.refresh(force: true)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "TokenroomSendTestAlert") {
                await self?.relay?.sendTestAlert()
            }
            #endif
            await self?.checkOnTimer()
        }
        schedulePresentationClock()
        startNewsLoop()
        wakeTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in notifications {
                self?.startNewsLoop()
                await self?.refresh(force: true)
            }
        }
        sleepTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification)
            for await _ in notifications {
                self?.willSleep()
            }
        }
        timeZoneTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange)
            for await _ in notifications {
                NSTimeZone.resetSystemTimeZone()
                self?.ageReadings(at: .now)
            }
        }
    }

    private func checkOnTimer() async {
        while !Task.isCancelled {
            let interval = max(settings.refreshInterval, 60)
            nextTimedCheck = Date().addingTimeInterval(interval)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await refresh()
        }
    }

    func setRefreshMinutes(_ minutes: Int) {
        guard settings.refreshMinutes != minutes else { return }
        settings.refreshMinutes = minutes
        guard loopTask != nil else { return }
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.checkOnTimer()
        }
    }

    func willSleep() {
        inFlight?.cancel()
        followUp?.cancel()
        sharing?.cancel()
        deferredSharing?.cancel()
        deferredSharing = nil
        maintenance?.cancel()
        maintenance = nil
        offlineRetry?.cancel()
        offlineRetry = nil
        newsLoop?.cancel()
        newsLoop = nil
        news?.cancelPass()
    }

    func startNewsLoop() {
        guard newsLoop == nil, news != nil else { return }
        newsLoop = Task { [weak self] in await self?.runNewsLoop() }
    }

    private func runNewsLoop() async {
        while !Task.isCancelled {
            guard let news else { return }
            if settings.newsEnabled {
                await news.refresh(preferences: settings.alertPreferences, notifies: settings.showsAlertsOnMac,
                                   waitsForFollowUp: true, cancellable: true)
            }
            let now = Date()
            let next = settings.newsEnabled ? NewsCadence.nextCheck(cache: news.cache, sources: news.sources, now: now) : now.addingTimeInterval(NewsCadence.longestWait)
            do {
                try await waitForNextNewsCheck(max(0, next.timeIntervalSince(now)))
            } catch {
                return
            }
        }
    }

    func stop() {
        presentationTask?.cancel()
        presentationTask = nil
        loopTask?.cancel()
        loopTask = nil
        nextTimedCheck = nil
        wakeTask?.cancel()
        wakeTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        timeZoneTask?.cancel()
        timeZoneTask = nil
        inFlight?.cancel()
        inFlight = nil
        followUp?.cancel()
        followUp = nil
        sharing?.cancel()
        sharing = nil
        deferredSharing?.cancel()
        deferredSharing = nil
        maintenance?.cancel()
        maintenance = nil
        offlineRetry?.cancel()
        offlineRetry = nil
        newsLoop?.cancel()
        newsLoop = nil
        signIn.cancel()
    }

    private func schedulePresentationClock() {
        guard loopTask != nil else { return }
        presentationTask?.cancel()
        presentationTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date.now
                self?.ageReadings(at: now)
                guard let next = self?.nextPresentationDate(after: now) else { return }
                try? await Task.sleep(for: .seconds(max(0.001, next.timeIntervalSince(now))))
            }
        }
    }

    func ageReadings(at date: Date) { presentationNow = date }

    func nextPresentationDate(after date: Date) -> Date {
        let boundaries = statuses.flatMap { provider, status -> [Date] in
            guard let snapshot = status.snapshot else { return [] }
            let checked = lastChecked(provider) ?? snapshot.fetchedAt
            return snapshot.windows.compactMap(\.resetsAt) + [checked.addingTimeInterval(ReadingFreshness.staleAfter + 0.001)]
        }
        return boundaries.filter { $0 > date }.min().map { min($0, date.addingTimeInterval(60)) }
            ?? date.addingTimeInterval(60)
    }

    func presentationStatus(for provider: Provider, at date: Date? = nil) -> ProviderStatus {
        let status = statuses[provider] ?? .loading
        if case .live(let snapshot) = status,
           (date ?? presentationNow).timeIntervalSince(lastChecked(provider) ?? snapshot.fetchedAt) > ReadingFreshness.staleAfter {
            return .stale(snapshot)
        }
        return status
    }

    func refreshIfStale(after seconds: TimeInterval = 45) async {
        if let lastAttempt, (0..<seconds).contains(Date().timeIntervalSince(lastAttempt)) {
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool = false, providers: [Provider]? = nil) async {
        if let followUp, followUp.isCancelled {
            await followUp.value
            await refresh(force: force, providers: providers)
            return
        }
        if let inFlight {
            if inFlight.isCancelled {
                await inFlight.value
                if self.inFlight == inFlight { self.inFlight = nil }
                await refresh(force: true, providers: providers)
                return
            }
            guard force else {
                await inFlight.value
                return
            }
            await joinFollowUp(after: inFlight, providers: providers).value
            return
        }
        if !force, let lastAttempt, (0..<15).contains(Date().timeIntervalSince(lastAttempt)) {
            return
        }
        await check(providers, waitsForSharing: force)
    }

    func credentialsChanged(for provider: Provider) async {
        if let inFlight {
            await inFlight.value
        }
        lastAttemptAt[provider] = nil
        rateLimitedUntil[provider] = nil
        clients[provider]?.credentialsChanged()
        await refresh(force: true, providers: [provider])
    }

    @discardableResult
    func setEnabled(_ provider: Provider, _ isOn: Bool) -> Task<Void, Never>? {
        guard settings.isEnabled(provider) != isOn else { return nil }
        settings.setEnabled(provider, isOn)
        return Task {
            if isOn {
                await refresh(force: true, providers: [provider])
            }
            relay?.providersChanged()
            await share()
        }
    }

    private func joinFollowUp(after running: Task<Void, Never>, providers: [Provider]?) -> Task<Void, Never> {
        if let providers, let asked = followUpProviders {
            followUpProviders = asked.union(providers)
        } else {
            followUpProviders = nil
        }
        if let followUp {
            return followUp
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            await running.value
            guard let self else { return }
            if self.inFlight == running {
                self.inFlight = nil
            }
            let asked = self.followUpProviders
            self.followUp = nil
            self.followUpProviders = []
            guard !Task.isCancelled else { return }
            await self.refresh(force: true, providers: asked.map { Array($0) })
        }
        followUp = task
        return task
    }

    private func check(_ providers: [Provider]?, waitsForSharing: Bool = true) async {
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNow(providers: providers)
        }
        inFlight = task
        await task.value
        if inFlight == task {
            inFlight = nil
        }
        guard !task.isCancelled else { return }
        if waitsForSharing {
            await share()
        } else {
            Task { await self.share() }
        }
    }

    func share() async {
        deferredSharing?.cancel()
        deferredSharing = nil
        if let sharing {
            if sharing.isCancelled {
                await sharing.value
                await share()
                return
            }
            shareAgain = true
            await sharing.value
            return
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.shareAgain = false
                await self.shareReadings(now: self.sharingClock())
            } while self.shareAgain && !Task.isCancelled
            self.sharing = nil
            if !Task.isCancelled {
                self.scheduleSharing()
                self.startMaintenance()
            }
        }
        sharing = task
        await task.value
    }

    private func scheduleSharing() {
        deferredSharing?.cancel()
        deferredSharing = nil
        let now = sharingClock()
        guard let due = relay?.nextPublishDate(relayEnvelope(at: now), now: now) else { return }
        let wait = waitBeforeSharing
        deferredSharing = Task { @MainActor [weak self] in
            do { try await wait(max(0.01, due.timeIntervalSince(now))) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.deferredSharing = nil
            await self.share()
        }
    }

    private func shareReadings(now: Date) async {
        let envelope = relayEnvelope(at: now)
        await relay?.publish(envelope, now: now)
        let relayed = Provider.allCases.filter { settings.isEnabled($0) }
        await relay?.publishHistory(history.relayHistory(for: relayed), now: now)
        await sendAlerts(for: envelope.providers, now: now)
    }

    private func startMaintenance() {
        guard maintenance == nil, let relay else { return }
        let now = sharingClock()
        let id = UUID()
        maintenanceID = id
        maintenance = Task { @MainActor [weak self] in
            await relay.pruneEventsIfDue(now: now)
            guard let self, self.maintenanceID == id else { return }
            self.maintenance = nil
        }
    }

    private func refreshNow(providers: [Provider]?) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        lastAttempt = now
        let earlierAttempts = lastAttemptAt
        var due: [Provider] = []
        var resting: [Provider] = []
        for provider in providers ?? Provider.allCases where settings.isEnabled(provider) {
            let sinceLast = lastAttemptAt[provider].map { now.timeIntervalSince($0) }
            if let until = rateLimitedUntil[provider], until > now, until.timeIntervalSince(now) <= ProviderStatus.longestRetry {
                resting.append(provider)
            } else if let sinceLast, sinceLast >= 0, sinceLast < provider.minimumInterval {
                resting.append(provider)
            } else {
                due.append(provider)
                lastAttemptAt[provider] = now
            }
        }
        let networkBefore = TokenroomHTTP.networkTally
        await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in due {
                guard let client = clients[provider] else { continue }
                group.addTask {
                    await (provider, client.fetchWithinBudget())
                }
            }
            var unreachable: [Provider] = []
            var signedOut: Set<Provider> = []
            for await (provider, result) in group {
                if Task.isCancelled, case .failure = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                    continue
                }
                if case .failure(.signedOut) = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                    signedOut.insert(provider)
                }
                if case .failure(.unreachable) = result {
                    unreachable.append(provider)
                }
                apply(provider: provider, result: result)
            }
            let networkAfter = TokenroomHTTP.networkTally
            let offline = networkAfter.answers == networkBefore.answers && networkAfter.offline > networkBefore.offline
            let called = due.filter { clients[$0] != nil && !signedOut.contains($0) }
            if !called.isEmpty, unreachable.count == called.count, offline {
                for provider in unreachable {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                }
                retryOnceOnline(unreachable)
            }
        }
        guard !Task.isCancelled else { return }
        for provider in resting {
            guard !Task.isCancelled else { return }
            var previous = statuses[provider]?.snapshot
            if let kept = previous?.fetchedAt, let checked = checkedAt[provider], checked > kept {
                previous?.fetchedAt = checked
            }
            guard let client = clients[provider] else { continue }
            let baseline = previous
            guard let snapshot = await TimeLimit.run(client.fetchBudget, otherwise: nil, {
                await client.fetchBetweenCalls(previous: baseline)
            }) else { continue }
            apply(provider: provider, result: .success(snapshot))
        }
        persistLiveSnapshots()
        cache.saveChecked(checkedAt)
        history.saveIfNeeded()
    }

    private func retryOnceOnline(_ providers: [Provider]) {
        guard offlineRetry == nil else { return }
        let wait = waitBeforeOfflineRetry
        offlineRetry = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled else { return }
            await self.refresh(force: true, providers: providers)
            if !Task.isCancelled {
                self.offlineRetry = nil
            }
        }
    }

    func newsBecameVisible() {
        guard liveNews == nil, let news else { return }
        liveNews = Task { [weak self] in
            await news.keepCurrent(
                preferences: { self?.settings.alertPreferences ?? AlertPreferences() },
                isAllowed: { self?.settings.newsEnabled == true }
            )
        }
    }

    func newsHidden() {
        liveNews?.cancel()
        liveNews = nil
    }

    func refreshNews(force: Bool = false, now: Date = .now, waitsForFollowUp: Bool = false) async {
        guard settings.newsEnabled, let news else { return }
        await news.refresh(maxAge: force ? 0 : nil, preferences: settings.alertPreferences, notifies: settings.showsAlertsOnMac, now: now,
                           waitsForFollowUp: waitsForFollowUp)
    }

    private func sendAlerts(for providers: [RelayProvider], now: Date) async {
        let preferences = await currentAlertPreferences(now: now)
        alertLedger.process(providers, preferences: preferences, now: now)
        let due = alertLedger.due(preferences: preferences, now: now)
        guard !due.isEmpty else {
            alertLedger.save(to: cache.directory)
            return
        }
        var delivery: AlertLedger.Delivery?
        if sendsAlertsToiCloud, let relay {
            delivery = await relay.sendAlerts(due, now: now)
        }
        let shown = alertLedger.settle(due, delivery: delivery, showsHere: settings.showsAlertsOnMac, now: now)
        if !shown.isEmpty {
            MacAlerts.post(shown)
        }
        alertLedger.save(to: cache.directory)
    }

    var sendsAlertsToiCloud: Bool {
        relay.map { $0.isAvailable && $0.isEnabled } ?? false
    }

    func currentAlertPreferences(now: Date = .now) async -> AlertPreferences {
        followTimeZone()
        let local = settings.alertPreferences
        let preferences = await relay?.syncAlertPreferences(local: local, now: now) ?? local
        if preferences != local {
            if settings.alertPreferences == local {
                settings.alertPreferences = preferences
            } else {
                settings.alertPreferences = AlertPreferences.merged(base: local, local: settings.alertPreferences, remote: preferences)
            }
        }
        return settings.alertPreferences
    }

    func updateAlertPreferences(_ change: (inout AlertPreferences) -> Void, now: Date = .now) {
        var preferences = settings.alertPreferences
        change(&preferences)
        guard preferences != settings.alertPreferences else { return }
        preferences.updatedAt = now
        settings.alertPreferences = preferences
        guard relay != nil else { return }
        Task { _ = await currentAlertPreferences() }
    }

    private func followTimeZone() {
        let zone = currentTimeZone().identifier
        let followed = settings.followedTimeZone
        guard followed != zone else { return }
        settings.followedTimeZone = zone
        if followed == nil, relay?.hasSharedAlertPreferences == true { return }
        guard settings.alertPreferences.timeZoneID != zone else { return }
        settings.alertPreferences.timeZoneID = zone
    }

    func pace(for provider: Provider, now: Date = .now) -> Pace? {
        let status = presentationStatus(for: provider, at: now)
        guard let snapshot = status.snapshot, let window = snapshot.windows.first else { return nil }
        return Pace.evaluate(
            used: window.usedPercent,
            kind: window.kind,
            resetsAt: window.resetsAt,
            startsAt: window.startsAt,
            windowSeconds: window.windowSeconds,
            samples: history.samples(provider: provider, window: window.id),
            isStale: status.isStale,
            now: now
        )
    }

    func windowPaces(for provider: Provider, now: Date = .now) -> [String: Pace] {
        let status = presentationStatus(for: provider, at: now)
        guard let snapshot = status.snapshot else { return [:] }
        var paces: [String: Pace] = [:]
        for window in snapshot.windows {
            let pace = Pace.evaluate(
                used: window.usedPercent,
                kind: window.kind,
                resetsAt: window.resetsAt,
                startsAt: window.startsAt,
                windowSeconds: window.windowSeconds,
                samples: history.samples(provider: provider, window: window.id),
                isStale: status.isStale,
                now: now
            )
            paces[window.id] = pace
        }
        return paces
    }

    func weeks(for provider: Provider) -> [String: UsageHistory] {
        history.weeks(for: provider)
    }

    var bankedResets: (count: Int, providers: [Provider]) {
        bankedResets(among: connectedProviders)
    }

    func bankedResets(among connected: [Provider]) -> (count: Int, providers: [Provider]) {
        var count = 0
        var providers: [Provider] = []
        for provider in connected {
            if let available = statuses[provider]?.snapshot?.availableBanked(at: presentationNow)?.available, available > 0 {
                count += available
                providers.append(provider)
            }
        }
        return (count, providers)
    }

    func relayEnvelope(at now: Date) -> RelayEnvelope {
        let providers = Provider.allCases.filter { settings.isEnabled($0) }.map { provider in
            var relayed = RelayProvider(provider: provider, status: statuses[provider] ?? .loading, checkedAt: checkedAt[provider])
            let at = max(now, checkedAt[provider] ?? now)
            let paces = windowPaces(for: provider, now: at)
            for index in relayed.windows.indices where relayed.windows[index].isMetered {
                if let pace = paces[relayed.windows[index].id] {
                    relayed.windows[index].pace = RelayPace(runsOutAt: pace.runsOutAt)
                }
            }
            return relayed
        }
        return RelayEnvelope(
            producer: "mac",
            appVersion: TokenroomIdentity.version,
            checkedAt: now,
            providers: providers
        )
    }

    var menuMeters: [MenuMeter] {
        let now = presentationNow
        return Provider.allCases.compactMap { provider in
            guard settings.isEnabled(provider), settings.showsInMenuBar(provider) else { return nil }
            let status = presentationStatus(for: provider, at: now)
            switch status {
            case .signedOut, .notEntitled, .expired(_, nil), .unreachable(nil):
                return nil
            case .loading, .rateLimited(_, nil):
                return MenuMeter(
                    provider: provider,
                    valueText: "--",
                    remaining: 100,
                    usedPercent: 0,
                    isStale: false,
                    isPlaceholder: true
                )
            case .live(let snapshot), .stale(let snapshot), .unreachable(let snapshot?),
                 .expired(_, let snapshot?), .rateLimited(_, let snapshot?):
                guard snapshot.windows.first?.isMetered ?? true else { return nil }
                let relay = RelayProvider(provider: provider, status: status, checkedAt: lastChecked(provider))
                let lead = UsageRanking.leadWindow(for: relay, now: now) { window in
                    UsageRanking.pace(
                        for: window,
                        isStale: status.isStale,
                        samples: history.samples(provider: provider, window: window.id),
                        now: now
                    )
                }
                guard let shown = lead else { return nil }
                let awaiting = shown.isAwaitingReading(at: now)
                let namesTheWindow = !awaiting && relay.primaryWindow?.id != shown.id
                let pace = UsageRanking.pace(
                    for: shown,
                    isStale: status.isStale,
                    samples: history.samples(provider: provider, window: shown.id),
                    now: now
                )
                return MenuMeter(
                    provider: provider,
                    valueText: Self.percentText(shown.used),
                    remaining: max(0, min(100, 100 - shown.used)),
                    usedPercent: shown.used,
                    isStale: status.isStale || awaiting,
                    isPlaceholder: false,
                    isAwaitingReading: awaiting,
                    attention: ReadingText.attention(relay, now: now, lead: shown),
                    windowLabel: namesTheWindow ? shown.displayTitle : nil,
                    urgency: awaiting ? 0 : UsageRanking.urgency(of: shown, pace: pace),
                    runsOutAt: awaiting ? nil : pace?.runsOutAt,
                    lastReading: status.isStale ? RelativeTime.ago(lastChecked(provider) ?? snapshot.fetchedAt, now: now) : nil
                )
            }
        }
    }

    var popoverProviders: [Provider] {
        Provider.allCases.filter { settings.isEnabled($0) }
    }

    var connectedProviders: [Provider] {
        let now = presentationNow
        return UsageRanking.sorted(popoverProviders.filter { !isDisconnected($0) }, provider: { provider in
            RelayProvider(provider: provider, status: presentationStatus(for: provider, at: now), checkedAt: lastChecked(provider))
        }, now: now, windowPace: { provider, window in
            UsageRanking.pace(for: window, isStale: presentationStatus(for: provider, at: now).isStale,
                              samples: history.samples(provider: provider, window: window.id), now: now)
        })
    }

    var disconnectedProviders: [Provider] {
        popoverProviders.filter { isDisconnected($0) }
    }

    private func isDisconnected(_ provider: Provider) -> Bool {
        (statuses[provider] ?? .loading).isDisconnected
    }

    func accountCaption(_ provider: Provider) -> String {
        let status = statuses[provider] ?? .loading
        switch status {
        case .loading:
            return "Checking…"
        case .live:
            return "Connected"
        case .stale, .unreachable(.some):
            return "Connected · last good reading"
        case .signedOut:
            return "Not signed in"
        case .expired(_, .some):
            return "Session expired · last good reading"
        case .expired(_, nil):
            return "Session expired"
        case .notEntitled:
            return "Not on this plan"
        case .rateLimited(let until, _):
            return "Rate limited · next try \(until.formatted(date: .omitted, time: .shortened))"
        case .unreachable(nil):
            return "Couldn't reach \(provider.displayName)"
        }
    }

    func lastChecked(_ provider: Provider) -> Date? {
        checkedAt[provider] ?? statuses[provider]?.snapshot?.fetchedAt
    }

    func lastChanged(_ provider: Provider) -> Date? {
        statuses[provider]?.snapshot?.fetchedAt
    }

    func budgetUnit(for provider: Provider, region: String? = nil) -> String {
        BudgetReferencePreferences.editorUnit(for: provider, region: region,
            readingUnit: (rawSnapshots[provider] ?? statuses[provider]?.snapshot)?.budgetUnit)
    }

    func budgetCurrency(for provider: Provider, region: String? = nil) -> String {
        budgetUnit(for: provider, region: region).uppercased()
    }

    func budgetDidChange(for provider: Provider) {
        guard let raw = rawSnapshots[provider], statuses[provider]?.snapshot != nil else { return }
        let snapshot = raw.applyingBudget(reference: settings.budgetReference(for: provider))
        switch statuses[provider] {
        case .live: statuses[provider] = .live(snapshot)
        case .stale: statuses[provider] = .stale(snapshot)
        case .expired(let message, _): statuses[provider] = .expired(message, cached: snapshot)
        case .rateLimited(let until, _): statuses[provider] = .rateLimited(until: until, cached: snapshot)
        case .unreachable: statuses[provider] = .unreachable(cached: snapshot)
        default: return
        }
        snapshotsDirty = true
        persistLiveSnapshots()
    }

    func dismissLegacyNotice() {
        LegacyMigration.dismissNotice()
        showsLegacyNotice = false
    }

    func quitLegacyApp() {
        LegacyMigration.quitLegacyApp()
    }

    static var defaultClients: [any ProviderClient] {
        var clients: [any ProviderClient] = [
            GrokClient(), GrokBotClient(), ClaudeClient(), OpenAIClient(), CursorClient(),
            CopilotClient(), AntigravityClient(), DevinClient(),
        ]
        for provider in Provider.allCases where provider.usesAPIKey {
            var client = APIKeyClient(provider: provider, keys: CredentialReaders.apiKeys)
            if provider.access == .codingPlanKey {
                client.localCredential = { try LocalKeys.credential(for: $0) }
            }
            clients.append(client)
        }
        return clients
    }

    static func percentText(_ value: Double) -> String {
        TokenroomFormat.percentText(value)
    }

    private func apply(provider: Provider, result: Result<QuotaSnapshot, ProviderError>, now: Date = .now) {
        switch result {
        case .success(let raw):
            rawSnapshots[provider] = raw
            let snapshot = raw.applyingBudget(reference: settings.budgetReference(for: provider))
            checkedAt[provider] = snapshot.fetchedAt
            rateLimitedUntil[provider] = nil
            history.record(snapshot, now: now)
            if case .live(let old) = statuses[provider], Self.usageEqual(old, snapshot) {
                return
            }
            statuses[provider] = .live(snapshot)
            snapshotsDirty = true
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: statuses[provider]?.snapshot, lastChecked: checkedAt[provider], now: now)
            if let until = ProviderStatus.retryDate(after: error, now: now) {
                rateLimitedUntil[provider] = until
            }
            logger.error("refresh failed \(provider.rawValue, privacy: .public) \(error.logClass, privacy: .public)")
            if statuses[provider] != next {
                statuses[provider] = next
                snapshotsDirty = true
            }
        }
    }

    nonisolated static func clampedRetry(_ until: Date?, now: Date) -> Date {
        ProviderStatus.clampedRetry(until, now: now)
    }

    nonisolated static func usageEqual(_ a: QuotaSnapshot, _ b: QuotaSnapshot) -> Bool {
        var a = a
        a.fetchedAt = b.fetchedAt
        a.source = b.source
        if sameMinute(a.resetsAt, b.resetsAt) {
            a.resetsAt = b.resetsAt
        }
        for index in a.windows.indices {
            guard let match = b.windows.first(where: { $0.id == a.windows[index].id }) else { continue }
            if sameMinute(a.windows[index].resetsAt, match.resetsAt) {
                a.windows[index].resetsAt = match.resetsAt
            }
            if sameMinute(a.windows[index].startsAt, match.startsAt) {
                a.windows[index].startsAt = match.startsAt
            }
        }
        return a == b
    }

    private nonisolated static func sameMinute(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < 60
    }

    private func persistLiveSnapshots() {
        guard snapshotsDirty else { return }
        snapshotsDirty = false
        var snapshots: [Provider: QuotaSnapshot] = [:]
        for (provider, status) in statuses {
            if let snapshot = status.snapshot {
                snapshots[provider] = snapshot
            }
        }
        cache.save(snapshots)
    }
}
