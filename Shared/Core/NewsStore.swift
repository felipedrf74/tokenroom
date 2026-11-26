import Foundation
import Observation
import UserNotifications

@Observable
@MainActor
final class NewsStore {
    enum Keys {
        static let vendors = "newsVendors"
        static let sources = "newsSources"
        static let knownSources = "newsKnownSources"
        static let knownVendors = "newsKnownVendors"
        static let voices = "newsVoices"
        static let status = "newsStatusSources"
        static let seenAt = "newsSeenAt"
        static let quietSources = "newsQuietSources"
        static let knownSuggestions = "newsKnownSuggestions"
    }

    static let firstSuggestions: Set<String> = [
        "voice-simonw", "voice-emollick", "voice-karpathy", "voice-bcherny", "status-openai", "status-claude",
    ]

    static var suggestibleSources: [FeedSource] {
        FeedSource.toggles.filter { !$0.startsOnForUpgraders } + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
    }

    static let firstCatalog: Set<String> = [
        "claude-code", "claude-code-releases", "openai-news", "codex-releases", "gemini", "copilot", "cursor", "devin",
        "zai", "kimi-code", "openrouter", "codex-changelog", "antigravity-blog", "antigravity-cli", "minimax-code",
    ]

    static let firstDefaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    private(set) var cache: NewsCache
    private(set) var isRefreshing = false
    private var visitIsOpen = false
    private typealias RefreshRequest = (maxAge: TimeInterval?, preferences: AlertPreferences, notifies: Bool, now: Date, forcedSources: Set<String>, isAllowed: (@MainActor @Sendable () -> Bool)?)
    private var queuedRefresh: RefreshRequest?
    private var ownedRefresh: RefreshRequest?
    @ObservationIgnored private var successor: (from: Task<Void, Never>, to: Task<Void, Never>)?
    private var runningMaxAge: TimeInterval??
    private var runningIsAllowed: (@MainActor @Sendable () -> Bool)?
    private var lastPreferences = AlertPreferences()
    private var notifyAsked = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored var allowsRefresh: @MainActor @Sendable () -> Bool = { true }

    var followedVendors: Set<String> {
        didSet {
            defaults.set(followedVendors.sorted(), forKey: Keys.vendors)
            defaults.set(ModelFeed.defaultVendors.sorted(), forKey: Keys.knownVendors)
        }
    }

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

    private var quietSources: Set<String> {
        didSet { defaults.set(quietSources.sorted(), forKey: Keys.quietSources) }
    }

    private var knownSuggestions: Set<String> {
        didSet { defaults.set(knownSuggestions.sorted(), forKey: Keys.knownSuggestions) }
    }

    var newSources: [FeedSource] {
        Self.suggestibleSources.filter { !knownSuggestions.contains($0.id) }
    }

    func dismissNewSources() {
        knownSuggestions.formUnion(Self.suggestibleSources.map(\.id))
    }

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

    private func startFollowing(_ added: [FeedSource]) {
        guard !added.isEmpty else { return }
        let stale = Set(added.filter { cache.items[$0.id] != nil }.map(\.id))
        if !stale.isEmpty { quietSources.formUnion(stale) }
        let ids = Set(added.map(\.id))
        Task { await refresh(preferences: lastPreferences, notifies: false, forcedSources: ids) }
    }

    private(set) var seenAt: Date {
        didSet { defaults.set(seenAt.timeIntervalSince1970, forKey: Keys.seenAt) }
    }

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
        let isNewInstall = [Keys.seenAt, Keys.vendors, Keys.sources, Keys.knownSources, Keys.voices, Keys.status]
            .allSatisfy { defaults.object(forKey: $0) == nil }
        let knownVendors = (defaults.array(forKey: Keys.knownVendors) as? [String]).map(Set.init) ?? Self.firstDefaultVendors
        followedVendors = (defaults.array(forKey: Keys.vendors) as? [String]).map { Set($0).union(ModelFeed.defaultVendors.subtracting(knownVendors)) } ?? ModelFeed.defaultVendors
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
        let saved = (defaults.object(forKey: Keys.seenAt) as? Double).map(Date.init(timeIntervalSince1970:))
        let seen = min(saved ?? now, now)
        seenAt = seen
        visitBaseline = seen
        if saved != seen {
            defaults.set(seen.timeIntervalSince1970, forKey: Keys.seenAt)
        }
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

    func models(all: Bool = false) -> [ModelRelease] {
        all ? cache.models : cache.models.filter { followedVendors.contains($0.vendor) }
    }

    var retiring: [ModelRelease] {
        cache.models.filter { ($0.expires ?? .distantPast) > .now }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
    }

    func retiringModels(all: Bool = false) -> [ModelRelease] {
        retiring.filter { all || followedVendors.contains($0.vendor) }
    }

    var unseenModelCount: Int {
        unseenModelCount(now: .now)
    }

    func unseenModelCount(now: Date) -> Int {
        models().filter { $0.newsDate > seenAt && NewsEditions.isRecentModel($0, now: now) }.count
    }

    var unseenAnnouncementCount: Int {
        allAnnouncements.filter { ($0.newsDate ?? .distantPast) > seenAt }.count
    }

    var unseenReleaseCount: Int {
        NewsDiscovery.stories(allAnnouncements, collection: .release).filter { ($0.newsDate ?? .distantPast) > seenAt }.count
    }

    var unseenCount: Int {
        unseenCount(now: .now)
    }

    func unseenCount(now: Date) -> Int {
        unseenModelCount(now: now) + unseenAnnouncementCount
    }

    var modelProblem: String? {
        cache.unreadable?.contains(ModelFeed.id) == true ? "Couldn't read OpenRouter's model list." : nil
    }

