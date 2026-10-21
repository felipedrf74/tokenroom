import Foundation

/// What the News tab shows, kept on the device: new models and official announcements.
/// Titles, dates, and links only.
struct NewsCache: Codable, Equatable, Sendable {
    static let fileName = "news.json"

    struct Validator: Codable, Equatable, Sendable {
        var etag: String?
        var lastModified: String?
    }

    struct SourceCheck: Codable, Equatable, Sendable {
        var succeededAt: Date?
        var failedAt: Date?
        /// Failed checks in a row since the last success, for `NewsFetcher.retryInterval`. Nil
        /// after a success, and in caches from earlier releases.
        var failures: Int?
        /// When the feed's server asked to be asked again (Retry-After), as allowed: no
        /// automatic check goes out before it. Nil after a success.
        var retryAt: Date?
    }
    /// Optional for caches written by earlier releases.
    var sourceChecks: [String: SourceCheck]?

    var models: [ModelRelease] = []
    var modelsFetchedAt: Date?
    /// When the last check failed (no answer, or an error status), so the next waits
    /// `NewsFetcher.retryInterval` instead of going out on every refresh. Cleared by an answer.
    var modelsFailedAt: Date?
    /// The model list's failed checks in a row; nil after an answer, and in older caches.
    var modelsFailures: Int?
    /// When OpenRouter asked to be asked again (Retry-After), as allowed; nil after an answer.
    var modelsRetryAt: Date?
    var modelState = ModelFeedState()
    /// Items per feed ID, newest first.
    var items: [String: [FeedItem]] = [:]
    var announcementsFetchedAt: Date?
    /// When the last check failed for every feed.
    var announcementsFailedAt: Date?
    /// Conditional GET validators per URL, so unchanged feeds cost a 304.
    var validators: [String: Validator] = [:]
    /// Feeds whose last answer couldn't be read in full, by ID (`ModelFeed.id` for the model
    /// list): an error status, a feed past its size limit, or not a feed at all.
    var unreadable: Set<String>?

    func check(for source: FeedSource) -> SourceCheck {
        if let check = sourceChecks?[source.id] { return check }
        // Migrate a cached source's old shared success time; never delay an uncached source.
        guard items[source.id] != nil else { return SourceCheck() }
        return SourceCheck(succeededAt: announcementsFetchedAt,
                           failedAt: unreadable?.contains(source.id) == true ? (announcementsFailedAt ?? announcementsFetchedAt) : nil)
    }

