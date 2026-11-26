import Foundation

struct NewsCache: Codable, Equatable, Sendable {
    static let fileName = "news.json"

    struct Validator: Codable, Equatable, Sendable {
        var etag: String?
        var lastModified: String?
    }

    struct SourceCheck: Codable, Equatable, Sendable {
        var succeededAt: Date?
        var failedAt: Date?
        var failures: Int?
        var retryAt: Date?
        var firstFailedAt: Date? = nil
        var isPermanent: Bool? = nil
        var truncatedAt: Date? = nil
    }
    var sourceChecks: [String: SourceCheck]?

    var models: [ModelRelease] = []
    var modelsFetchedAt: Date?
    var modelsFailedAt: Date?
    var modelsFailures: Int?
    var modelsRetryAt: Date?
    var modelState = ModelFeedState()
    var items: [String: [FeedItem]] = [:]
    var announcementsFetchedAt: Date?
    var announcementsFailedAt: Date?
    var validators: [String: Validator] = [:]
    var unreadable: Set<String>?

    func check(for source: FeedSource) -> SourceCheck {
        if let check = sourceChecks?[source.id] { return check }
        guard items[source.id] != nil else { return SourceCheck() }
        return SourceCheck(succeededAt: announcementsFetchedAt,
                           failedAt: unreadable?.contains(source.id) == true ? (announcementsFailedAt ?? announcementsFetchedAt) : nil)
    }

    static let persistentFailureSpan: TimeInterval = 3600
    static let persistentFailureCount = 3

    func isPersistentlyFailing(_ source: FeedSource) -> Bool {
        let check = check(for: source)
        guard let failedAt = check.failedAt, check.succeededAt.map({ failedAt >= $0 }) ?? true else { return false }
        if check.isPermanent == true { return true }
        guard let failures = check.failures, failures >= Self.persistentFailureCount, let first = check.firstFailedAt else { return false }
        return failedAt.timeIntervalSince(first) > Self.persistentFailureSpan
    }

