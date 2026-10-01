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
    }
    /// Optional for caches written by earlier releases.
    var sourceChecks: [String: SourceCheck]?

    var models: [ModelRelease] = []
    var modelsFetchedAt: Date?
    /// When the last check failed (no answer, or an error status), so the next waits
    /// `NewsFetcher.retryInterval` instead of going out on every refresh. Cleared by an answer.
    var modelsFailedAt: Date?
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
        let newestFirst: (FeedItem, FeedItem) -> Bool = { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        var kept: [FeedItem] = []
        var keptFeeds: [String] = []
        var positions: [String: Int] = [:]
        let entries = items.flatMap { id, feed in products[id].map { product in feed.map { (item: $0, feed: id, product: product) } } ?? [] }
        for (item, feed, product) in entries.sorted(by: { newestFirst($0.item, $1.item) }) {
            let keys = [item.link.map { "link \($0.absoluteString)" }, "title \(product) \(item.duplicateKey)"].compactMap { $0 }
            if let position = keys.lazy.compactMap({ positions[$0] }).first {
                if let published = item.published, published < (kept[position].published ?? .distantFuture) {
                    kept[position].published = published
                }
                if kept[position].alsoIn == nil, feed != keptFeeds[position], let other = feeds[feed] {
                    kept[position].alsoIn = Self.name(of: other, besides: kept[position].source)
                }
                keys.forEach { positions[$0] = position }
                continue
            }
            keys.forEach { positions[$0] = kept.count }
            kept.append(item)
            keptFeeds.append(feed)
        }
        return Array(kept.sorted(by: newestFirst).prefix(limit))
    }

    /// A feed's name as a place an entry also appeared: "Claude Code releases", or "Claude Code
    /// changelog" beside an entry already shown under "Claude Code".
    static func name(of feed: FeedSource, besides source: String) -> String {
        feed.name == source ? "\(feed.name) \(NewsEditions.kind(of: feed).lowercased())" : feed.name
    }

    static func load(from directory: URL?) -> NewsCache {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let cache = try? RelayEnvelope.decoder.decode(NewsCache.self, from: data)
        else { return NewsCache() }
        return cache
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
    static let modelInterval: TimeInterval = 6 * 3600
    static let announcementInterval: TimeInterval = 12 * 3600
    /// Opening News (the iPhone tab or the app coming forward, the Mac window) refreshes
    /// anything older than this.
    static let openInterval: TimeInterval = 15 * 60
    /// While News is on screen it checks again this often by itself, so nobody has to pull or
    /// press Check Now to catch up. Conditional GETs keep an unchanged feed to a 304.
    static let liveInterval: TimeInterval = 15 * 60
    /// A failed check waits this long before the next, unless asked for (pulling to refresh,
    /// Check now), so a server that's down isn't asked on every refresh.
    static let retryInterval: TimeInterval = 3600

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
    }

    /// What a GET got back.
    enum Answer: Sendable {
        /// The body, up to the size limit; `isTruncated` when it went on past it.
        case body(Data, NewsCache.Validator, isTruncated: Bool)
        /// 304: the cached copy is current.
        case notModified
        /// An answer with an error status.
        case status(Int)
        /// No answer.
        case unreachable
    }

    /// Fetches what's due: models every 6 hours, announcements every 12, or anything older than
    /// `maxAge` when given (opening the tab, pulling to refresh).
    static func refresh(_ cache: NewsCache, sources: [FeedSource], following vendors: Set<String>, maxAge: TimeInterval? = nil, now: Date = .now, forcedSources: Set<String> = []) async -> Result {
        var cache = cache
        // Freeze legacy sources' dates before another source advances the shared timestamp.
        var migrated = cache.sourceChecks ?? [:]
        for source in FeedSource.catalog + sources where cache.items[source.id] != nil && migrated[source.id] == nil {
            migrated[source.id] = cache.check(for: source)
        }
        if !migrated.isEmpty { cache.sourceChecks = migrated }
        var newModels: [ModelRelease] = []
        var unreadable = cache.unreadable ?? []

        if isDue(cache.modelsFetchedAt, failedAt: cache.modelsFailedAt, interval: maxAge ?? modelInterval, now: now) {
            let key = ModelFeed.url.absoluteString
            switch await get(ModelFeed.url, validator: cache.validators[key]) {
            case let .body(data, validator, isTruncated):
                if !isTruncated, let releases = try? ModelFeed.releases(from: data) {
                    cache.models = firstSeen(releases, previous: cache.models, now: now)
                    newModels = cache.modelState.takeNew(from: cache.models, following: vendors)
                    cache.validators[key] = validator
                    unreadable.remove(ModelFeed.id)
                    cache.modelsFetchedAt = now
                    cache.modelsFailedAt = nil
                } else {
                    // Keeps the last list, and asks for the whole answer next time.
                    cache.validators[key] = nil
                    unreadable.insert(ModelFeed.id)
                    cache.modelsFailedAt = now
                }
            case .notModified:
                if cache.modelsFetchedAt != nil {
                    cache.modelsFetchedAt = now
                    cache.modelsFailedAt = nil
                    unreadable.remove(ModelFeed.id)
                } else {
                    cache.validators[key] = nil
                    cache.modelsFailedAt = now
                    unreadable.insert(ModelFeed.id)
                }
            case .status:
                cache.modelsFailedAt = now
                unreadable.insert(ModelFeed.id)
            case .unreachable:
                // A cancelled refresh (quitting, sleep) isn't a failure.
                if !Task.isCancelled {
                    cache.modelsFailedAt = now
                    unreadable.insert(ModelFeed.id)
                }
            }
        }

        let due = sources.filter { source in
            let check = cache.check(for: source)
            return forcedSources.contains(source.id) || isDue(check.succeededAt, failedAt: check.failedAt, interval: maxAge ?? announcementInterval, now: now)
        }
        if !due.isEmpty {
            let previous = cache.validators
            let answers = await withTaskGroup(of: (FeedSource, Answer).self) { group in
                for source in due {
                    group.addTask { (source, await get(source.url, validator: previous[source.url.absoluteString], sizeLimit: source.sizeLimit)) }
                }
                var answers: [(FeedSource, Answer)] = []
                for await answer in group { answers.append(answer) }
                return answers
            }
            var anySucceeded = false
            var anyFailed = false
            var checks = cache.sourceChecks ?? [:]
            for (source, answer) in answers {
                let key = source.url.absoluteString
                var check = cache.check(for: source)
                var success = false
                switch answer {
                case let .body(data, validator, isTruncated):
                    let read = FeedParser.read(data, source: source)
                    let previousItems = cache.items[source.id] ?? []
                    let items = firstSeen(read.items, previous: previousItems, now: now)
                    if read.isComplete, !isTruncated {
                        cache.items[source.id] = items
                        cache.validators[key] = validator
                        success = true
                    } else {
                        // A partial response supplements the last complete copy, never deletes it.
                        let ids = Set(items.map(\.id))
                        cache.items[source.id] = (items + previousItems.filter { !ids.contains($0.id) })
                            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
                        cache.validators[key] = nil
                    }
                case .notModified:
                    success = cache.items[source.id] != nil
                    if !success { cache.validators[key] = nil }
                case .status: break
                case .unreachable:
                    if Task.isCancelled { continue }
                }
                if success {
                    check.succeededAt = now
                    check.failedAt = nil
                    unreadable.remove(source.id)
                    anySucceeded = true
                } else {
                    check.failedAt = now
                    unreadable.insert(source.id)
                    anyFailed = true
                }
                checks[source.id] = check
            }
            cache.sourceChecks = checks
            if anySucceeded { cache.announcementsFetchedAt = now }
            cache.announcementsFailedAt = anyFailed ? now : nil
        }
        cache.unreadable = unreadable.isEmpty ? nil : unreadable
        return Result(cache: cache, newModels: newModels)
    }

    static func isDue(_ fetchedAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        fetchedAt.map { now.timeIntervalSince($0) >= interval } ?? true
    }

    /// Due by `interval`, and, after a failed check, once `retryInterval` has passed, however
    /// often News is open or on screen; asking with a `maxAge` of 0 (pulling to refresh, Check
    /// Now) always goes out.
    static func isDue(_ fetchedAt: Date?, failedAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        if let failedAt, fetchedAt == nil || failedAt >= fetchedAt! {
            return isDue(failedAt, interval: interval <= 0 ? 0 : retryInterval, now: now)
        }
        return isDue(fetchedAt, interval: interval, now: now)
    }

    /// Items dated no later than the check that first saw them: one dated ahead (a wrong time
    /// zone, a post scheduled early) counts as seen once News opens, and a later change to its
    /// date doesn't make it new again.
    static func firstSeen(_ items: [FeedItem], previous: [FeedItem], now: Date) -> [FeedItem] {
        let earlier = Dictionary(previous.compactMap { item in item.published.map { (item.id, $0) } }) { first, _ in first }
        return items.map { item in
            var item = item
            let latest = min(earlier[item.id] ?? now, now)
            item.published = item.published.map { min($0, latest) }
            return item
        }
    }

    /// Releases dated no later than the check that first saw them, newest first.
    static func firstSeen(_ releases: [ModelRelease], previous: [ModelRelease], now: Date) -> [ModelRelease] {
        let earlier = Dictionary(previous.map { ($0.id, $0.created) }) { first, _ in first }
        return releases.map { release in
            var release = release
            release.created = min(release.created, earlier[release.id] ?? now, now)
            return release
        }
        .sorted { $0.created > $1.created }
    }

    /// A conditional GET that reads at most `sizeLimit` bytes: a longer body stops there instead
    /// of loading whole.
    static func get(_ url: URL, validator: NewsCache.Validator?, sizeLimit: Int = FeedParser.sizeLimit) async -> Answer {
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
        do {
            let (bytes, response) = try await TokenroomHTTP.session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .unreachable
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()
                return http.statusCode == 304 ? .notModified : .status(http.statusCode)
            }
            var data = Data()
            var isTruncated = false
            for try await byte in bytes {
                guard data.count < sizeLimit else {
                    isTruncated = true
                    break
                }
                data.append(byte)
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