    /// Announcements from the given feeds, newest first. An entry two feeds share shows once: the
    /// newer copy, dated when the first one appeared, so it isn't new again when the second feed
    /// catches up, and noting the other feed in `alsoIn`. Titles and versions only match within a
    /// product's own feeds (a changelog and its GitHub releases); two products' entries fold only
    /// when they link to the same page.
    func announcements(from sources: [FeedSource], limit: Int = 80) -> [FeedItem] {
        let products = Dictionary(sources.map { ($0.id, $0.partOf ?? $0.id) }) { first, _ in first }
        let feeds = Dictionary(sources.map { ($0.id, $0) }) { first, _ in first }
        let newestFirst: (FeedItem, FeedItem) -> Bool = {
            $0.sortDate == $1.sortDate ? $0.stableID < $1.stableID : $0.sortDate > $1.sortDate
        }
        // Stable positions let a bridging entry merge every matching group without losing
        // the keys learned from copies that have already been folded.
        var kept: [FeedItem?] = []
        var keptFeeds: [String] = []
        var positions: [String: Int] = [:]
        let entries = items.flatMap { id, feed in products[id].map { product in feed.map { (item: $0, feed: id, product: product) } } ?? [] }
        for (raw, feed, product) in entries.sorted(by: { newestFirst($0.item, $1.item) }) {
            var item = raw
            item.sourceID = feed
            item.kind = feeds[feed]?.kind ?? .officialAnnouncement
            item.firstSeenAt = item.firstSeenAt ?? item.published ?? item.updatedAt
            let paired = sources.contains { $0.partOf == product }
            if paired, let range = item.duplicateKey.range(of: #"\d+(\.\d+)+([-+.][0-9a-z.]+)?"#, options: .regularExpression) {
                item.canonicalID = "release|\(product)|\(item.duplicateKey[range])"
            }
            let keys: [String]
            if item.kind == .officialAnnouncement {
                // A feed whose entries share titles (commits) is matched by link and ID only.
                let byTitle = feeds[feed]?.isCommitLog == true ? "item \(feed)|\(item.id)" : "title \(product) \(item.duplicateKey)"
                keys = [item.link.map { "official link \(Self.linkKey($0))" }, item.link.flatMap(Self.googlePostKey), item.canonicalID, byTitle].compactMap { $0 }
            } else { keys = ["item \(feed)|\(item.id)"] }
            let matches = Set(keys.compactMap { positions[$0] })
            if let position = matches.min(), var winner = kept[position] {
                var copies = matches.sorted().filter { $0 != position }.compactMap { kept[$0] }
                copies.append(item)
                for copy in copies {
                    winner.firstSeenAt = [winner.newsDate, copy.newsDate].compactMap { $0 }.min()
                    // Legacy stored date is bookkeeping, not an original publisher timestamp.
                    if let date = copy.published { winner.published = min(date, winner.published ?? date) }
                    winner.aliases = winner.aliasIDs.union(copy.aliasIDs).union([copy.stableID])
                    if winner.alsoIn == nil, copy.sourceID != keptFeeds[position],
                       let other = copy.sourceID.flatMap({ feeds[$0] }) {
                        winner.alsoIn = Self.name(of: other, besides: winner.source)
                    }
                }
                kept[position] = winner
                for other in matches where other != position { kept[other] = nil }
                // Repoint every inherited key, not just this entry's keys, to the winner.
                let redirected = positions.keys.filter { matches.contains(positions[$0]!) }
                for key in redirected { positions[key] = position }
                keys.forEach { positions[$0] = position }
                continue
            }
            keys.forEach { positions[$0] = kept.count }
            kept.append(item)
            keptFeeds.append(feed)
        }
        return Array(kept.compactMap { $0 }.sorted(by: newestFirst).prefix(limit))
    }

    /// A link as the same page however it's written: host case and `www.`, a trailing slash, and
    /// tracking parameters (`utm_…`) aside. The fragment stays: changelogs link each entry to its
    /// own anchor on one page.
    static func linkKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host.map { host in
            let host = host.lowercased()
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        let query = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") }
        parts.queryItems = query?.isEmpty == true ? nil : query
        return parts.string ?? url.absoluteString
    }

