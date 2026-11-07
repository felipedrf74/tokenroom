import Foundation
import Observation
import UserNotifications

/// News: new models from OpenRouter's public list, and announcements from official feeds. The
/// iPhone's News tab and the Mac's News window both read it.
@Observable
@MainActor
final class NewsStore {
    enum Keys {
        static let vendors = "newsVendors"
        static let sources = "newsSources"
        /// The catalog when `sources` was saved, so feeds added since start on.
        static let knownSources = "newsKnownSources"
        /// The default labs when `vendors` was saved, so labs added to the defaults since start on.
        static let knownVendors = "newsKnownVendors"
        static let voices = "newsVoices"
        static let status = "newsStatusSources"
        static let seenAt = "newsSeenAt"
        static let quietSources = "newsQuietSources"
        /// The sources an update may add without following them (`suggestibleSources`) that this
        /// install has been offered, so the ones added since show in Following as "New sources".
        /// `voices` and `status` are written only when a choice changes, so they can't tell an
        /// install that never chose from one that didn't exist.
        static let knownSuggestions = "newsKnownSuggestions"
    }

    /// Voices and status sources Tokenroom 2.6 offered: what an install that saved nothing about
    /// them had been offered before `Keys.knownSuggestions` existed.
    static let firstSuggestions: Set<String> = [
        "voice-simonw", "voice-emollick", "voice-karpathy", "voice-bcherny", "status-openai", "status-claude",
    ]

    /// Sources nothing follows by itself after an update: voices and discussion, provider status,
    /// and catalog feeds that don't start on for upgraders (`FeedSource.startsOnForUpgraders`).
    static var suggestibleSources: [FeedSource] {
        FeedSource.toggles.filter { !$0.startsOnForUpgraders } + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
    }

    /// Tokenroom 2.0's feeds: what a list saved before `Keys.knownSources` existed had offered.
    static let firstCatalog: Set<String> = [
        "claude-code", "claude-code-releases", "openai-news", "codex-releases", "gemini", "copilot", "cursor", "devin",
        "zai", "kimi-code", "openrouter", "codex-changelog", "antigravity-blog", "antigravity-cli", "minimax-code",
    ]

    /// Tokenroom 2.0's default labs: what a list saved before `Keys.knownVendors` existed had.
    static let firstDefaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    private(set) var cache: NewsCache
    private(set) var isRefreshing = false
    private var visitIsOpen = false
    /// Per-call permission is an additional veto at pass/GET dispatch and follows queued work.
    private typealias RefreshRequest = (maxAge: TimeInterval?, preferences: AlertPreferences, notifies: Bool, now: Date, forcedSources: Set<String>, isAllowed: (@MainActor @Sendable () -> Bool)?)
    /// The follow-up asked for during a pass, by callers that don't own it (a pull, Retry, Check
    /// Now, coming forward): it survives the pass being cancelled, and runs after it.
    private var queuedRefresh: RefreshRequest?
    /// What cancellable owners (the Mac's loop, the background refresh) asked for during a pass:
    /// dropped with the pass when it's cancelled, since its owner is going away.
    private var ownedRefresh: RefreshRequest?
    /// A cancelled pass's surviving follow-up runs in work of its own: waiters follow it there.
    @ObservationIgnored private var successor: (from: Task<Void, Never>, to: Task<Void, Never>)?
    /// The maxAge of the pass under way, so a request for fresher feeds is queued behind it.
    private var runningMaxAge: TimeInterval??
    private var runningIsAllowed: (@MainActor @Sendable () -> Bool)?
    private var lastPreferences = AlertPreferences()
    /// A notifying request arrived while a pass that doesn't notify (a live check) was under way.
    private var notifyAsked = false
    /// The pass under way and the follow-ups it runs, so an owner can cancel it (`cancelPass`,
    /// `refresh(cancellable:)`) and a request can wait for the follow-up it queued.
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The owning app's policy applies to every entry point, including Follow and Retry.
    @ObservationIgnored var allowsRefresh: @MainActor @Sendable () -> Bool = { true }

    /// Labs whose new models are announced, e.g. `anthropic`.
    var followedVendors: Set<String> {
        didSet {
            defaults.set(followedVendors.sorted(), forKey: Keys.vendors)
            defaults.set(ModelFeed.defaultVendors.sorted(), forKey: Keys.knownVendors)
        }
    }

