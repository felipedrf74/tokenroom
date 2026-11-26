import Foundation

struct BenchRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}

enum BenchFixture {
    static let now = Date(timeIntervalSince1970: 1_795_176_000)
    static let words = [
        "agents", "context", "window", "pricing", "preview", "terminal", "editor", "models", "reasoning", "latency",
        "tools", "sandbox", "memory", "review", "tokens", "streaming", "workspace", "plugins", "billing", "limits",
        "research", "benchmark", "release", "notes", "background", "tasks", "voice", "search", "safety", "update",
    ]

    static var allSources: [FeedSource] {
        FeedSource.catalog + NewsVoice.catalog.compactMap(\.feed) + NewsStatusSource.catalog
    }

    static func cache(perSource: Int, seed: UInt64) -> NewsCache {
        var cache = NewsCache()
        for (index, source) in allSources.enumerated() {
            var random = BenchRandom(state: seed &+ UInt64(index) &* 7919)
            cache.items[source.id] = items(for: source, count: perSource, random: &random)
        }
        return cache
    }

    static func phrase(_ count: Int, random: inout BenchRandom) -> String {
        (0..<count).map { _ in words[random.below(words.count)] }.joined(separator: " ")
    }

    static func items(for source: FeedSource, count: Int, random: inout BenchRandom) -> [FeedItem] {
        let product = source.partOf ?? source.id
        let isPaired = source.partOf != nil || FeedSource.catalog.contains { $0.partOf == source.id }
        let isReleaseFeed = source.url.path.hasSuffix("/releases.atom")
        let series = product.utf8.reduce(0) { ($0 + Int($1)) % 7 }
        let spacing = TimeInterval(6 * 3600 + random.below(54 * 3600))
        var shared = BenchRandom(state: UInt64(series) &* 104_729 &+ 17)
        return (0..<count).map { index in
            var date = now.addingTimeInterval(-Double(index) * spacing - Double(random.below(3600)))
            var title: String
            var link = URL(string: "https://feeds.example.invalid/\(source.id)/entry-\(index)")!
            var updates: [FeedItem.StatusUpdate]? = nil
            if isReleaseFeed || isPaired {
                let offset = source.partOf == nil ? index + 3 : index
                let version = "\(series + 1).\(series % 3).\(400 - offset)"
                title = source.partOf == nil && !isReleaseFeed ? version : (index % 3 == 0 ? "\(source.name) v\(version)" : "v\(version)")
                if isReleaseFeed { link = URL(string: "https://github.com/example/\(product)/releases/tag/v\(version)")! }
                if isPaired { date = now.addingTimeInterval(-Double(offset) * 8 * 3600 - (source.partOf == nil ? 0 : 1200)) }
            } else if source.isCommitLog {
                title = "Update the \(words[random.below(words.count)]) skill (#\(1000 + random.below(900)))"
            } else if source.titleFoldGroup != nil, index < 6 {
                title = "Shared " + phrase(6, random: &shared).capitalized
                date = now.addingTimeInterval(-Double(index) * 2 * 86_400 - 7200)
            } else if source.kind == .officialStatus {
                title = "Elevated error rates on \(words[random.below(words.count)]) API"
                updates = (0..<(1 + random.below(3))).map { step in
                    .init(date: date.addingTimeInterval(Double(step) * 900), excerpt: phrase(12, random: &random))
                }
            } else {
                title = phrase(5 + random.below(6), random: &random).capitalized
            }
            return FeedItem(
                id: "\(source.id)-entry-\(index)", title: title, link: link, published: date, source: source.name,
                publisherPublishedAt: source.datesEntriesByUpdate ? nil : date,
                updatedAt: index % 3 == 0 ? date.addingTimeInterval(Double(random.below(7200))) : (source.datesEntriesByUpdate ? date : nil),
                firstSeenAt: date.addingTimeInterval(600), excerpt: phrase(40, random: &random), excerptIsPlainText: true,
                observedUpdates: updates
            )
        }
    }
}

struct BenchSections: Equatable {
    var releases: [FeedItem]
    var voices: [FeedItem]
    var status: [FeedItem]

    var ids: [String] {
        ["releases"] + releases.map(\.stableID) + ["voices"] + voices.map(\.stableID) + ["status"] + status.map(\.stableID)
    }

    var checksum: Int {
        releases.count &* 1_000_003 &+ voices.count &* 1009 &+ status.count
    }