    var announcementProblem: String? {
        let names = sources.filter { cache.isPersistentlyFailing($0) }.map(\.name)
        guard let last = names.last else { return nil }
        if names.count > 1, names.count == sources.count {
            return "Couldn't read the feeds."
        }
        return "Couldn't read \(names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last)."
    }

    func isNew(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date > visitBaseline
    }

    func beginVisit(now: Date = .now) {
        guard !visitIsOpen else { return }
        visitIsOpen = true
        visitBaseline = seenAt
        seenAt = max(seenAt, now)
    }

    func endVisit() { visitIsOpen = false }

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

    func markSeen(now: Date = .now) { beginVisit(now: now) }

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

    func retrySources(_ ids: Set<String>, waitsForFollowUp: Bool = false) async {
        guard !ids.isEmpty else { return }
        await refresh(preferences: lastPreferences, notifies: false, forcedSources: ids, waitsForFollowUp: waitsForFollowUp)
    }

    func cancelPass() {
        work?.cancel()
    }

    func refresh(maxAge: TimeInterval? = nil, preferences: AlertPreferences, notifies: Bool = true, now: Date = .now, forcedSources: Set<String> = [], isAllowed: (@MainActor @Sendable () -> Bool)? = nil,
                 waitsForFollowUp: Bool = false, cancellable: Bool = false) async {
        guard allowsRefresh(), isAllowed?() != false else { return }
        lastPreferences = preferences
        if isRefreshing {
            let fresher = runningMaxAge.map { Self.isShorter(maxAge, than: $0) } ?? false
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
        let request: RefreshRequest = (maxAge, preferences, notifies, now, forcedSources, isAllowed)
        let work = Task { await performRefresh(request) }
        self.work = work
        if cancellable {
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        } else {
            await work.value
        }
        if self.work == work { self.work = nil }
    }

    private static func isShorter(_ maxAge: TimeInterval?, than other: TimeInterval?) -> Bool {
        guard let maxAge else { return false }
        guard let other else { return true }
        return maxAge < other
    }

    private static func shorter(_ a: TimeInterval?, _ b: TimeInterval?) -> TimeInterval? {
        isShorter(b, than: a) ? b : a
    }

    private static func merged(_ queued: RefreshRequest?, _ owned: RefreshRequest?) -> RefreshRequest? {
        guard let queued, let owned else { return queued ?? owned }
        let latest = owned.now > queued.now ? owned : queued
        return (shorter(queued.maxAge, owned.maxAge), latest.preferences, queued.notifies || owned.notifies, latest.now,
                queued.forcedSources.union(owned.forcedSources), queued.isAllowed ?? owned.isAllowed)
    }

    private static func newestArrival(in result: NewsCache, since previous: NewsCache, checkedAt: Date) -> Date? {
        let knownModels = Set(previous.models.map(\.id))
        let knownItems = Set(previous.items.flatMap { source, items in items.map { source + "|" + $0.id } })
        let models = result.models.filter { !knownModels.contains($0.id) }.map(\.newsDate)
        let items = result.items.flatMap { source, items in
            items.filter { !knownItems.contains(source + "|" + $0.id) }.compactMap(\.newsDate)
        }
        return (models + items).max().map { min($0, checkedAt) }
    }

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
    nonisolated(unsafe) static var foldRan: (@Sendable (_ onMainThread: Bool) -> Void)?
    #endif

    private func show(_ partial: NewsCache, previous: NewsCache, sources: [FeedSource], quiet: Set<String>, now: Date) async {
        cache = await Self.settled(partial, previous: previous, sources: sources, quiet: quiet, baseline: min(visitBaseline, now), now: now)
    }

    private func performRefresh(_ initial: RefreshRequest) async {
        defer {
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
                work = nil
            }
        }
        if cache.modelsFetchedAt == nil, cache.announcementsFetchedAt == nil {
            seenAt = max(seenAt, initial.now)
            visitBaseline = seenAt
        }
        var request = initial
        while true {
            guard !Task.isCancelled, allowsRefresh(), request.isAllowed?() != false else { break }
            runningMaxAge = .some(request.maxAge)
            runningIsAllowed = request.isAllowed
            let previous = cache
            let checkedSources = sources
            let quiet = Set(checkedSources.filter { previous.check(for: $0).succeededAt == nil || quietSources.contains($0.id) }.map(\.id))
            let requestAllows = request.isAllowed
            let now = request.now
            let result = await fetch(.init(cache: cache, sources: checkedSources, vendors: followedVendors, maxAge: request.maxAge, now: now, forcedSources: request.forcedSources,
                                           quietSources: quiet,
                                           publish: { [weak self] partial in
                                               await self?.show(partial, previous: previous, sources: checkedSources, quiet: quiet, now: now)
                                           },
                                           isAllowed: { [weak self] in self?.allowsRefresh() == true && requestAllows?() != false }))
            cache = await Self.settled(result.cache, previous: previous, sources: checkedSources, quiet: quiet, baseline: min(visitBaseline, now), now: now)
            let read = checkedSources.filter { source in
                cache.check(for: source).succeededAt.map { $0 != previous.check(for: source).succeededAt } ?? false
            }
            if !read.isEmpty, !quietSources.isDisjoint(with: read.map(\.id)) { quietSources.subtract(read.map(\.id)) }
            cache.save(to: directory)
            if visitIsOpen, let arrival = Self.newestArrival(in: cache, since: previous, checkedAt: request.now) {
                seenAt = max(seenAt, arrival)
            }
            let notifies = request.notifies || (notifyAsked && !visitIsOpen)
            let preferences = request.notifies ? request.preferences : lastPreferences
            notifyAsked = false
            if notifies, preferences.newModels, !result.newModels.isEmpty {
                notify(result.newModels, preferences, request.now)
            }
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