    func announcements(from sources: [FeedSource], limit: Int = 80) -> [FeedItem] {
        let products = Dictionary(sources.map { ($0.id, $0.partOf ?? $0.id) }) { first, _ in first }
        let feeds = Dictionary(sources.map { ($0.id, $0) }) { first, _ in first }
        let newestFirst: (FeedItem, FeedItem) -> Bool = {
            $0.sortDate == $1.sortDate ? $0.stableID < $1.stableID : $0.sortDate > $1.sortDate
        }
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
            if paired, let version = Self.releaseVersion(of: item) {
                item.canonicalID = "release|\(product)|\(version)"
            }
            let keys: [String]
            if item.kind == .officialAnnouncement {
                let byTitle = feeds[feed]?.isCommitLog == true ? "item \(feed)|\(item.id)" : "title \(product) \(item.duplicateKey)"
                keys = [item.link.map { "official link \(Self.linkKey($0))" }, item.canonicalID, byTitle].compactMap { $0 }
                    + (feeds[feed]?.titleFoldGroup.map { Self.groupTitleKeys(item, group: $0) } ?? [])
            } else { keys = ["item \(feed)|\(item.id)"] }
            let matches = Set(keys.compactMap { positions[$0] })
            if let position = matches.min(), var winner = kept[position] {
                var copies = matches.sorted().filter { $0 != position }.compactMap { kept[$0] }
                copies.append(item)
                for copy in copies {
                    winner.firstSeenAt = [winner.newsDate, copy.newsDate].compactMap { $0 }.min()
                    if let date = copy.published { winner.published = min(date, winner.published ?? date) }
                    winner.aliases = winner.aliasIDs.union(copy.aliasIDs).union([copy.stableID])
                    if winner.alsoIn == nil, copy.sourceID != keptFeeds[position],
                       let other = copy.sourceID.flatMap({ feeds[$0] }) {
                        winner.alsoIn = Self.name(of: other, besides: winner.source)
                    }
                }
                kept[position] = winner
                for other in matches where other != position { kept[other] = nil }
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

    static let versionPattern = #"\d+(\.\d+)+([-+.][0-9a-z.]+)?"#

    static func releaseVersion(of item: FeedItem) -> String? {
        let name = NSRegularExpression.escapedPattern(for: item.source.lowercased())
        let title = #"^(?:"# + name + #"\s+)?(?:(?:release|version)\s+)?v?("# + versionPattern + #")$"#
        if let version = item.duplicateKey.trimmingCharacters(in: .whitespaces).firstCapture(title) { return version }
        guard let link = item.link, let marker = link.pathComponents.firstIndex(of: "tag"), marker > 0,
              link.pathComponents[marker - 1] == "releases", marker + 1 < link.pathComponents.count else { return nil }
        return link.pathComponents[marker + 1].lowercased().firstCapture(#"^(?:[a-z0-9_.-]*?[-@])?v?("# + versionPattern + #")$"#)
    }

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

    static func groupTitleKeys(_ item: FeedItem, group: String) -> [String] {
        guard item.sortDate > .distantPast else { return [] }
        let day = Int((item.sortDate.timeIntervalSince1970 / 86_400).rounded(.down))
        let title = comparableTitle(item.title)
        return (day - 1...day + 1).map { "group \(group) \($0) \(title)" }
    }

    static func comparableTitle(_ title: String) -> String {
        var text = FeedParser.plainText(title)
        for (curly, straight) in [("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{201B}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201F}", "\"")] {
            text = text.replacingOccurrences(of: curly, with: straight)
        }
        return text.lowercased()
    }

    static func name(of feed: FeedSource, besides source: String) -> String {
        feed.name == source ? "\(feed.name) \(NewsEditions.kind(of: feed).lowercased())" : feed.name
    }

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

    mutating func modelsSucceeded(at now: Date) {
        modelsFetchedAt = now
        modelsFailedAt = nil
        modelsFailures = nil
        modelsRetryAt = nil
    }

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
    static var modelInterval: TimeInterval { NewsCadence.intervals(for: .models).background }
    static var announcementInterval: TimeInterval { NewsCadence.intervals(for: .official).background }
    static let openInterval: TimeInterval = 5 * 60
    static let liveInterval: TimeInterval = 5 * 60
    static let retryIntervals: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 3600]

    static func retryInterval(afterFailures failures: Int?) -> TimeInterval {
        retryIntervals[min(max(failures ?? 1, 1), retryIntervals.count) - 1]
    }

    static let longestRetryAfter: TimeInterval = 6 * 3600

    static func allowedRetry(_ retryAfter: Date?, now: Date) -> Date? {
        guard let retryAfter, retryAfter > now else { return nil }
        return min(retryAfter, now.addingTimeInterval(longestRetryAfter))
    }

    struct Result: Sendable {
        var cache: NewsCache
        var newModels: [ModelRelease]
    }

    struct Request: Sendable {
        var cache: NewsCache
        var sources: [FeedSource]
        var vendors: Set<String>
        var maxAge: TimeInterval?
        var now: Date
        var forcedSources: Set<String> = []
        var quietSources: Set<String> = []
        var publish: @Sendable (NewsCache) async -> Void = { _ in }
        var isAllowed: @MainActor @Sendable () -> Bool = { true }
    }

    static let downloadTimeout: TimeInterval = 60

    static var session: URLSession {
        let shared = TokenroomHTTP.session
        return shared === TokenroomHTTP.defaultSession ? downloadSession : shared
    }

    private static let downloadSession: URLSession = {
        let configuration = TokenroomHTTP.defaultSession.configuration
        configuration.timeoutIntervalForResource = downloadTimeout
        return URLSession(configuration: configuration, delegate: FeedRedirectDelegate(), delegateQueue: nil)
    }()

    enum Answer: Sendable {
        case body(Data, NewsCache.Validator, isTruncated: Bool)
        case notModified
        case status(Int, retryAfter: String?)
        case unreachable
        case offline
    }

    static func isPermanent(status: Int) -> Bool {
        status == 404 || status == 410
    }

    private enum PassEvent: Sendable {
        case answer(FeedSource, Answer?)
        case shown
    }

    static func refresh(_ cache: NewsCache, sources: [FeedSource], following vendors: Set<String>, maxAge: TimeInterval? = nil, now: Date = .now, forcedSources: Set<String> = [], quietSources: Set<String> = [], isAllowed: @escaping @MainActor @Sendable () -> Bool = { true }, publish: @escaping @Sendable (NewsCache) async -> Void = { _ in }) async -> Result {
        var cache = cache
        var migrated = cache.sourceChecks ?? [:]
        for source in FeedSource.catalog + sources where cache.items[source.id] != nil && migrated[source.id] == nil {
            migrated[source.id] = cache.check(for: source)
        }
        if !migrated.isEmpty { cache.sourceChecks = migrated }
        var newModels: [ModelRelease] = []
        var unreadable = cache.unreadable ?? []
        var answered = false
        var modelsOffline = false
        var offlineSources: [FeedSource] = []

        let modelAge = NewsCadence.interval(for: .models, maxAge: maxAge)
        if forcedSources.contains(ModelFeed.id) || isDue(cache.modelsFetchedAt, failedAt: cache.modelsFailedAt, failures: cache.modelsFailures, retryAt: cache.modelsRetryAt, interval: modelAge, now: now) {
            let key = ModelFeed.url.absoluteString
            guard let answer = await permittedGet(ModelFeed.url, validator: cache.validators[key], isAllowed: isAllowed) else {
                return .init(cache: cache, newModels: [])
            }
            let listed = cache.models
            switch answer {
            case .offline: break
            case .unreachable where Task.isCancelled: break
            default: answered = true
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
                if !Task.isCancelled {
                    cache.modelsFailed(at: now)
                    unreadable.insert(ModelFeed.id)
                }
            case .offline:
                modelsOffline = true
            }
            if cache.models != listed {
                var shown = cache
                shown.unreadable = unreadable.isEmpty ? nil : unreadable
                await publish(shown)
            }
        }

        let due = sources.filter { source in
            let check = cache.check(for: source)
            return forcedSources.contains(source.id) || isDue(check.succeededAt, failedAt: check.failedAt, failures: check.failures, retryAt: check.retryAt, interval: NewsCadence.interval(for: source, maxAge: maxAge), now: now)
        }
        if !due.isEmpty {
            let previous = cache.validators
            let needsExcerptBody = Set(due.filter { source in
                cache.items[source.id]?.contains { $0.excerpt != nil && $0.excerptIsPlainText != true } == true
            }.map(\.id))
            var anySucceeded = false
            var anyFailed = false
            var checks = cache.sourceChecks ?? [:]
            await withTaskGroup(of: PassEvent.self) { group in
                for source in due {
                    group.addTask {
                        return .answer(source, await permittedGet(source.url, validator: needsExcerptBody.contains(source.id) ? nil : previous[source.url.absoluteString], sizeLimit: source.sizeLimit, isAllowed: isAllowed))
                    }
                }
                var isShowing = false
                var unshown = false
                for await event in group {
                    guard case let .answer(source, answer) = event else {
                        isShowing = false
                        if unshown {
                            unshown = false
                            isShowing = true
                            let shown = cache
                            group.addTask { await publish(shown); return .shown }
                        }
                        continue
                    }
                    guard let answer else { continue }
                    let key = source.url.absoluteString
                    let listed = cache.items[source.id] ?? []
                    var check = cache.check(for: source)
                    var success = false
                    var truncated = false
                    var permanent = false
                    var retryAfter: Date?
                    switch answer {
                    case let .body(data, validator, isTruncated):
                        let read = FeedParser.read(data, source: source)
                        let previousItems = cache.items[source.id] ?? []
                        let items = firstSeen(read.items, previous: previousItems, now: now, quiet: quietSources.contains(source.id), previousRead: check.succeededAt)
                        let pastLimit = isTruncated && data.count >= source.sizeLimit && read.isFeed && read.entries > 0
                        if read.isComplete, !isTruncated, read.entries > 0 || previousItems.isEmpty {
                            cache.items[source.id] = items.isEmpty ? previousItems : items
                            cache.validators[key] = validator
                            success = true
                        } else {
                            let ids = Set(items.map(\.id))
                            if !items.isEmpty || cache.items[source.id] != nil {
                                cache.items[source.id] = Array((items + previousItems.filter { !ids.contains($0.id) })
                                    .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
                                    .prefix(FeedParser.itemLimit))
                            }
                            if pastLimit {
                                if cache.items[source.id] == nil { cache.items[source.id] = [] }
                                cache.validators[key] = validator
                                success = true
                                truncated = true
                            } else {
                                cache.validators[key] = nil
                                let cutShort = isTruncated && data.count < source.sizeLimit
                                permanent = !read.isFeed && !cutShort
                            }
                        }
                    case .notModified:
                        success = cache.items[source.id] != nil
                        if !success { cache.validators[key] = nil }
                        truncated = success && check.truncatedAt != nil
                    case let .status(code, asked):
                        retryAfter = TokenroomHTTP.retryDate(asked, now: now)
                        permanent = isPermanent(status: code)
                    case .unreachable:
                        if Task.isCancelled { continue }
                    case .offline:
                        offlineSources.append(source)
                        continue
                    }
                    answered = true
                    if success {
                        check.succeededAt = now
                        check.failedAt = nil
                        check.failures = nil
                        check.retryAt = nil
                        check.firstFailedAt = nil
                        check.isPermanent = nil
                        check.truncatedAt = truncated ? (check.truncatedAt ?? now) : nil
                        unreadable.remove(source.id)
                        anySucceeded = true
                    } else {
                        recordFailure(&check, now: now, retryAfter: retryAfter, permanent: permanent)
                        unreadable.insert(source.id)
                        anyFailed = true
                    }
                    checks[source.id] = check
                    cache.sourceChecks = checks
                    cache.unreadable = unreadable.isEmpty ? nil : unreadable
                    if anySucceeded { cache.announcementsFetchedAt = now }
                    guard (cache.items[source.id] ?? []) != listed else { continue }
                    if isShowing {
                        unshown = true
                    } else {
                        isShowing = true
                        let shown = cache
                        group.addTask { await publish(shown); return .shown }
                    }
                }
            }
            if answered {
                for source in offlineSources {
                    var check = cache.check(for: source)
                    recordFailure(&check, now: now, retryAfter: nil, permanent: false)
                    checks[source.id] = check
                    unreadable.insert(source.id)
                    anyFailed = true
                }
                if !offlineSources.isEmpty { cache.sourceChecks = checks }
            }
            if anySucceeded || anyFailed { cache.announcementsFailedAt = anyFailed ? now : nil }
        }
        if answered, modelsOffline {
            cache.modelsFailed(at: now)
            unreadable.insert(ModelFeed.id)
        }
        cache.unreadable = unreadable.isEmpty ? nil : unreadable
        return Result(cache: cache, newModels: newModels)
    }

    static func recordFailure(_ check: inout NewsCache.SourceCheck, now: Date, retryAfter: Date?, permanent: Bool) {
        let running = (check.failures ?? 0) > 0
        check.firstFailedAt = running ? (check.firstFailedAt ?? check.failedAt ?? now) : now
        check.failedAt = now
        check.failures = (check.failures ?? 0) + 1
        check.retryAt = allowedRetry(retryAfter, now: now)
        check.isPermanent = permanent ? true : nil
    }

    static func isDue(_ fetchedAt: Date?, interval: TimeInterval, now: Date) -> Bool {
        fetchedAt.map { $0 > now || now.timeIntervalSince($0) >= interval } ?? true
    }

    static func isDue(_ fetchedAt: Date?, failedAt: Date?, failures: Int? = nil, retryAt: Date? = nil, interval: TimeInterval, now: Date) -> Bool {
        if let failedAt, fetchedAt == nil || failedAt >= fetchedAt! {
            guard interval > 0 else { return true }
            if let retryAt, retryAt > now, retryAt.timeIntervalSince(now) <= longestRetryAfter { return false }
            return isDue(failedAt, interval: retryInterval(afterFailures: failures), now: now)
        }
        return isDue(fetchedAt, interval: interval, now: now)
    }

    static let arrivalSlack: TimeInterval = 2 * 86_400

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

    @MainActor static func permittedGet(_ url: URL, validator: NewsCache.Validator?, sizeLimit: Int = FeedParser.sizeLimit,
                                       isAllowed: @MainActor @Sendable () -> Bool) async -> Answer? {
        guard !Task.isCancelled, isAllowed() else { return nil }
        return await get(url, validator: validator, sizeLimit: sizeLimit)
    }

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
                guard !Task.isCancelled else { return .unreachable }
                if let error = error as? URLError, TokenroomHTTP.meansOffline(error) { return .offline }
                guard !data.isEmpty else { return .unreachable }
                isTruncated = true
            }
            if isTruncated {
                bytes.task.cancel()
            }
            let fresh = NewsCache.Validator(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified")
            )
            return .body(data, fresh, isTruncated: isTruncated)
        } catch let error as URLError where !Task.isCancelled && TokenroomHTTP.meansOffline(error) {
            return .offline
        } catch {
            return .unreachable
        }
    }
}

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
    var shortName: String {
        guard let colon = name.range(of: ": ") else { return name }
        return String(name[colon.upperBound...])
    }

    var vendorName: String {
        name.range(of: ": ").map { String(name[..<$0.lowerBound]) } ?? vendor
    }

    var link: URL? {
        URL(string: "https://openrouter.ai/\(id)")
    }
}

private extension String {
    func firstCapture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