    var fingerprint: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in ids.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

enum BenchBaseline {
    static func stories(_ items: [FeedItem], collection: NewsCollection? = nil, query: String = "") -> [FeedItem] {
        items.filter { item in
            let kind = item.kind ?? .officialAnnouncement
            let matches: Bool
            switch collection {
            case .release: matches = kind == .officialAnnouncement
            case .voice: matches = kind == .commentary
            case .status: matches = kind == .officialStatus
            case .model, .retirement: matches = false
            case nil: matches = true
            }
            return matches && NewsSearch.matches(query, title: item.displayTitle, source: item.source)
        }
    }
}

@MainActor
enum BenchVariant: String, CaseIterable {
    case base, reuse, shipped

    var summary: String {
        switch self {
        case .base: "before: news.allAnnouncements three times, each filtered by the earlier stories(_:collection:), which builds displayTitle for every item"
        case .reuse: "news.allAnnouncements once, the earlier stories(_:collection:) three times"
        case .shipped: "this checkout: NewsDiscovery.today(news.allAnnouncements), as both Today views call it"
        }
    }

    func sections(_ news: NewsStore) -> BenchSections {
        switch self {
        case .base:
            let stories = BenchBaseline.stories(news.allAnnouncements, collection: .release)
            let voices = BenchBaseline.stories(news.allAnnouncements, collection: .voice)
            let status = BenchBaseline.stories(news.allAnnouncements, collection: .status)
            return BenchSections(releases: stories, voices: voices, status: status)
        case .reuse:
            let all = news.allAnnouncements
            return BenchSections(releases: BenchBaseline.stories(all, collection: .release),
                                 voices: BenchBaseline.stories(all, collection: .voice),
                                 status: BenchBaseline.stories(all, collection: .status))
        case .shipped:
            let today = NewsDiscovery.today(news.allAnnouncements)
            return BenchSections(releases: today.releases, voices: today.voices, status: today.status)
        }
    }
}

struct BenchStats {
    var median: Double
    var p95: Double
    var minimum: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        p95 = sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        minimum = sorted[0]
    }
}

@MainActor
struct NewsTodayBench {
    struct Profile {
        var name: String
        var followsEverything: Bool
        var perSource: Int
    }

    static let profiles = [
        Profile(name: "new install, 30 per source", followsEverything: false, perSource: 30),
        Profile(name: "everything followed, 30 per source", followsEverything: true, perSource: 30),
        Profile(name: "everything followed, 12 per source", followsEverything: true, perSource: 12),
    ]