    /// Feed IDs from `FeedSource.catalog`.
    var followedSources: Set<String> {
        didSet {
            defaults.set(followedSources.sorted(), forKey: Keys.sources)
            defaults.set(FeedSource.catalog.map(\.id).sorted(), forKey: Keys.knownSources)
            let added = followedSources.subtracting(oldValue)
            startFollowing(sources.filter { added.contains($0.partOf ?? $0.id) })
        }
    }

    var followedVoices: Set<String> {
        didSet {
            defaults.set(followedVoices.sorted(), forKey: Keys.voices)
            startFollowing(sources.filter { followedVoices.subtracting(oldValue).contains($0.id) })
        }
    }
    var followedStatusSources: Set<String> {
        didSet {
            defaults.set(followedStatusSources.sorted(), forKey: Keys.status)
            startFollowing(sources.filter { followedStatusSources.subtracting(oldValue).contains($0.id) })
        }
    }

    /// Sources followed again while an old copy of them is still cached: their next read is quiet,
    /// like a first read, so what they published while they weren't followed isn't badged or
    /// marked New. Saved, so a relaunch before that read doesn't lose it.
    private var quietSources: Set<String> {
        didSet { defaults.set(quietSources.sorted(), forKey: Keys.quietSources) }
    }

    /// Suggestible sources this install has been offered (`Keys.knownSuggestions`).
    private var knownSuggestions: Set<String> {
        didSet { defaults.set(knownSuggestions.sorted(), forKey: Keys.knownSuggestions) }
    }

    /// Sources added since this install last looked, offered in Following until dismissed:
    /// an update shows what's new there rather than following it.
    var newSources: [FeedSource] {
        Self.suggestibleSources.filter { !knownSuggestions.contains($0.id) }
    }

    func dismissNewSources() {
        knownSuggestions.formUnion(Self.suggestibleSources.map(\.id))
    }

    /// Whether a source of any kind is followed: a voice or discussion source, a status feed, or a
    /// catalog feed (through the feed it's part of).
    func isFollowing(_ source: FeedSource) -> Bool {
        switch source.kind {
        case .commentary: followedVoices.contains(source.id)
        case .officialStatus: followedStatusSources.contains(source.id)
        case .officialAnnouncement: followedSources.contains(source.partOf ?? source.id)
        }
    }

    func setFollowing(_ source: FeedSource, _ isOn: Bool) {
        let id = source.partOf ?? source.id
        switch source.kind {
        case .commentary: if isOn { followedVoices.insert(id) } else { followedVoices.remove(id) }
        case .officialStatus: if isOn { followedStatusSources.insert(id) } else { followedStatusSources.remove(id) }
        case .officialAnnouncement: if isOn { followedSources.insert(id) } else { followedSources.remove(id) }
        }
    }

    /// Newly followed sources are read at once. One followed before, with its old copy still
    /// cached, is read quietly (`quietSources`).
    private func startFollowing(_ added: [FeedSource]) {
        guard !added.isEmpty else { return }
        let stale = Set(added.filter { cache.items[$0.id] != nil }.map(\.id))
        if !stale.isEmpty { quietSources.formUnion(stale) }
        let ids = Set(added.map(\.id))
        Task { await refresh(preferences: lastPreferences, notifies: false, forcedSources: ids) }
    }

    /// When News was last opened. Items that arrived after it (`FeedItem.newsDate`) count as new.
    private(set) var seenAt: Date {
        didSet { defaults.set(seenAt.timeIntervalSince1970, forKey: Keys.seenAt) }
    }

    /// `seenAt` as it was when News opened, so what was new stays marked while it's open.
    private(set) var visitBaseline: Date

    private let defaults: UserDefaults
    private let directory: URL?
    @ObservationIgnored private let fetch: @Sendable (NewsFetcher.Request) async -> NewsFetcher.Result
    @ObservationIgnored private let notify: @MainActor ([ModelRelease], AlertPreferences, Date) -> Void

