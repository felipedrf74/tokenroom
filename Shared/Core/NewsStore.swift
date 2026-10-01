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
        static let seenAt = "newsSeenAt"
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
    /// `isAllowed`, when set, is asked again before a queued pass runs (the Mac's News can be
    /// turned off while the pass before it is out).
    private typealias RefreshRequest = (maxAge: TimeInterval?, preferences: AlertPreferences, notifies: Bool, now: Date, forcedSources: Set<String>, isAllowed: (@MainActor () -> Bool)?)
    private var queuedRefresh: RefreshRequest?
    /// The maxAge of the pass under way, so a request for fresher feeds is queued behind it.
    private var runningMaxAge: TimeInterval??
    private var lastPreferences = AlertPreferences()

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
            let uncached = Set(sources.filter { added.contains($0.partOf ?? $0.id) && cache.items[$0.id] == nil }.map(\.id))
            if !uncached.isEmpty {
                Task { await refresh(preferences: lastPreferences, notifies: false, forcedSources: uncached) }
            }
        }
    }

    /// When News was last opened. Items published after it count as new.
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
        fetch: @escaping @Sendable (NewsFetcher.Request) async -> NewsFetcher.Result = {
            await NewsFetcher.refresh($0.cache, sources: $0.sources, following: $0.vendors, maxAge: $0.maxAge, now: $0.now, forcedSources: $0.forcedSources)
        },
        notify: @escaping @MainActor ([ModelRelease], AlertPreferences, Date) -> Void = {
            NewsStore.notify($0, preferences: $1, now: $2)
        }
    ) {
        self.defaults = defaults
        self.directory = directory
        self.fetch = fetch
        self.notify = notify
        cache = NewsCache.load(from: directory)
        // A saved choice, plus labs added to the defaults since it was saved, as with feeds below.
        let knownVendors = (defaults.array(forKey: Keys.knownVendors) as? [String]).map(Set.init) ?? Self.firstDefaultVendors
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map { Set($0).union(ModelFeed.defaultVendors.subtracting(knownVendors)) } ?? ModelFeed.defaultVendors
        // A saved choice, plus feeds added to the catalog since it was saved: those start on,
        // as every feed does before anything is saved.
        let catalog = Set(FeedSource.catalog.map(\.id))
        let known = (defaults.array(forKey: Keys.knownSources) as? [String]).map(Set.init) ?? Self.firstCatalog
        followedSources = (defaults.array(forKey: Keys.sources) as? [String]).map { Set($0).union(catalog.subtracting(known)) } ?? catalog
        // A first launch starts from now, so the whole list isn't "new".
        let saved = defaults.object(forKey: Keys.seenAt) as? Double
        let seen = saved.map(Date.init(timeIntervalSince1970:)) ?? now
        seenAt = seen
        visitBaseline = seen
        if saved == nil {
            defaults.set(seen.timeIntervalSince1970, forKey: Keys.seenAt)
        }
    }

    var sources: [FeedSource] {
        FeedSource.catalog.filter { followedSources.contains($0.partOf ?? $0.id) }
    }

    var announcements: [FeedItem] {
        cache.announcements(from: sources)
    }

    /// Newest first; followed labs only unless `all`.
    func models(all: Bool = false) -> [ModelRelease] {
        all ? cache.models : cache.models.filter { followedVendors.contains($0.vendor) }
    }

    /// Models OpenRouter will retire, soonest first.
    var retiring: [ModelRelease] {
        cache.models.filter { ($0.expires ?? .distantPast) > .now }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    /// New models from followed labs since News was last opened.
    var unseenModelCount: Int {
        models().filter { $0.created > seenAt }.count
    }

    /// Announcements from followed feeds since News was last opened.
    var unseenAnnouncementCount: Int {
        announcements.filter { ($0.published ?? .distantPast) > seenAt }.count
    }

    var unseenCount: Int {
        unseenModelCount + unseenAnnouncementCount
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
        isAllowed: @escaping @MainActor () -> Bool = { true },
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

    /// Fetches what's due, or anything older than `maxAge`. New models from followed labs get one
    /// notification when `notifies` and the preferences allow it.
    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, notifies: Bool = true, now: Date = .now, forcedSources: Set<String> = [], isAllowed: (@MainActor () -> Bool)? = nil) async {
        lastPreferences = preferences
        if isRefreshing {
            // Requests during one pass coalesce into a single follow-up pass: a manual one, a new
            // feed, or one asking for fresher feeds than the pass under way (News opened meanwhile).
            let fresher = runningMaxAge.map { Self.isShorter(maxAge, than: $0) } ?? false
            if maxAge == 0 || !forcedSources.isEmpty || fresher || sources.contains(where: { cache.items[$0.id] == nil && cache.sourceChecks?[$0.id] == nil }) {
                let queued = queuedRefresh
                queuedRefresh = (queued.map { Self.shorter($0.maxAge, maxAge) } ?? maxAge, preferences,
                                 (queued?.notifies ?? false) || notifies, now,
                                 (queued?.forcedSources ?? []).union(forcedSources), isAllowed ?? queued?.isAllowed)
            }
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
        let models = result.models.filter { !knownModels.contains($0.id) }.map(\.created)
        let items = result.items.flatMap { source, items in
            items.filter { !knownItems.contains(source + "|" + $0.id) }.compactMap(\.published)
        }
        return (models + items).max().map { min($0, checkedAt) }
    }

    private func performRefresh(_ initial: RefreshRequest) async {
        defer {
            isRefreshing = false
            runningMaxAge = nil
        }
        if cache.modelsFetchedAt == nil, cache.announcementsFetchedAt == nil, !visitIsOpen {
            seenAt = max(seenAt, initial.now)
            visitBaseline = seenAt
        }
        var request = initial
        while true {
            runningMaxAge = .some(request.maxAge)
            let previous = cache
            let result = await fetch(.init(cache: cache, sources: sources, vendors: followedVendors, maxAge: request.maxAge, now: request.now, forcedSources: request.forcedSources))
            cache = result.cache
            cache.save(to: directory)
            // What arrived while News is open is seen, so it doesn't come back as a badge; it
            // stays marked New for the rest of this visit (`visitBaseline`). Only what this
            // pass brought: a check that found nothing doesn't mark later arrivals seen.
            if visitIsOpen, let arrival = Self.newestArrival(in: result.cache, since: previous, checkedAt: request.now) {
                seenAt = max(seenAt, arrival)
            }
            if request.notifies, request.preferences.newModels, !result.newModels.isEmpty {
                notify(result.newModels, request.preferences, request.now)
            }
            guard let next = queuedRefresh else { break }
            queuedRefresh = nil
            // News turned off meanwhile (on the Mac): the follow-up doesn't go out.
            if let isAllowed = next.isAllowed, !isAllowed() { break }
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