    static func store(_ profile: Profile, defaults: UserDefaults) -> NewsStore {
        if profile.followsEverything {
            let official = FeedSource.catalog.map(\.id)
            defaults.set(official, forKey: NewsStore.Keys.sources)
            defaults.set(official, forKey: NewsStore.Keys.knownSources)
            defaults.set(NewsVoice.catalog.compactMap(\.feed).map(\.id), forKey: NewsStore.Keys.voices)
            defaults.set(NewsStatusSource.catalog.map(\.id), forKey: NewsStore.Keys.status)
        }
        return NewsStore(
            defaults: defaults, directory: nil, now: BenchFixture.now,
            initialCache: BenchFixture.cache(perSource: profile.perSource, seed: 0x7061_7065_7221),
            newInstallVoices: NewsVoice.newInstallFollows,
            fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in }
        )
    }

    static func milliseconds(_ variant: BenchVariant, _ news: NewsStore, expecting checksum: Int) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let sections = variant.sections(news)
        let end = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        precondition(sections.checksum == checksum, "\(variant.rawValue) changed its answer between runs")
        return Double(end - start) / 1_000_000
    }

    static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    static func csvField(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func compare(_ first: BenchVariant, _ second: BenchVariant, news: NewsStore, pairs: Int, checksum: Int, raw: inout [String], profile: String) {
        var samples: [BenchVariant: [Double]] = [first: [], second: []]
        var differences: [Double] = []
        var wins = 0
        for pair in 0..<pairs {
            let order = pair % 2 == 0 ? [first, second] : [second, first]
            var taken: [BenchVariant: Double] = [:]
            for variant in order {
                taken[variant] = milliseconds(variant, news, expecting: checksum)
            }
            let a = taken[first]!, b = taken[second]!
            samples[first]!.append(a)
            samples[second]!.append(b)
            differences.append(a - b)
            if b < a { wins += 1 }
            raw.append([profile, first.rawValue, second.rawValue, "\(pair)", order[0].rawValue, "\(a)", "\(b)"].map(csvField).joined(separator: ","))
        }
        let a = BenchStats(samples[first]!), b = BenchStats(samples[second]!), delta = BenchStats(differences)
        print("| \(first.rawValue) vs \(second.rawValue) | \(first.rawValue) | \(format(a.median)) | \(format(a.p95)) | \(format(a.minimum)) |")
        print("| | \(second.rawValue) | \(format(b.median)) | \(format(b.p95)) | \(format(b.minimum)) |")
        print("| | \(first.rawValue) − \(second.rawValue), per pair | \(format(delta.median)) | \(format(delta.p95)) | \(format(delta.minimum)) |")
        print("| | ratio of medians \(String(format: "%.2f", a.median / b.median))×; \(second.rawValue) faster in \(wins) of \(pairs) pairs | | | |")
    }

    static func run() {
        let environment = ProcessInfo.processInfo.environment
        let pairs = max(20, Int(environment["BENCH_PAIRS"] ?? "") ?? 300)
        let warmup = max(1, Int(environment["BENCH_WARMUP"] ?? "") ?? 30)
        var raw = ["profile,first,second,pair,ran_first,first_ms,second_ms"]
        print("Tokenroom News Today: announcements for the three story sections")
        print("commit: \(environment["BENCH_COMMIT"] ?? "unknown")")
        print("build: \(environment["BENCH_BUILD"] ?? "unknown")")
        print("host: \(environment["BENCH_HOST"] ?? "unknown"), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("pairs: \(pairs) per comparison, order alternating each pair; warm-up \(warmup) runs per variant, discarded")
        print("timed: one evaluation, on the main actor, of what a Today body evaluation computes for Latest releases, voices and status")
        print("not timed: SwiftUI layout and drawing, models, editions, freshness, any network or disk; fixtures are synthetic; this is a Mac, not an iPhone")
        for variant in BenchVariant.allCases {
            print("variant \(variant.rawValue): \(variant.summary)")
        }
        for profile in profiles {
            let suite = "tokenroom.bench.news-today." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { fatalError("No defaults suite") }
            defer { defaults.removePersistentDomain(forName: suite) }
            let news = store(profile, defaults: defaults)
            let sources = news.sources
            let rawItems = sources.reduce(0) { $0 + (news.cache.items[$1.id]?.count ?? 0) }
            let expected = BenchVariant.base.sections(news)
            for variant in BenchVariant.allCases {
                let sections = variant.sections(news)
                guard sections == expected, sections.ids == expected.ids else {
                    print("MISMATCH: \(variant.rawValue) differs from base in \(profile.name)")
                    exit(1)
                }
            }
            print("")
            print("## \(profile.name)")
            print("sources \(sources.count), items \(rawItems), most in one source \(sources.map { news.cache.items[$0.id]?.count ?? 0 }.max() ?? 0), announcements after folding \(news.allAnnouncements.count)")
            print("sections: releases \(expected.releases.count), voices \(expected.voices.count), status \(expected.status.count); stable IDs in order, FNV-1a \(expected.fingerprint)")
            print("equality: base, reuse and shipped give equal sections (every FeedItem field) and equal stable IDs in the same order, before and after timing")
            for variant in BenchVariant.allCases {
                for _ in 0..<warmup { _ = milliseconds(variant, news, expecting: expected.checksum) }
            }
            print("| comparison | series | median ms | p95 ms | min ms |")
            print("|---|---|---|---|---|")
            compare(.base, .shipped, news: news, pairs: pairs, checksum: expected.checksum, raw: &raw, profile: profile.name)
            compare(.base, .reuse, news: news, pairs: pairs, checksum: expected.checksum, raw: &raw, profile: profile.name)
            compare(.reuse, .shipped, news: news, pairs: pairs, checksum: expected.checksum, raw: &raw, profile: profile.name)
            for variant in BenchVariant.allCases {
                guard variant.sections(news) == expected else {
                    print("MISMATCH after timing: \(variant.rawValue) in \(profile.name)")
                    exit(1)
                }
            }
        }
        if let path = environment["BENCH_RAW"], !path.isEmpty {
            do {
                try raw.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                print("\nraw samples: \(path)")
            } catch {
                print("\nraw samples not written: \(error.localizedDescription)")
            }
        }
    }
}

@main
struct NewsTodayBenchMain {
    @MainActor
    static func main() {
        NewsTodayBench.run()
    }
}