    init(
        defaults: UserDefaults = AppGroup.defaults,
        directory: URL? = AppGroup.containerURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        now: Date = .now,
        initialCache: NewsCache? = nil,
        newInstallVoices: Set<String> = [],
        fetch: @escaping @Sendable (NewsFetcher.Request) async -> NewsFetcher.Result = {
            await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources, quietSources: $0.quietSources, isAllowed: $0.isAllowed, publish: $0.publish)
        },
        notify: @escaping @MainActor ([ModelRelease], AlertPreferences, Date) -> Void = {
            NewsStore.notify($0, preferences: $1, now: $2)
        }
    ) {
        self.defaults = defaults
        self.directory = directory
        self.fetch = fetch
        self.notify = notify
        var loaded = initialCache ?? NewsCache.load(from: directory)
        loaded.bringDatesBack(to: now)
        cache = loaded
        // Nothing of News saved yet: a new install, not an update. Every earlier release saved
        // `seenAt` on its first launch.
        let isNewInstall = [Keys.seenAt, Keys.vendors, Keys.sources, Keys.knownSources, Keys.voices, Keys.status]
            .allSatisfy { defaults.object(forKey: $0) == nil }
        // A saved choice, plus labs added to the defaults since it was saved, as with feeds below.
        let knownVendors = (defaults.array(forKey: Keys.knownVendors) as? [String]).map(Set.init) ?? Self.firstDefaultVendors
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map { Set($0).union(ModelFeed.defaultVendors.subtracting(knownVendors)) } ?? ModelFeed.defaultVendors
        // A saved choice, plus feeds added to the catalog since it was saved: those start on,
        // as every feed does before anything is saved, except feeds an update only offers
        // (`startsOnForUpgraders`), which a new install follows and an update suggests.
        let catalog = Set(FeedSource.catalog.map(\.id))
        let offeredOnly = Set(FeedSource.catalog.filter { !$0.startsOnForUpgraders }.map(\.id))
        let known = (defaults.array(forKey: Keys.knownSources) as? [String]).map(Set.init) ?? Self.firstCatalog
        followedSources = (defaults.array(forKey: Keys.sources) as? [String]).map { Set($0).union(catalog.subtracting(known).subtracting(offeredOnly)) }
            ?? (isNewInstall ? catalog : catalog.subtracting(offeredOnly))
        followedVoices = Set(defaults.stringArray(forKey: Keys.voices) ?? (isNewInstall ? Array(newInstallVoices) : []))
        followedStatusSources = Set(defaults.stringArray(forKey: Keys.status) ?? [])
        quietSources = Set(defaults.stringArray(forKey: Keys.quietSources) ?? [])
        knownSuggestions = (defaults.stringArray(forKey: Keys.knownSuggestions)).map(Set.init)
            ?? (isNewInstall ? Set(Self.suggestibleSources.map(\.id)) : Self.firstSuggestions)
        // A first launch starts from now, so the whole list isn't "new". A time saved ahead of the
        // clock (set while it was wrong) comes back to now, or nothing would be new until then.
        let saved = (defaults.object(forKey: Keys.seenAt) as? Double).map(Date.init(timeIntervalSince1970:))
        let seen = min(saved ?? now, now)
        seenAt = seen
        visitBaseline = seen
        if saved != seen {
            defaults.set(seen.timeIntervalSince1970, forKey: Keys.seenAt)
        }
        // Written now: the next launch isn't a new install, and `voices` is otherwise written only
        // when a choice changes.
        if isNewInstall {
            defaults.set(knownSuggestions.sorted(), forKey: Keys.knownSuggestions)
            if !followedVoices.isEmpty { defaults.set(followedVoices.sorted(), forKey: Keys.voices) }
        }
    }

    var sources: [FeedSource] {
        FeedSource.catalog.filter { followedSources.contains($0.partOf ?? $0.id) }
        + NewsVoice.catalog.compactMap(\.feed).filter { followedVoices.contains($0.id) }
        + NewsStatusSource.catalog.filter { followedStatusSources.contains($0.id) }
    }

    var announcements: [FeedItem] {
        cache.announcements(from: sources)
    }

    var allAnnouncements: [FeedItem] { cache.announcements(from: sources, limit: Int.max) }

    /// Newest first; followed labs only unless `all`.
    func models(all: Bool = false) -> [ModelRelease] {
        all ? cache.models : cache.models.filter { followedVendors.contains($0.vendor) }
    }

    /// Models OpenRouter will retire, soonest first.
    var retiring: [ModelRelease] {
        cache.models.filter { ($0.expires ?? .distantPast) > .now }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    func retiringModels(all: Bool = false) -> [ModelRelease] {
        retiring.filter { all || followedVendors.contains($0.vendor) }
    }

    /// Recent models from followed labs since News was last opened; archives never badge.
    var unseenModelCount: Int {
        unseenModelCount(now: .now)
    }

    func unseenModelCount(now: Date) -> Int {
        models().filter { $0.newsDate > seenAt && NewsEditions.isRecentModel($0, now: now) }.count
    }

    /// Announcements from followed feeds that arrived since News was last opened.
    var unseenAnnouncementCount: Int {
        allAnnouncements.filter { ($0.newsDate ?? .distantPast) > seenAt }.count
    }

    /// The Mac release pill opens Releases; voice/status unread items remain in the News badge.
    var unseenReleaseCount: Int {
        NewsDiscovery.stories(allAnnouncements, collection: .release).filter { ($0.newsDate ?? .distantPast) > seenAt }.count
    }

    var unseenCount: Int {
        unseenCount(now: .now)
    }

    func unseenCount(now: Date) -> Int {
        unseenModelCount(now: now) + unseenAnnouncementCount
    }

    /// "Couldn't read …" when the model list's last answer couldn't be read.
    var modelProblem: String? {
        cache.unreadable?.contains(ModelFeed.id) == true ? "Couldn't read OpenRouter's model list." : nil
    }

    /// "Couldn't read …" naming the followed feeds that keep failing: a permanent error (404, 410,
    /// not a feed), or three failures in a row over more than an hour
    /// (`NewsCache.isPersistentlyFailing`). One that failed once shows in source health instead.
    var announcementProblem: String? {
        let names = sources.filter { cache.isPersistentlyFailing($0) }.map(\.name)
        guard let last = names.last else { return nil }
        if names.count > 1, names.count == sources.count {
            return "Couldn't read the feeds."
        }
        return "Couldn't read \(names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last)."
    }

    /// Whether to mark an item as new while News is open.
    func isNew(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date > visitBaseline
    }

    /// News is open: clear the badge, but keep this visit's items marked.
    func beginVisit(now: Date = .now) {
        guard !visitIsOpen else { return }
        visitIsOpen = true
        visitBaseline = seenAt
        seenAt = max(seenAt, now)
    }

    func endVisit() { visitIsOpen = false }

    /// While News is on screen: checks what's older than `interval` now and every `interval`
    /// after, until the caller's task is cancelled (the screen goes away). New items arrive
    /// marked New for the visit; they don't notify, since News is open. `isAllowed` is asked
    /// before each check (the Mac's News can be turned off meanwhile).
    func keepCurrent(
        interval: TimeInterval = NewsFetcher.liveInterval,
        preferences: @escaping @MainActor () -> AlertPreferences,
        isAllowed: @escaping @MainActor @Sendable () -> Bool = { true },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async {
        while !Task.isCancelled {
            if isAllowed() {
                await refresh(maxAge: interval, preferences: preferences(), notifies: false, isAllowed: isAllowed)
            }
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }

    /// Compatibility for callers opening a new visit; internal navigation uses beginVisit.
    func markSeen(now: Date = .now) { beginVisit(now: now) }

    /// Labs to offer in settings: followed ones, then others in the list, by name.
    var vendorChoices: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for release in cache.models where names[release.vendor] == nil {
            names[release.vendor] = release.vendorName
        }
        for vendor in ModelFeed.defaultVendors where names[vendor] == nil {
            names[vendor] = ModelFeed.vendorNames[vendor] ?? vendor
        }
        return names.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A discovery retry retains the latest real preferences, including a queued notifying pass.
    /// `waitsForFollowUp`: as `refresh`'s, for a Retry or pull whose spinner should last.
    func retrySources(_ ids: Set<String>, waitsForFollowUp: Bool = false) async {
        guard !ids.isEmpty else { return }
        await refresh(preferences: lastPreferences, notifies: false, forcedSources: ids, waitsForFollowUp: waitsForFollowUp)
    }

    /// Cancels the pass under way and what cancellable owners queued behind it, for the store's
    /// owner: the Mac going to sleep. What the pass had read stays; the checks it cut short count
    /// no failure. A follow-up another caller asked for (a pull, Check Now) still runs after it.
    /// Views never call this: a page going away leaves its pass running.
    func cancelPass() {
        work?.cancel()
    }

    /// Fetches what's due, or anything older than `maxAge`. New models from followed labs get one
    /// notification when `notifies` and the preferences allow it.
    ///
    /// During a pass, a request joins a single follow-up when it asks for something that pass
    /// won't cover; with `waitsForFollowUp` it always does, and returns once that follow-up is
    /// done (pull to refresh, Retry, Check Now, the Mac waking), rather than at once.
    ///
    /// `cancellable` is for an owner whose time can run out (iPhone background refresh, the Mac's
    /// News loop): cancelling the caller then cancels the pass it started, and the checks cut short
    /// count no failure. By default a pass outlives its caller, so a view going away while its
    /// request waits never cancels or drops the pass or what's queued behind it.
    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, notifies: Bool = true, now: Date = .now, forcedSources: Set<String> = [], isAllowed: (@MainActor @Sendable () -> Bool)? = nil,
                 waitsForFollowUp: Bool = false, cancellable: Bool = false) async {
        guard allowsRefresh(), isAllowed?() != false else { return }
        lastPreferences = preferences
        if isRefreshing {
            // Requests during one pass coalesce into a single follow-up pass: a manual one, a new
            // feed, or one asking for fresher feeds than the pass under way (News opened meanwhile).
            let fresher = runningMaxAge.map { Self.isShorter(maxAge, than: $0) } ?? false
            // Every accepted request updates preferences on an existing follow-up, even a
            // cached/slower visit that would not independently justify another fetch. Keep
            // that pass's permission, freshest age, forced feeds and notification intent.
            for keyPath in [\NewsStore.queuedRefresh, \NewsStore.ownedRefresh] {
                guard var queued = self[keyPath: keyPath] else { continue }
                queued.preferences = preferences
                queued.notifies = queued.notifies || notifies
                self[keyPath: keyPath] = queued
            }
            if waitsForFollowUp || maxAge == 0 || !forcedSources.isEmpty || fresher || sources.contains(where: { cache.items[$0.id] == nil && cache.sourceChecks?[$0.id] == nil }) {
                let keyPath = cancellable ? \NewsStore.ownedRefresh : \NewsStore.queuedRefresh
                let queued = self[keyPath: keyPath]
                self[keyPath: keyPath] = (queued.map { Self.shorter($0.maxAge, maxAge) } ?? maxAge, preferences,
                                          (queued?.notifies ?? false) || notifies, now,
                                          (queued?.forcedSources ?? []).union(forcedSources), isAllowed ?? queued?.isAllowed ?? runningIsAllowed)
            }
            if notifies { notifyAsked = true }
            // The running work takes the queued follow-up before it ends, so its end is the
            // follow-up's; a cancelled pass hands a surviving follow-up to work of its own, which
            // the waiter follows. Waiting doesn't own the pass: the waiter going away leaves it.
            if waitsForFollowUp {
                var current = work
                while let running = current {
                    await running.value
                    current = successor?.from == running ? successor?.to : nil
                }
            }
            return
        }
        isRefreshing = true
        // A view can disappear while its request is awaiting a feed. Keep the owning pass and
        // its queued manual/follow-up requests alive independently of that view's cancellation.
        let request: RefreshRequest = (maxAge, preferences, notifies, now, forcedSources, isAllowed)
        let work = Task { await performRefresh(request) }
        self.work = work
        if cancellable {
            // An owner whose time runs out takes its pass with it.
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        } else {
            await work.value
        }
        if self.work == work { self.work = nil }
    }

    /// Whether `maxAge` asks for fresher feeds than `other`: 0 is freshest, nil (each feed's own
    /// interval) the least fresh.
    private static func isShorter(_ maxAge: TimeInterval?, than other: TimeInterval?) -> Bool {
        guard let maxAge else { return false }
        guard let other else { return true }
        return maxAge < other
    }

    private static func shorter(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
        isShorter(b, than: a) ? b : a
    }

    /// One follow-up for what other callers and owners queued: the freshest age, every forced
    /// feed, either's notification intent, the latest preferences and time, and the other
    /// callers' permission before the owners'.
    private static func merged(_ queued: RefreshRequest?, _ owned: RefreshRequest?) -> RefreshRequest? {
        guard let queued, let owned else { return queued ?? owned }
        let latest = owned.now > queued.now ? owned : queued
        return (shorter(queued.maxAge, owned.maxAge), latest.preferences, queued.notifies || owned.notifies, latest.now,
                queued.forcedSources.union(owned.forcedSources), queued.isAllowed ?? owned.isAllowed)
    }

    /// When the newest item that arrived in this pass was dated, no later than the check.
    private static func newestArrival(in result: NewsCache, since previous: NewsCache, checkedAt: Date) -> Date? {
        let knownModels = Set(previous.models.map(\.id))
        let knownItems = Set(previous.items.flatMap { source, items in items.map { source + "|" + $0.id } })
        let models = result.models.filter { !knownModels.contains($0.id) }.map(\.newsDate)
        let items = result.items.flatMap { source, items in
            items.filter { !knownItems.contains(source + "|" + $0.id) }.compactMap(\.newsDate)
        }
        return (models + items).max().map { min($0, checkedAt) }
    }

    /// A pass's answers as News shows them: identities folded before kept, and what a source read
    /// quietly brought (`quiet`) dated no later than the visit (`baseline`), so none of it counts
    /// as new. Folding goes over every entry, up to about 1,300, so it runs off the main actor.
    @concurrent nonisolated private static func settled(_ fetched: NewsCache, previous: NewsCache, sources: [FeedSource], quiet: Set<String>, baseline: Date, now: Date) async -> NewsCache {
        #if DEBUG
        foldRan?(pthread_main_np() != 0)
        #endif
        var cache = fetched
        cache.retainFoldedIdentities(from: previous, sources: sources)
        for source in sources where source.kind == .officialAnnouncement && quiet.contains(source.id) {
            cache.items[source.id] = cache.items[source.id]?.map { raw in
                var item = raw
                item.firstSeenAt = min(item.newsDate ?? baseline, baseline)
                return item
            }
        }
        for source in sources where source.kind != .officialAnnouncement {
            if let items = cache.items[source.id] {
                cache.items[source.id] = items.map { raw in
                    var item = raw
                    item.sourceID = source.id
                    item.kind = source.kind
                    let old = previous.items[source.id]?.first { $0.id == item.id }
                    // A failed/partial bucket is not a successful first check. Keep that
                    // source's initial archive quiet even if it was unfollowed while awaiting.
                    if quiet.contains(source.id) {
                        item.firstSeenAt = min(old?.newsDate ?? baseline, baseline)
                    } else {
                        item.firstSeenAt = old?.newsDate ?? min(item.newsDate ?? now, now)
                    }
                    return item
                }
            }
        }
        return cache
    }

    #if DEBUG
    /// Told, for tests, whether each fold (`settled`) ran on the main thread.
    nonisolated(unsafe) static var foldRan: (@Sendable (_ onMainThread: Bool) -> Void)?
    #endif

    /// What a pass has taken in so far, shown before the pass is done.
    private func show(_ partial: NewsCache, previous: NewsCache, sources: [FeedSource], quiet: Set<String>, now: Date) async {
        cache = await Self.settled(partial, previous: previous, sources: sources, quiet: quiet, baseline: min(visitBaseline, now), now: now)
    }

    private func performRefresh(_ initial: RefreshRequest) async {
        defer {
            // Cancelled by its owner: what owners queued goes with it; what another caller asked
            // for (a pull, Check Now, coming forward) runs next, in work of its own.
            let survivor = Task.isCancelled ? queuedRefresh : nil
            isRefreshing = false
            notifyAsked = false
            runningMaxAge = nil
            runningIsAllowed = nil
            queuedRefresh = nil
            ownedRefresh = nil
            if let survivor, let cancelled = work {
                isRefreshing = true
                let next = Task { await performRefresh(survivor) }
                successor = (cancelled, next)
                work = next
            } else {
                // This pass (or a successor that ran in its place) is done: nothing is running.
                // A newer pass can't have started yet, since `isRefreshing` was set until now.
                work = nil
            }
        }
        // The first check (turning News on) marks nothing new, even with News open, as the Mac's
        // window is when News is turned on from it: what it finds was there before.
        if cache.modelsFetchedAt == nil, cache.announcementsFetchedAt == nil {
            seenAt = max(seenAt, initial.now)
            visitBaseline = seenAt
        }
        var request = initial
        while true {
            // Recheck at physical dispatch, after the owning Task/previous pass yielded.
            guard !Task.isCancelled, allowsRefresh(), request.isAllowed?() != false else { break }
            runningMaxAge = .some(request.maxAge)
            runningIsAllowed = request.isAllowed
            let previous = cache
            let checkedSources = sources
            // A source never read before (just followed, or new in this release), or followed again
            // with an old copy cached, brings its back catalog: none of it is new, however
            // recently it was dated.
            let quiet = Set(checkedSources.filter { previous.check(for: $0).succeededAt == nil || quietSources.contains($0.id) }.map(\.id))
            let requestAllows = request.isAllowed
            let now = request.now
            // A feed's new items show as they arrive, settled as the whole pass's are.
            let result = await fetch(.init(cache: cache, sources: checkedSources, vendors: followedVendors, maxAge: request.maxAge, now: now, forcedSources: request.forcedSources,
                                           quietSources: quiet,
                                           publish: { [weak self] partial in
                                               await self?.show(partial, previous: previous, sources: checkedSources, quiet: quiet, now: now)
                                           },
                                           isAllowed: { [weak self] in self?.allowsRefresh() == true && requestAllows?() != false }))
            cache = await Self.settled(result.cache, previous: previous, sources: checkedSources, quiet: quiet, baseline: min(visitBaseline, now), now: now)
            // Once read, a source followed again is read as usual.
            let read = checkedSources.filter { source in
                cache.check(for: source).succeededAt.map { $0 != previous.check(for: source).succeededAt } ?? false
            }
            if !read.isEmpty, !quietSources.isDisjoint(with: read.map(\.id)) { quietSources.subtract(read.map(\.id)) }
            cache.save(to: directory)
            // What arrived while News is open is seen, so it doesn't come back as a badge; it
            // stays marked New for the rest of this visit (`visitBaseline`). Only what this
            // pass brought: a check that found nothing doesn't mark later arrivals seen.
            if visitIsOpen, let arrival = Self.newestArrival(in: cache, since: previous, checkedAt: request.now) {
                seenAt = max(seenAt, arrival)
            }
            // A notifying request that arrived meanwhile (a background refresh during a live check)
            // hands this pass its intent: the models it found are now off the list, so no later
            // pass would find them again. News on screen still doesn't notify.
            let notifies = request.notifies || (notifyAsked && !visitIsOpen)
            let preferences = request.notifies ? request.preferences : lastPreferences
            notifyAsked = false
            if notifies, preferences.newModels, !result.newModels.isEmpty {
                notify(result.newModels, preferences, request.now)
            }
            // Cancelled by its owner (sleep, the end of background time): what it read is kept,
            // and the owners' queued checks wait for their next pass (see `defer`).
            guard !Task.isCancelled, let next = Self.merged(queuedRefresh, ownedRefresh) else { break }
            queuedRefresh = nil
            ownedRefresh = nil
            request = next
        }
    }

    func problem(for section: NewsFilter) -> String? {
        switch section {
        case .today: let problems = [modelProblem, announcementProblem].compactMap { $0 }
            return problems.isEmpty ? nil : problems.joined(separator: " ")
        case .models, .retiring: return modelProblem
        case .announcements: return announcementProblem
        }
    }

    /// One notification for the batch, held until quiet hours end.
    private static func notify(_ releases: [ModelRelease], preferences: AlertPreferences, now: Date) {
        let content = UNMutableNotificationContent()
        if releases.count == 1, let release = releases.first {
            content.title = "New model: \(release.shortName)"
            content.body = "From \(release.vendorName)."
        } else {
            content.title = "\(releases.count) new models"
            content.body = releases.prefix(4).map(\.shortName).joined(separator: ", ") + (releases.count > 4 ? ", and more." : ".")
        }
        content.threadIdentifier = "models"
        let trigger = preferences.quietEnd(after: now).map { end in
            UNTimeIntervalNotificationTrigger(timeInterval: max(end.timeIntervalSince(now), 1), repeats: false)
        }
        let id = "models-" + releases.map(\.id).joined(separator: ",")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
