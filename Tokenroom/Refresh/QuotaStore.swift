import AppKit
import Foundation
import Observation
import os

@Observable
@MainActor
final class QuotaStore {
    var statuses: [Provider: ProviderStatus] = [:] { didSet { schedulePresentationClock() } }
    /// Last successful fetch per provider, even when usage didn't change.
    var checkedAt: [Provider: Date] = [:] { didSet { schedulePresentationClock() } }
    /// Presentation time advances independently of network polling and publishes reset/age changes.
    private(set) var presentationNow = Date.now
    var lastAttempt: Date?
    /// When the timer's next check is due. Nil until `start`.
    private(set) var nextTimedCheck: Date?
    var isRefreshing = false
    var settings: AppSettings
    var showsLegacyNotice: Bool
    /// Set by "Add Key" in the popover; Settings opens its key sheet and clears it.
    var pendingKeyProvider: Provider?
    let signIn: SignInCoordinator
    /// Sends readings to iCloud for iPhone and Apple Watch. Nil in tests.
    let relay: RelayPublisher?
    /// A week of hourly usage per window, next to the snapshot cache.
    let history: HistoryStore
    /// New models and announcements for the News window, fetched only when turned on. Nil in tests.
    let news: NewsStore?
    private var alertLedger: AlertLedger

