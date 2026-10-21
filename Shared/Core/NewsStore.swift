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
    private var queuedRefresh: RefreshRequest?
    /// The maxAge of the pass under way, so a request for fresher feeds is queued behind it.
    private var runningMaxAge: TimeInterval??
    private var runningIsAllowed: (@MainActor @Sendable () -> Bool)?
    private var lastPreferences = AlertPreferences()
    /// A notifying request arrived while a pass that doesn't notify (a live check) was under way.
    private var notifyAsked = false
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
        fetch: @escaping @Sendable (NewsFetcher.Request) async -> NewsFetcher.Result = {
            await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources, quietSources: $0.quietSources, isAllowed: $0.isAllowed)
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
        // A saved choice, plus labs added to the defaults since it was saved, as with feeds below.
        let knownVendors = (defaults.array(forKey: Keys.knownVendors) as? [String]).map(Set.init) ?? Self.firstDefaultVendors
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map { Set($0).union(ModelFeed.defaultVendors.subtracting(knownVendors)) } ?? ModelFeed.defaultVendors
        // A saved choice, plus feeds added to the catalog since it was saved: those start on,
        // as every feed does before anything is saved.
        let catalog = Set(FeedSource.catalog.map(\.id))
        let known = (defaults.array(forKey: Keys.knownSources) as? [String]).map(Set.init) ?? Self.firstCatalog
        followedSources = (defaults.array(forKey: Keys.sources) as? [String]).map { Set($0).union(catalog.subtracting(known)) } ?? catalog
        followedVoices = Set(defaults.stringArray(forKey: Keys.voices) ?? [])
        followedStatusSources = Set(defaults.stringArray(forKey: Keys.status) ?? [])
        quietSources = Set(defaults.stringArray(forKey: Keys.quietSources) ?? [])
        // A first launch starts from now, so the whole list isn't "new". A time saved ahead of the
        // clock (set while it was wrong) comes back to now, or nothing would be new until then.
        let saved = (defaults.object(forKey: Keys.seenAt) as? Double).map(Date.init(timeIntervalSince1970:))
        let seen = min(saved ?? now, now)
        seenAt = seen
        visitBaseline = seen
        if saved != seen {
            defaults.set(seen.timeIntervalSince1970, forKey: Keys.seenAt)
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

    /// "Couldn't read …" naming the followed feeds whose last answer couldn't be read in full.
    var announcementProblem: String? {
        let names = sources.filter { cache.unreadable?.contains($0.id) == true || cache.check(for: $0).failedAt != nil }.map(\.name)
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
    func retrySources(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        await refresh(preferences: lastPreferences, notifies: false, forcedSources: ids)
    }

    /// Fetches what's due, or anything older than `maxAge`. New models from followed labs get one
    /// notification when `notifies` and the preferences allow it.
    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, notifies: Bool = true, now: Date = .now, forcedSources: Set<String> = [], isAllowed: (@MainActor @Sendable () -> Bool)? = nil) async {
        guard allowsRefresh(), isAllowed?() != false else { return }
        lastPreferences = preferences
        if isRefreshing {
            // Requests during one pass coalesce into a single follow-up pass: a manual one, a new
            // feed, or one asking for fresher feeds than the pass under way (News opened meanwhile).
            let fresher = runningMaxAge.map { Self.isShorter(maxAge, than: $0) } ?? false
            // Every accepted request updates preferences on an existing follow-up, even a
            // cached/slower visit that would not independently justify another fetch. Keep
            // that pass's permission, freshest age, forced feeds and notification intent.
            if var queued = queuedRefresh {
                queued.preferences = preferences
                queued.notifies = queued.notifies || notifies
                queuedRefresh = queued
            }
            if maxAge == 0 || !forcedSources.isEmpty || fresher || sources.contains(where: { cache.items[$0.id] == nil && cache.sourceChecks?[$0.id] == nil }) {
                let queued = queuedRefresh
                queuedRefresh = (queued.map { Self.shorter($0.maxAge, maxAge) } ?? maxAge, preferences,
                                 (queued?.notifies ?? false) || notifies, now,
                                 (queued?.forcedSources ?? []).union(forcedSources), isAllowed ?? queued?.isAllowed ?? runningIsAllowed)
            }
            if notifies { notifyAsked = true }
            return
        }
        isRefreshing = true
        // A view can disappear while its request is awaiting a feed. Keep the owning pass and
        // its queued manual/follow-up requests alive independently of that view's cancellation.
        let request: RefreshRequest = (maxAge, preferences, notifies, now, forcedSources, isAllowed)
        let work = Task { await performRefresh(request) }
        await work.value
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

    private func performRefresh(_ initial: RefreshRequest) async {
        defer {
            isRefreshing = false
            notifyAsked = false
            runningMaxAge = nil
            runningIsAllowed = nil
            queuedRefresh = nil
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
            guard allowsRefresh(), request.isAllowed?() != false else { break }
            runningMaxAge = .some(request.maxAge)
            runningIsAllowed = request.isAllowed
            let previous = cache
            let checkedSources = sources
            // A source never read before (just followed, or new in this release), or followed again
            // with an old copy cached, brings its back catalog: none of it is new, however
            // recently it was dated.
            let quiet = Set(checkedSources.filter { previous.check(for: $0).succeededAt == nil || quietSources.contains($0.id) }.map(\.id))
            let requestAllows = request.isAllowed
            let result = await fetch(.init(cache: cache, sources: checkedSources, vendors: followedVendors, maxAge: request.maxAge, now: request.now, forcedSources: request.forcedSources,
                                           quietSources: quiet,
                                           isAllowed: { [weak self] in self?.allowsRefresh() == true && requestAllows?() != false }))
            var updated = result.cache
            updated.retainFoldedIdentities(from: cache, sources: checkedSources)
            cache = updated
            for source in checkedSources where source.kind == .officialAnnouncement && quiet.contains(source.id) {
                let baseline = min(visitBaseline, request.now)
                cache.items[source.id] = cache.items[source.id]?.map { raw in
                    var item = raw
                    item.firstSeenAt = min(item.newsDate ?? baseline, baseline)
                    return item
                }
            }
            for source in checkedSources where source.kind != .officialAnnouncement {
                if let items = cache.items[source.id] {
                    cache.items[source.id] = items.map { raw in
                        var item = raw
                        item.sourceID = source.id
                        item.kind = source.kind
                        let old = previous.items[source.id]?.first { $0.id == item.id }
                        let baseline = min(visitBaseline, request.now)
                        // A failed/partial bucket is not a successful first check. Keep that
                        // source's initial archive quiet even if it was unfollowed while awaiting.
                        if quiet.contains(source.id) {
                            item.firstSeenAt = min(old?.newsDate ?? baseline, baseline)
                        } else {
                            item.firstSeenAt = old?.newsDate ?? min(item.newsDate ?? request.now, request.now)
                        }
                        return item
                    }
                }
            }
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
            guard let next = queuedRefresh else { break }
            queuedRefresh = nil
            request = next
        }
    }

    func freshness(for section: NewsFilter, now: Date = .now) -> String {
        let models = cache.modelsFetchedAt.map { "Models checked \(RelativeTime.ago($0, now: now))" } ?? "Models not checked yet"
        let times = sources.compactMap { cache.check(for: $0).succeededAt }
        let feeds: String
        if sources.isEmpty { feeds = "No announcement sources followed" }
        else if times.count != sources.count { feeds = "Some sources have not loaded yet" }
        else { feeds = "Sources checked \(RelativeTime.ago(times.min(), now: now))" }
        switch section {
        case .today: return models + " · " + feeds
        case .models, .retiring: return models
        case .announcements: return feeds
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