    /// Google posts some stories on both its Keyword blog and DeepMind's, under the same slug
    /// (`blog.google/…/gemini-3/`, `deepmind.google/…/gemini-3/`): one post, shown once.
    static func googlePostKey(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), ["blog.google", "deepmind.google"].contains(host) else { return nil }
        let slug = url.pathComponents.last { $0 != "/" }?.lowercased() ?? ""
        guard slug.count > 3, !["blog", "discover", "technology", "products"].contains(slug) else { return nil }
        return "google post \(slug)"
    }

    /// A feed's name as a place an entry also appeared: "Claude Code releases", or "Claude Code
    /// changelog" beside an entry already shown under "Claude Code".
    static func name(of feed: FeedSource, besides source: String) -> String {
        feed.name == source ? "\(feed.name) \(NewsEditions.kind(of: feed).lowercased())" : feed.name
    }

    /// Persist the associations learned while paired copies coexist. Carry them on the
    /// surviving raw item when the other feed rotates it out, without retaining old articles.
    mutating func retainFoldedIdentities(from previous: NewsCache, sources: [FeedSource]) {
        var combined = self
        for source in sources {
            let current = combined.items[source.id] ?? []
            let ids = Set(current.map(\.id))
            combined.items[source.id] = current + (previous.items[source.id] ?? []).filter { !ids.contains($0.id) }
        }
        let groups = combined.announcements(from: sources, limit: .max)
        var identities: [String: FeedItem] = [:]
        for group in groups { for alias in group.aliasIDs { identities[alias] = group } }
        for source in sources {
            guard let current = items[source.id] else { continue }
            items[source.id] = current.map { raw in
                var item = raw
                if let group = identities["\(source.id)|\(raw.id)"] {
                    item.aliases = group.aliasIDs
                    item.firstSeenAt = [item.newsDate, group.newsDate].compactMap { $0 }.min()
                }
                return item
            }
        }
    }

    /// The model list answered: checked now, and no longer failing.
    mutating func modelsSucceeded(at now: Date) {
        modelsFetchedAt = now
        modelsFailedAt = nil
        modelsFailures = nil
        modelsRetryAt = nil
    }

    /// The model list's check failed once more, so the next waits a little longer, and no less
    /// than OpenRouter asked (`retryAfter`).
    mutating func modelsFailed(at now: Date, retryAfter: Date? = nil) {
        modelsFailedAt = now
        modelsFailures = (modelsFailures ?? 0) + 1
        modelsRetryAt = NewsFetcher.allowedRetry(retryAfter, now: now)
    }

    static func load(from directory: URL?) -> NewsCache {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let cache = try? RelayEnvelope.decoder.decode(NewsCache.self, from: data)
        else { return NewsCache() }
        return cache
    }

    /// Dates saved while the clock was ahead come back to `now`, so what they mark doesn't stay
    /// new or badged after a visit until the clock catches up.
    mutating func bringDatesBack(to now: Date) {
        for (id, feed) in items where feed.contains(where: { ($0.firstSeenAt ?? .distantPast) > now || ($0.published ?? .distantPast) > now }) {
            items[id] = feed.map { item in
                var item = item
                item.firstSeenAt = item.firstSeenAt.map { min($0, now) }
                item.published = item.published.map { min($0, now) }
                return item
            }
        }
        if models.contains(where: { $0.newsDate > now || $0.created > now }) {
            models = models.map { model in
                var model = model
                model.created = min(model.created, now)
                model.firstSeenAt = model.firstSeenAt.map { min($0, now) }
                return model
            }
        }
    }

    func save(to directory: URL?) {
        guard let url = directory?.appendingPathComponent(Self.fileName),
              let data = try? RelayEnvelope.encoder.encode(self)
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

enum NewsFetcher {
    /// How often the model list and each feed are checked in the background (the iPhone's
    /// background refresh, the Mac's sharing loop). Conditional GETs keep an unchanged feed to a 304.
    static let modelInterval: TimeInterval = 3600
    static let announcementInterval: TimeInterval = 3600
    /// Opening News (the iPhone tab or the app coming forward, the Mac window) refreshes
    /// anything older than this.
    static let openInterval: TimeInterval = 5 * 60
    /// While News is on screen it checks again this often by itself, so nobody has to pull or
    /// press Check Now to catch up.
    static let liveInterval: TimeInterval = 5 * 60
    /// After a failed check the next waits longer the more checks have failed in a row: 5, 15,
    /// and 30 minutes, then an hour each time, unless asked for (pulling to refresh, Check Now).
    /// A server that's down isn't asked on every refresh, and one back up is found soon.
    static let retryIntervals: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 3600]

    /// The wait after `failures` failed checks in a row; a failure an earlier release recorded,
    /// without a count, is the first.
    static func retryInterval(afterFailures failures: Int?) -> TimeInterval {
        retryIntervals[min(max(failures ?? 1, 1), retryIntervals.count) - 1]
    }

    /// The longest a server's Retry-After holds a feed off: a feed asking for days is still
    /// tried again within this.
    static let longestRetryAfter: TimeInterval = 6 * 3600

    /// A server's Retry-After as the time the next automatic check may go out: kept within
    /// `longestRetryAfter`, and none for one already past.
    static func allowedRetry(_ retryAfter: Date?, now: Date) -> Date? {
        guard let retryAfter, retryAfter > now else { return nil }
        return min(retryAfter, now.addingTimeInterval(longestRetryAfter))
    }

    struct Result: Sendable {
        var cache: NewsCache
        /// New releases from followed labs since the last check, for a notification.
        var newModels: [ModelRelease]
    }

    struct Request: Sendable {
        var cache: NewsCache
        var sources: [FeedSource]
        var vendors: Set<String>
        var maxAge: TimeInterval?
        var now: Date
        var forcedSources: Set<String> = []
        /// Sources whose read is quiet, like a first read (`firstSeen`'s `quiet`).
        var quietSources: Set<String> = []
        /// Shown the cache as each answer is taken in, before the whole pass is done.
        var publish: @MainActor @Sendable (NewsCache) -> Void = { _ in }
        /// Rechecked before each public GET; already-issued requests may finish normally.
        var isAllowed: @MainActor @Sendable () -> Bool = { true }
    }

    /// Feeds run to megabytes (`FeedSource.sizeLimit`), so a download has this long on a slow
    /// network, not a provider check's `TokenroomHTTP.timeout`; a pause longer than that still
    /// ends it sooner.
    static let downloadTimeout: TimeInterval = 60

    /// The session News reads through: `TokenroomHTTP`'s settings and redirect rules, with
    /// `downloadTimeout` for the whole download. A session tests swap into `TokenroomHTTP` is
    /// used as it is.
    static var session: URLSession {
        let shared = TokenroomHTTP.session
        return shared === TokenroomHTTP.defaultSession ? downloadSession : shared
    }

    private static let downloadSession: URLSession = {
        // A copy: no cookies, no cache, Tokenroom's user agent, the same wait between packets.
        let configuration = TokenroomHTTP.defaultSession.configuration
        configuration.timeoutIntervalForResource = downloadTimeout
        return URLSession(configuration: configuration, delegate: FeedRedirectDelegate(), delegateQueue: nil)
    }()

    /// What a GET got back.
    enum Answer: Sendable {
        /// The body, up to the size limit; `isTruncated` when it went on past it, or was cut off
        /// partway.
        case body(Data, NewsCache.Validator, isTruncated: Bool)
        /// 304: the cached copy is current.
        case notModified
        /// An answer with an error status, and its Retry-After, if any.
        case status(Int, retryAfter: String?)
        /// No answer.
        case unreachable
    }

    /// Fetches what's due: the model list and each feed every hour, a failed one after its
    /// `retryInterval`, or anything older than `maxAge` when given (opening the tab, pulling to
    /// refresh).
    static func refresh(_ cache: NewsCache, sources: [FeedSource], following vendors: Set<String>, maxAge: TimeInterval? = nil, now: Date = .now, forcedSources: Set<String> = [], quietSources: Set<String> = [], isAllowed: @escaping @MainActor @Sendable () -> Bool = { true }, publish: @escaping @MainActor @Sendable (NewsCache) -> Void = { _ in }) async -> Result {
        var cache = cache
        // Freeze legacy sources' dates before another source advances the shared timestamp.
        var migrated = cache.sourceChecks ?? [:]
        for source in FeedSource.catalog + sources where cache.items[source.id] != nil && migrated[source.id] == nil {
            migrated[source.id] = cache.check(for: source)
        }
        if !migrated.isEmpty { cache.sourceChecks = migrated }
        var newModels: [ModelRelease] = []
        var unreadable = cache.unreadable ?? []

        // The model list has no validators, so every check downloads all of it: it keeps to its
        // hourly interval while News is open or on screen; only a pull or Check Now asks sooner.
        let modelAge = maxAge == 0 ? 0 : modelInterval
        if forcedSources.contains(ModelFeed.id) || isDue(cache.modelsFetchedAt, failedAt: cache.modelsFailedAt, failures: cache.modelsFailures, retryAt: cache.modelsRetryAt, interval: modelAge, now: now) {
            let key = ModelFeed.url.absoluteString
            guard let answer = await permittedGet(ModelFeed.url, validator: cache.validators[key], isAllowed: isAllowed) else {
                return .init(cache: cache, newModels: [])
            }
            switch answer {
            case let .body(data, validator, isTruncated):
                if !isTruncated, let releases = try? ModelFeed.releases(from: data) {
                    cache.models = firstSeen(releases, previous: cache.models, now: now, previousRead: cache.modelsFetchedAt)
                    newModels = cache.modelState.takeNew(from: cache.models, following: vendors)
                    cache.validators[key] = validator
                    unreadable.remove(ModelFeed.id)
                    cache.modelsSucceeded(at: now)
                } else {
                    // Keeps the last list, and asks for the whole answer next time.
                    cache.validators[key] = nil
                    unreadable.insert(ModelFeed.id)
                    cache.modelsFailed(at: now)
                }
            case .notModified:
                if cache.modelsFetchedAt != nil {
                    cache.modelsSucceeded(at: now)
                    unreadable.remove(ModelFeed.id)
                } else {
                    cache.validators[key] = nil
                    cache.modelsFailed(at: now)
                    unreadable.insert(ModelFeed.id)
                }
            case let .status(_, retryAfter):
                cache.modelsFailed(at: now, retryAfter: TokenroomHTTP.retryDate(retryAfter, now: now))
                unreadable.insert(ModelFeed.id)
            case .unreachable:
                // A cancelled refresh (quitting, sleep) isn't a failure.
                if !Task.isCancelled {
                    cache.modelsFailed(at: now)
                    unreadable.insert(ModelFeed.id)
                }
            }
            // Shown before the feeds are in.
            var shown = cache
            shown.unreadable = unreadable.isEmpty ? nil : unreadable
            await publish(shown)
        }

        let due = sources.filter { source in
            let check = cache.check(for: source)
            return forcedSources.contains(source.id) || isDue(check.succeededAt, failedAt: check.failedAt, failures: check.failures, retryAt: check.retryAt, interval: maxAge ?? announcementInterval, now: now)
        }
        if !due.isEmpty {
            let previous = cache.validators
            let needsExcerptBody = Set(due.filter { source in
                cache.items[source.id]?.contains { $0.excerpt != nil && $0.excerptIsPlainText != true } == true
            }.map(\.id))
            var anySucceeded = false
            var anyFailed = false
            var checks = cache.sourceChecks ?? [:]
            // Each feed's answer is taken in, and shown (`publish`), as it arrives: a slow feed
            // doesn't hold the others back.
            await withTaskGroup(of: (FeedSource, Answer?).self) { group in
                for source in due {
                    group.addTask {
                        return (source, await permittedGet(source.url, validator: needsExcerptBody.contains(source.id) ? nil : previous[source.url.absoluteString], sizeLimit: source.sizeLimit, isAllowed: isAllowed))
                    }
                }
                for await (source, answer) in group {
                    guard let answer else { continue } // Disabled checks are neither failures nor fresh readings.
                    let key = source.url.absoluteString
                    var check = cache.check(for: source)
                    var success = false
                    var retryAfter: Date?
                    switch answer {
                    case let .body(data, validator, isTruncated):
                        let read = FeedParser.read(data, source: source)
                        let previousItems = cache.items[source.id] ?? []
                        let items = firstSeen(read.items, previous: previousItems, now: now, quiet: quietSources.contains(source.id), previousRead: check.succeededAt)
                        // A feed with no entries at all where some were cached isn't taken at its
                        // word: a server's placeholder would clear the list.
                        if read.isComplete, !isTruncated, read.entries > 0 || previousItems.isEmpty {
                            // Every entry left out (a run of pre-releases): the last ones stay.
                            cache.items[source.id] = items.isEmpty ? previousItems : items
                            cache.validators[key] = validator
                            success = true
                        } else {
                            // A partial response supplements the last complete copy, never deletes it,
                            // and keeps to a feed's usual length.
                            let ids = Set(items.map(\.id))
                            if !items.isEmpty || cache.items[source.id] != nil {
                                cache.items[source.id] = Array((items + previousItems.filter { !ids.contains($0.id) })
                                    .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
                                    .prefix(FeedParser.itemLimit))
                            }
                            cache.validators[key] = nil
                        }
                    case .notModified:
                        success = cache.items[source.id] != nil
                        if !success { cache.validators[key] = nil }
                    case let .status(_, asked): retryAfter = TokenroomHTTP.retryDate(asked, now: now)
                    case .unreachable:
                        if Task.isCancelled { continue }
                    }
                    if success {
                        check.succeededAt = now
                        check.failedAt = nil
                        check.failures = nil
                        check.retryAt = nil
                        unreadable.remove(source.id)
                        anySucceeded = true
                    } else {
                        check.failedAt = now
                        check.failures = (check.failures ?? 0) + 1
                        check.retryAt = allowedRetry(retryAfter, now: now)
                        unreadable.insert(source.id)
                        anyFailed = true
                    }
                    checks[source.id] = check
                    cache.sourceChecks = checks
                    cache.unreadable = unreadable.isEmpty ? nil : unreadable
                    if anySucceeded { cache.announcementsFetchedAt = now }
                    await publish(cache)
                }
            }
            if anySucceeded || anyFailed { cache.announcementsFailedAt = anyFailed ? now : nil }
        }
        cache.unreadable = unreadable.isEmpty ? nil : unreadable
        return Result(cache: cache, newModels: newModels)
    }

    /// Due once `interval` has passed since `fetchedAt`, or when `fetchedAt` is later than `now`:
    /// saved while the clock was ahead, it would otherwise hold checks off until then.
    static func isDue(_ fetchedAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        fetchedAt.map { $0 > now || now.timeIntervalSince($0) >= interval } ?? true
    }

    /// Due by `interval`, and, after `failures` failed checks in a row, once their
    /// `retryInterval` has passed and no sooner than the server asked (`retryAt`), however often
    /// News is open or on screen; asking with a `maxAge` of 0 (pulling to refresh, Check Now)
    /// always goes out.
    static func isDue(_ fetchedAt: Date?, failedAt: Date?, failures: Int? = nil, retryAt: Date? = nil, interval: TimeInterval, now: Date) -> Bool {
        if let failedAt, fetchedAt == nil || failedAt >= fetchedAt! {
            guard interval > 0 else { return true }
            // A time asked for further off than allowed was saved while the clock was ahead.
            if let retryAt, retryAt > now, retryAt.timeIntervalSince(now) <= longestRetryAfter { return false }
            return isDue(failedAt, interval: retryInterval(afterFailures: failures), now: now)
        }
        return isDue(fetchedAt, interval: interval, now: now)
    }

    /// An entry dated this long before its feed's previous successful read was out by then: it's
    /// only new to the feed's window (an older post moved up), so it keeps its own date. Two days
    /// leave room for a post dated by the day that turns up the next.
    static let arrivalSlack: TimeInterval = 2 * 86_400

    /// Items dated no later than the check that first saw them: one dated ahead (a wrong time
    /// zone, a post scheduled early) counts as seen once News opens, and a later change to its
    /// date doesn't make it new again.
    ///
    /// `firstSeenAt` is when it reached this device, so an entry dated earlier than it turned up
    /// (a post dated midnight that arrives in the afternoon) is still new, and one without any
    /// date is dated when it arrives, so it sorts with what came then rather than last. A quiet
    /// read (a feed's first, or one followed again: `quiet`, or nothing cached) brings what was
    /// there already, so it has no arrival to go by: its entries keep their own dates, an undated
    /// one still sorts last, and `NewsStore` keeps them from counting as new. One dated well
    /// before the feed's previous successful read (`previousRead`, `arrivalSlack`) keeps its own
    /// date too. A first-seen date saved ahead of the clock comes back to `now`.
    static func firstSeen(_ items: [FeedItem], previous: [FeedItem], now: Date, quiet: Bool = false, previousRead: Date? = nil) -> [FeedItem] {
        let earlier = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
        let isQuiet = quiet || previous.isEmpty
        return items.map { incoming in
            var item = incoming
            let old = earlier[item.id]
            if let old { item.aliases = old.aliasIDs.union(item.aliasIDs) }
            let dated = min(item.publisherPublishedAt ?? item.updatedAt ?? item.published ?? now, now)
            let enteredWindow = previousRead.map { dated < $0.addingTimeInterval(-arrivalSlack) } ?? false
            item.firstSeenAt = min(old?.newsDate ?? (isQuiet || enteredWindow ? dated : now), now)
            item.published = item.published.map { min($0, old?.published ?? now, now) }
            if item.published == nil, item.updatedAt == nil {
                // One cached undated by an earlier release stays so, rather than turning new now.
                item.published = old == nil ? (isQuiet ? nil : now) : old?.published
            }
            if item.kind == .officialStatus {
                let update = FeedItem.StatusUpdate(date: item.updatedAt ?? item.publisherPublishedAt, excerpt: item.excerpt)
                var updates = old?.observedUpdates ?? []
                if !updates.contains(update) { updates.insert(update, at: 0) }
                item.observedUpdates = Array(updates.prefix(5))
            }
            return item
        }
    }

    /// Releases dated no later than the check that first saw them, newest first, each noting when
    /// it arrived (`firstSeenAt`) as announcements do: the list's first read, and a model created
    /// well before the list's previous read (`previousRead`, `arrivalSlack`), keep their own dates.
    static func firstSeen(_ releases: [ModelRelease], previous: [ModelRelease], now: Date, previousRead: Date? = nil) -> [ModelRelease] {
        let earlier = Dictionary(previous.map { ($0.id, $0) }) { first, _ in first }
        return releases.map { release in
            var release = release
            let old = earlier[release.id]
            release.created = min(release.created, old?.created ?? now, now)
            let enteredList = previousRead.map { release.created < $0.addingTimeInterval(-arrivalSlack) } ?? false
            release.firstSeenAt = min(old?.newsDate ?? (previous.isEmpty || enteredList ? release.created : now), now)
            return release
        }
        .sorted { $0.created > $1.created }
    }

    /// Check the live owner on the transport entry's actor, without hopping back to a
    /// generic worker after authorization. A veto is not an unsuccessful check.
    @MainActor static func permittedGet(_ url: URL, validator: NewsCache.Validator?, sizeLimit: Int = FeedParser.sizeLimit,
                                       isAllowed: @MainActor @Sendable () -> Bool) async -> Answer? {
        guard !Task.isCancelled, isAllowed() else { return nil }
        return await get(url, validator: validator, sizeLimit: sizeLimit)
    }

    /// A conditional GET that reads at most `sizeLimit` bytes: a longer body stops there instead
    /// of loading whole. One cut off partway (the time ran out, the network dropped) gives what
    /// arrived, as one past its limit does.
    @MainActor static func get(_ url: URL, validator: NewsCache.Validator?, sizeLimit: Int = FeedParser.sizeLimit) async -> Answer {
        guard !Task.isCancelled else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = TokenroomHTTP.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/rss+xml, application/atom+xml, application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag = validator?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validator?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return await download(request, sizeLimit: sizeLimit)
    }

    /// The download itself, off the main actor: its body is read where it arrives, a buffer at a
    /// time, never with a hop to the main actor for each byte, which made a megabyte take seconds
    /// and could run a whole answer past `downloadTimeout`.
    @concurrent private static func download(_ request: URLRequest, sizeLimit: Int) async -> Answer {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .unreachable
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()
                if http.statusCode == 304 { return .notModified }
                return .status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            }
            var data = Data()
            data.reserveCapacity(min(max(Int(http.expectedContentLength), 0), sizeLimit))
            var buffer: [UInt8] = []
            buffer.reserveCapacity(64 * 1024)
            var isTruncated = false
            do {
                for try await byte in bytes {
                    guard data.count + buffer.count < sizeLimit else {
                        isTruncated = true
                        break
                    }
                    buffer.append(byte)
                    if buffer.count == buffer.capacity {
                        data.append(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                data.append(contentsOf: buffer)
            } catch {
                data.append(contentsOf: buffer)
                // A cancelled check isn't a failure, and nothing at all is no answer.
                guard !Task.isCancelled, !data.isEmpty else { return .unreachable }
                isTruncated = true
            }
            if isTruncated {
                // The rest of the body is never downloaded.
                bytes.task.cancel()
            }
            let fresh = NewsCache.Validator(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
            return .body(data, fresh, isTruncated: isTruncated)
        } catch {
            return .unreachable
        }
    }
}

/// The redirect rules `TokenroomHTTP.defaultSession` applies, for News's own session: a feed may
/// move to another HTTPS host, never to cleartext or a URL carrying credentials.
private final class FeedRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(TokenroomRedirectPolicy.allows(original: task.originalRequest, current: task.currentRequest, redirected: request) ? request : nil)
    }
}

extension ModelRelease {
    /// "Anthropic: Claude Opus 5.5" reads as "Claude Opus 5.5" under its lab's name.
    var shortName: String {
        guard let colon = name.range(of: ": ") else { return name }
        return String(name[colon.upperBound...])
    }

    /// The lab as OpenRouter names it, e.g. "Anthropic".
    var vendorName: String {
        name.range(of: ": ").map { String(name[..<$0.lowerBound]) } ?? vendor
    }

    var link: URL? {
        URL(string: "https://openrouter.ai/\(id)")
    }
}