    private let clients: [Provider: any ProviderClient]
    private let cache: SnapshotCache
    private var rateLimitedUntil: [Provider: Date] = [:]
    /// When each provider's endpoint was last called, successful or not; spacing counts from it.
    private var lastAttemptAt: [Provider: Date] = [:]
    /// Readings before a budget was applied, so a new budget shows at once.
    private var rawSnapshots: [Provider: QuotaSnapshot] = [:]
    private var loopTask: Task<Void, Never>?
    private var presentationTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var timeZoneTask: Task<Void, Never>?
    /// This Mac's time zone now. Foundation keeps the zone it first read for the life of the
    /// process, so it's read again each time: a change made here after travelling is dated
    /// in the zone the Mac is in, not the one Tokenroom launched in. Tests pin it.
    var currentTimeZone: () -> TimeZone = {
        NSTimeZone.resetSystemTimeZone()
        return .current
    }
    /// The check running now.
    private var inFlight: Task<Void, Never>?
    /// One more check after the running one, shared by the forced refreshes asked for meanwhile,
    /// for every provider they asked for (nil: all of them).
    private var followUp: Task<Void, Never>?
    private var followUpProviders: Set<Provider>? = []
    /// Sending readings, history, and alerts to iCloud, and checking News, after a check.
    private var sharing: Task<Void, Never>?
    /// Keeps News current while its window is open.
    private var liveNews: Task<Void, Never>?
    /// The one check more after a check that couldn't reach the network at all.
    private(set) var offlineRetry: Task<Void, Never>?
    /// How long after a check where no call reached the network it's tried once more: the Mac
    /// woke before its Wi-Fi, and the timer's next check can be half an hour away.
    nonisolated static let offlineRetryDelay: TimeInterval = 45
    /// Waits out `offlineRetryDelay` before that check (returning early when cancelled). Tests
    /// hold it until they're ready instead.
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
            // `-TokenroomSendTestAlert YES` sends one test alert to the iPhone after launch.
            if UserDefaults.standard.bool(forKey: "TokenroomSendTestAlert") {
                await self?.relay?.sendTestAlert()
            }
            #endif
            await self?.checkOnTimer()
        }
        schedulePresentationClock()
        wakeTask = Task { [weak self] in
            let notifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in notifications {
                // Forced: however short the sleep, what it cut short is checked again.
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
                // Times shown (resets, run-outs, quiet hours) follow the new zone without a relaunch.
                NSTimeZone.resetSystemTimeZone()
                self?.ageReadings(at: .now)
            }
        }
    }

    /// A check every "Refresh every", until cancelled.
    private func checkOnTimer() async {
        while !Task.isCancelled {
            let interval = max(settings.refreshInterval, 60)
            nextTimedCheck = Date().addingTimeInterval(interval)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await refresh()
        }
    }

    /// A new "Refresh every" starts the timer's wait over at once, instead of after the wait
    /// under way, which could be the old 30 minutes.
    func setRefreshMinutes(_ minutes: Int) {
        guard settings.refreshMinutes != minutes else { return }
        settings.refreshMinutes = minutes
        guard loopTask != nil else { return }
        // A timer check under way finishes: its calls are out, and cancelling it here doesn't
        // reach them.
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.checkOnTimer()
        }
    }

    /// Calls cut off by sleep would come back as failures. Cancelled, they don't count, and the
    /// refresh on waking checks again.
    func willSleep() {
        inFlight?.cancel()
        followUp?.cancel()
        sharing?.cancel()
        offlineRetry?.cancel()
        offlineRetry = nil
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
        offlineRetry?.cancel()
        offlineRetry = nil
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
        if let inFlight {
            // A check in flight finishes rather than being cancelled: its calls are already out,
            // and calling a rate-limited provider again right away can earn a 429.
            guard force else {
                await inFlight.value
                return
            }
            // Forced refreshes asked for meanwhile share one more check after it, for everything
            // they asked for; the spacing rules keep just-checked providers resting.
            await joinFollowUp(after: inFlight, providers: providers).value
            return
        }
        // A check moments ago is enough, unless the clock was set back since.
        if !force, let lastAttempt, (0..<15).contains(Date().timeIntervalSince(lastAttempt)) {
            return
        }
        // Forced refreshes (a button, a sign-in, the tests) return once readings are shared;
        // the timer's don't wait for iCloud and News, so a slow iCloud can't hold up checks.
        await check(providers, waitsForSharing: force)
    }

    /// A sign-in finished, or a key was saved or removed: the provider is checked now, not after
    /// its spacing or a Retry-After, which came from the old credentials.
    func credentialsChanged(for provider: Provider) async {
        // After the check in flight, whose answer came from the old credentials: a 429 it earns
        // mustn't hold the new ones off.
        if let inFlight {
            await inFlight.value
        }
        lastAttemptAt[provider] = nil
        rateLimitedUntil[provider] = nil
        clients[provider]?.credentialsChanged()
        await refresh(force: true, providers: [provider])
    }

    /// A provider turned on or off in Settings. One turned on is checked now rather than at the
    /// timer's next check, within its usual spacing and Retry-After (the login didn't change).
    /// Either way the iPhone's list changes with the next round sent to iCloud, which goes out
    /// at once instead of waiting out the minute since the last send.
    /// Returns the check and round it starts, nil when nothing changed.
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
            // Not when going to sleep or quitting.
            guard !Task.isCancelled else { return }
            // Through `refresh`, in case another check started first.
            await self.refresh(force: true, providers: asked.map { Array($0) })
        }
        followUp = task
        return task
    }

    /// Checks the providers asked for (nil: all), then shares what it found.
    private func check(_ providers: [Provider]?, waitsForSharing: Bool = true) async {
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshNow(providers: providers)
        }
        inFlight = task
        await task.value
        // Another refresh may have started once this one finished.
        if inFlight == task {
            inFlight = nil
        }
        // A check cut short (sleep, quitting) has nothing new to share.
        guard !task.isCancelled else { return }
        if waitsForSharing {
            await share()
        } else {
            Task { await self.share() }
        }
    }

    /// Sends readings, history, and alerts to iCloud and checks News, one round at a time and
    /// outside the check, so a slow iCloud doesn't hold up the next check. A check that finishes
    /// meanwhile leaves one more round, with the newest readings then.
    func share() async {
        if let sharing {
            // A round going to sleep cancelled doesn't go round again: this request gets a round
            // of its own once that one has ended (or joins one another request started).
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
                await self.shareReadings(now: Date())
            } while self.shareAgain && !Task.isCancelled
            self.sharing = nil
        }
        sharing = task
        await task.value
    }

    private func shareReadings(now: Date) async {
        let envelope = relayEnvelope(at: now)
        await relay?.publish(envelope, now: now)
        let relayed = Provider.allCases.filter { settings.isEnabled($0) }
        await relay?.publishHistory(history.relayHistory(for: relayed), now: now)
        await sendAlerts(for: envelope.providers, now: now)
        await relay?.pruneEventsIfDue(now: now)
        await refreshNews(now: now)
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
            // Times from before the clock was set back don't hold calls off.
            let sinceLast = lastAttemptAt[provider].map { now.timeIntervalSince($0) }
            if let until = rateLimitedUntil[provider], until > now, until.timeIntervalSince(now) <= ProviderStatus.longestRetry {
                // No call before its Retry-After, but a cheap local reading (Claude's status
                // line) still counts meanwhile.
                resting.append(provider)
            } else if let sinceLast, sinceLast >= 0, sinceLast < provider.minimumInterval {
                // Spacing counts from the last call, so failures don't bring the next one closer.
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
            for await (provider, result) in group {
                // Cut short (the Mac went to sleep, or Tokenroom is quitting): not a failure, and
                // not an attempt, so the next refresh asks again.
                if Task.isCancelled, case .failure = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                    continue
                }
                // No login at all: nothing was called, so the next check isn't spaced out. (An
                // expired session may have been refused by the server, which keeps the spacing.)
                if case .failure(.signedOut) = result {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                }
                if case .failure(.unreachable) = result {
                    unreachable.append(provider)
                }
                apply(provider: provider, result: result)
            }
            // Every call failed, nothing answered meanwhile, and the network said it wasn't there:
            // the Mac was offline (awake before its Wi-Fi), so none of them was a call to space out.
            // A server's error or a slow answer reached the provider, and keeps its spacing. One
            // provider alone can't tell an outage from being offline.
            let networkAfter = TokenroomHTTP.networkTally
            let offline = networkAfter.answers == networkBefore.answers && networkAfter.offline > networkBefore.offline
            let called = due.filter { clients[$0] != nil }
            if called.count >= 2, unreachable.count == called.count, offline {
                for provider in unreachable {
                    lastAttemptAt[provider] = earlierAttempts[provider]
                }
                retryOnceOnline(unreachable)
            }
        }
        guard !Task.isCancelled else { return }
        for provider in resting {
            guard !Task.isCancelled else { return }
            // The kept reading dates from when its values first appeared; a between-calls
            // reading has to be newer than the last check.
            var previous = statuses[provider]?.snapshot
            if let kept = previous?.fetchedAt, let checked = checkedAt[provider], checked > kept {
                previous?.fetchedAt = checked
            }
            guard let client = clients[provider] else { continue }
            let baseline = previous
            // Same budget as a full check. This read is local and usually instant; if it
            // doesn't return, the last reading stays and the menu leaves "Updating…".
            guard let snapshot = await TimeLimit.run(client.fetchBudget, otherwise: nil, {
                await client.fetchBetweenCalls(previous: baseline)
            }) else { continue }
            apply(provider: provider, result: .success(snapshot))
        }
        persistLiveSnapshots()
        cache.saveChecked(checkedAt)
        history.saveIfNeeded()
    }

    /// No call connected (the Mac woke before its Wi-Fi): these are checked once more a little
    /// later, rather than showing and sharing the readings from before the sleep until the
    /// timer's next check. Once: a retry that can't connect either leaves it to the timer.
    private func retryOnceOnline(_ providers: [Provider]) {
        guard offlineRetry == nil else { return }
        let wait = waitBeforeOfflineRetry
        offlineRetry = Task { [weak self] in
            await wait()
            // Cancelled by sleep or quitting: whoever cancelled it already let it go.
            guard let self, !Task.isCancelled else { return }
            // An ordinary check of those providers: each one's spacing and Retry-After hold (a
            // provider called meanwhile rests), and no login is renewed unless it's due. `force`
            // only keeps it from folding into a check in flight or one moments ago.
            await self.refresh(force: true, providers: providers)
            if !Task.isCancelled {
                self.offlineRetry = nil
            }
        }
    }

    /// While the News window is open: current on open, then checked every 15 minutes by itself,
    /// as long as News stays on.
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

    /// Checks News when it's turned on; the fetcher only goes out when a feed is due.
    func refreshNews(force: Bool = false, now: Date = .now) async {
        guard settings.newsEnabled, let news else { return }
        await news.refresh(maxAge: force ? 0 : nil, preferences: settings.alertPreferences, notifies: settings.showsAlertsOnMac, now: now)
    }

    /// Alerts for crossings since the last refresh: to the iPhone through iCloud, and on this Mac
    /// when turned on. Each goes out once, from whichever device saw it first. Alerts that can
    /// wait hold until quiet hours end, and ones iCloud didn't take are retried next time.
    private func sendAlerts(for providers: [RelayProvider], now: Date) async {
        let preferences = await currentAlertPreferences(now: now)
        alertLedger.process(providers, preferences: preferences, now: now)
        let due = alertLedger.due(preferences: preferences, now: now)
        guard !due.isEmpty else {
            alertLedger.save(to: cache.directory)
            return
        }
        let relayActive = relay.map { $0.isAvailable && $0.isEnabled } ?? false
        var delivered: [String] = []
        if relayActive, let relay {
            delivered = await relay.sendAlerts(due, now: now)
        }
        if settings.showsAlertsOnMac {
            let unseen = due.filter { alertLedger.shownHere[$0.id] == nil }
            MacAlerts.post(unseen)
            alertLedger.markShownHere(unseen.map(\.id), at: now)
        }
        if !relayActive {
            // Nowhere else to send them: this Mac showed them, or nothing will.
            delivered = due.map(\.id)
        }
        alertLedger.markSent(delivered, at: now)
        alertLedger.save(to: cache.directory)
    }

    /// This Mac's alert choices in step with the shared copy: takes what the iPhone changed, and
    /// sends what was changed here (again, if iCloud was away), so Settings shows both.
    func currentAlertPreferences(now: Date = .now) async -> AlertPreferences {
        let local = settings.alertPreferences
        let preferences = await relay?.syncAlertPreferences(local: local, now: now) ?? local
        if preferences != local {
            if settings.alertPreferences == local {
                settings.alertPreferences = preferences
            } else {
                // Changed in Settings meanwhile: that change stays, on top of what came in.
                settings.alertPreferences = AlertPreferences.merged(base: local, local: settings.alertPreferences, remote: preferences)
            }
        }
        return settings.alertPreferences
    }

    /// Alert choices changed in Settings on this Mac: saved at once, and shared on top of the
    /// newest copy in iCloud, so a choice made on the iPhone meanwhile isn't undone.
    func updateAlertPreferences(_ change: (inout AlertPreferences) -> Void, now: Date = .now) {
        var preferences = settings.alertPreferences
        change(&preferences)
        guard preferences != settings.alertPreferences else { return }
        preferences.touch(now: now, timeZone: currentTimeZone())
        settings.alertPreferences = preferences
        guard relay != nil else { return }
        Task { _ = await currentAlertPreferences() }
    }

    /// Pace of a provider's primary window, from its recent readings.
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

    /// Pace for every window of a provider, keyed by window ID.
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

    /// A week of hourly usage per window of a provider, keyed by window ID.
    func weeks(for provider: Provider) -> [String: UsageHistory] {
        history.weeks(for: provider)
    }

    /// Banked resets across providers, for the popover's footer.
    var bankedResets: (count: Int, providers: [Provider]) {
        var count = 0
        var providers: [Provider] = []
        for provider in connectedProviders {
            if let available = statuses[provider]?.snapshot?.banked?.available, available > 0 {
                count += available
                providers.append(provider)
            }
        }
        return (count, providers)
    }

    /// Enabled providers as the iPhone and Watch will see them.
    func relayEnvelope(at now: Date) -> RelayEnvelope {
        let providers = Provider.allCases.filter { settings.isEnabled($0) }.map { provider in
            var relayed = RelayProvider(provider: provider, status: statuses[provider] ?? .loading, checkedAt: checkedAt[provider])
            // The pace this Mac measured from its frequent readings, for readers with hourly
            // history. Measured as of the newest reading, which can come after `now`.
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
                // Connected, with no reading yet (a 429 can come before the first): a placeholder,
                // so the menu bar lists what the popover does.
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
                // A balance with no limit has no percentage to show.
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
                    runsOutAt: awaiting ? nil : pace?.runsOutAt
                )
            }
        }
    }

    var popoverProviders: [Provider] {
        Provider.allCases.filter { settings.isEnabled($0) }
    }

    /// Enabled providers with a reading (or still loading), shown first.
    var connectedProviders: [Provider] {
        let now = presentationNow
        return UsageRanking.sorted(popoverProviders.filter { !isDisconnected($0) }, provider: { provider in
            RelayProvider(provider: provider, status: presentationStatus(for: provider, at: now), checkedAt: lastChecked(provider))
        }, now: now, windowPace: { provider, window in
            UsageRanking.pace(for: window, isStale: presentationStatus(for: provider, at: now).isStale,
                              samples: history.samples(provider: provider, window: window.id), now: now)
        })
    }

    /// Enabled providers waiting for a sign-in or key, collapsed at the bottom.
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

    /// Last successful check for a provider, falling back to when its reading was taken.
    func lastChecked(_ provider: Provider) -> Date? {
        checkedAt[provider] ?? statuses[provider]?.snapshot?.fetchedAt
    }

    /// When a provider's usage last changed: its reading keeps the time it first appeared,
    /// because an unchanged answer doesn't replace it.
    func lastChanged(_ provider: Provider) -> Date? {
        statuses[provider]?.snapshot?.fetchedAt
    }

    /// Moonshot follows the key's selected account even when an old-region reading is retained.
    /// Other providers use the reading's currency. Metadata is supplied by the asynchronous UI
    /// key-row read; this accessor never reads a Keychain.
    func budgetUnit(for provider: Provider, region: String? = nil) -> String {
        BudgetReferencePreferences.editorUnit(for: provider, region: region,
            readingUnit: (rawSnapshots[provider] ?? statuses[provider]?.snapshot)?.budgetUnit)
    }

    func budgetCurrency(for provider: Provider, region: String? = nil) -> String {
        budgetUnit(for: provider, region: region).uppercased()
    }

    /// Re-applies the provider's budget to the reading its status holds, whichever status that
    /// is. A status without one stays without: an expired session's reading, once its 24 hours
    /// are up, doesn't come back with a new budget.
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
            history.record(snapshot)
            if case .live(let old) = statuses[provider], Self.usageEqual(old, snapshot) {
                return
            }
            statuses[provider] = .live(snapshot)
            snapshotsDirty = true
        case .failure(let error):
            let next = ProviderStatus.failure(error, cached: statuses[provider]?.snapshot, lastChecked: checkedAt[provider], now: now)
            if case .rateLimited(let until, _) = next {
                rateLimitedUntil[provider] = until
            }
            if statuses[provider] != next {
                statuses[provider] = next
                snapshotsDirty = true
                logger.error("refresh failed \(provider.rawValue, privacy: .public)")
            }
        }
    }

    /// Honors Retry-After, within one minute to six hours.
    nonisolated static func clampedRetry(_ until: Date?, now: Date) -> Date {
        ProviderStatus.clampedRetry(until, now: now)
    }

    /// Whether a new reading says nothing the kept one doesn't: every field but when it was
    /// fetched and where from, so a newly banked reset, credits, or extra usage replace it even
    /// when the meters haven't moved, while the same values from Claude's status line and its
    /// direct call don't take turns. The kept reading's `fetchedAt` stays the time its values
    /// first appeared.
    nonisolated static func usageEqual(_ a: QuotaSnapshot, _ b: QuotaSnapshot) -> Bool {
        var a = a
        a.fetchedAt = b.fetchedAt
        a.source = b.source
        // Claude's direct read gives reset times to the microsecond and its status line to the
        // second: the same reset within a minute isn't a change.
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
