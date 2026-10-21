import Foundation

// MARK: Model releases

/// A model as OpenRouter lists it: a public, key-free catalog of models from every lab.
struct ModelRelease: Codable, Equatable, Sendable, Identifiable {
    /// OpenRouter's canonical slug, e.g. `anthropic/claude-opus-5.5`.
    var id: String
    var name: String
    /// The lab, from the slug prefix, e.g. `anthropic`.
    var vendor: String
    var created: Date
    var contextLength: Int?
    /// Dollars per million tokens.
    var promptPrice: Double?
    var completionPrice: Double?
    /// When OpenRouter will retire it, if announced.
    var expires: Date?
    /// When this device first saw it in the list, so a model listed after the last visit though
    /// created before it is still new. Nil in caches from earlier releases.
    var firstSeenAt: Date? = nil

    /// What decides whether it's new: when it arrived, else when it was created.
    var newsDate: Date { firstSeenAt ?? created }
}

enum ModelFeed {
    /// The whole list, since retirements are announced for models of any age, not only the
    /// newest. No key and no Anthropic-style headers: an `anthropic-version` header changes the
    /// response shape. About 790 KB in October 2026, read with the usual `FeedParser.sizeLimit`.
    static let url = URL(string: "https://openrouter.ai/api/v1/models")!

    /// How many of the newest models are kept; older ones stay only while they have a retirement date.
    static let newestLimit = 50

    /// The model list's entry in `NewsCache.unreadable`.
    static let id = "openrouter-models"

    /// Labs followed by default: the ones behind Tokenroom's providers.
    static let defaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    /// Names for OpenRouter's lab IDs, for labs not in the latest list.
    static let vendorNames: [String: String] = [
        "anthropic": "Anthropic", "openai": "OpenAI", "x-ai": "xAI", "google": "Google", "z-ai": "Z.ai",
        "moonshotai": "Moonshot AI", "minimax": "MiniMax", "deepseek": "DeepSeek",
    ]

    /// Releases newest first: the newest `newestLimit`, then older ones OpenRouter will retire.
    /// Skips aliases (`~vendor/…`, `…-latest`), routers (`openrouter/…`), and stealth models;
    /// folds variants (`:free`, `:batch`, …) into their base model.
    static func releases(from data: Data) throws -> [ModelRelease] {
        let root = try JSONFlex.object(from: data)
        guard let items = JSONFlex.array(root["data"]) else { throw ProviderError.parse }
        var byID: [String: (release: ModelRelease, isBase: Bool)] = [:]
        var hasValidRecord = items.isEmpty
        for item in items {
            guard let model = JSONFlex.dictionary(item),
                  let rawID = JSONFlex.string(model["id"]),
                  let created = catalogDate(model["created"])
            else { continue }
            let parts = rawID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let id = parts.first, !id.isEmpty else { continue }
            let variant = parts.count > 1 ? parts[1] : nil
            let slug = id.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard slug.count == 2, !slug[0].isEmpty, !slug[1].isEmpty,
                  created.timeIntervalSince1970.isFinite else { continue }
            hasValidRecord = true
            guard !id.hasPrefix("~"), !id.hasSuffix("-latest"),
                  !["openrouter", "stealth"].contains(String(slug[0]))
            else { continue }
            var name = JSONFlex.string(model["name"]) ?? id
            if let variant, name.lowercased().hasSuffix(" (\(variant.lowercased()))") {
                name = String(name.dropLast(variant.count + 3))
            }
            let pricing = JSONFlex.dictionary(model["pricing"])
            let release = ModelRelease(
                id: id,
                name: name,
                vendor: String(slug[0]),
                created: created,
                contextLength: contextLength(model["context_length"]),
                promptPrice: pricePerMillion(pricing?["prompt"]),
                completionPrice: pricePerMillion(pricing?["completion"]),
                expires: catalogDate(model["expiration_date"])
            )
            // The base model's prices win over a variant's.
            if byID[id] == nil || (variant == nil && byID[id]?.isBase == false) {
                byID[id] = (release, variant == nil)
            }
        }
        // A malformed nonempty catalog must not replace a previously usable list with [];
        // an explicitly empty list, or a list of intentionally excluded aliases, remains valid.
        guard hasValidRecord else { throw ProviderError.parse }
        let newestFirst = byID.values.map(\.release).sorted { $0.created > $1.created }
        return Array(newestFirst.prefix(newestLimit)) + newestFirst.dropFirst(newestLimit).filter { $0.expires != nil }
    }

    private static func contextLength(_ raw: Any?) -> Int? {
        guard let value = JSONFlex.number(raw), value.isFinite, value >= 0 else { return nil }
        return Int(exactly: value)
    }

    private static func catalogDate(_ raw: Any?) -> Date? {
        guard let date = JSONFlex.date(raw), date.timeIntervalSince1970.isFinite,
              (0...253_402_300_799).contains(date.timeIntervalSince1970) else { return nil }
        return date
    }

    private static func pricePerMillion(_ raw: Any?) -> Double? {
        guard let value = JSONFlex.number(raw), value.isFinite, value >= 0 else { return nil }
        let scaled = value * 1_000_000
        // Price labels round at three decimal places; keep that multiplication finite too.
        guard scaled.isFinite, scaled <= Double.greatestFiniteMagnitude / 1000 else { return nil }
        return scaled
    }
}

/// What the device has already seen, so only new releases are announced.
struct ModelFeedState: Codable, Equatable, Sendable {
    var newestSeen: Date?
    var seenIDs: [String] = []

    static let memory = 500

    /// New releases from followed labs since the last check, newest first. The first check
    /// only remembers what's there, so installing Tokenroom doesn't announce the whole catalog.
    mutating func takeNew(from releases: [ModelRelease], following vendors: Set<String>) -> [ModelRelease] {
        // An empty answer says nothing about the catalog, so it doesn't count as the first check.
        guard !releases.isEmpty else { return [] }
        let seen = Set(seenIDs)
        defer {
            seenIDs = Array((releases.map(\.id) + seenIDs).uniqued().prefix(Self.memory))
            newestSeen = max(newestSeen ?? .distantPast, releases.map(\.created).max() ?? .distantPast)
        }
        guard let newestSeen else { return [] }
        return releases.filter { release in
            vendors.contains(release.vendor) && !seen.contains(release.id) && release.created > newestSeen.addingTimeInterval(-86_400)
        }
    }
}

// MARK: Announcements

struct FeedItem: Codable, Equatable, Sendable, Identifiable {
    /// The item's guid or id, else its link.
    var id: String
    var title: String
    var link: URL?
    var published: Date?
    /// Which feed it came from, e.g. "Claude Code".
    var source: String
    /// Another feed that had the same entry and was folded into this one, e.g. "Claude Code
    /// releases". Set by `NewsCache.announcements`, never stored.
    var alsoIn: String? = nil

    var sourceID: String? = nil
    var kind: NewsSourceKind? = nil
    var publisherPublishedAt: Date? = nil
    var updatedAt: Date? = nil
    var firstSeenAt: Date? = nil
    var excerpt: String? = nil
    /// Parsed once at the feed boundary. Older caches revalidate their source body
    /// on its next due check; display must not reinterpret literal code as HTML.
    var excerptIsPlainText: Bool? = nil
    var canonicalID: String? = nil
    var aliases: Set<String>? = nil
    struct StatusUpdate: Codable, Equatable, Sendable {
        var date: Date?
        var excerpt: String?
    }
    var observedUpdates: [StatusUpdate]? = nil
    var stableID: String { canonicalID ?? "\(sourceID ?? source)|\(id)" }
    var aliasIDs: Set<String> { (aliases ?? []).union(["\(sourceID ?? source)|\(id)"]) }
    var newsDate: Date? { firstSeenAt ?? published }
    var sortDate: Date { publisherPublishedAt ?? updatedAt ?? published ?? .distantPast }

    /// Release feeds title entries with a bare version; "Codex 0.157.0" reads better in a list.
    /// A commit's trailing pull request number ("Add discernment-nudge skill (#1553)") is left
    /// off; it stays in `title`, so two commits with the same message stay two.
    var displayTitle: String {
        namedTitle.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
    }

    private var namedTitle: String {
        title.range(of: #"^v?\d+(\.\d+)+([-+.][0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil
            ? "\(source) \(title)"
            : title
    }

    /// The same post or release in two of a product's feeds: the same title, or the same version
    /// under the same name ("Claude Code 2.1.282" from the changelog, "Claude Code v2.1.282" from
    /// GitHub). `NewsCache.announcements` compares it within a product only.
    var duplicateKey: String {
        namedTitle.lowercased().replacingOccurrences(of: #"\sv(?=\d)"#, with: " ", options: .regularExpression)
    }
}

/// An official news or changelog feed. Only RSS and Atom, never scraped pages.
struct FeedSource: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: URL
    /// The provider it belongs to, for following.
    var provider: Provider?
    /// Drops pre-release entries (alpha, beta, rc, nightly, preview, …: `FeedParser.isPrerelease`)
    /// from release feeds.
    var skipsPrereleases = false
    /// Keeps only entries whose link contains this, e.g. a blog's announcements.
    var linkContains: String? = nil
    /// Leaves out entries whose title starts with one of these (ignoring case), e.g. a
    /// repository's releases of another product it also ships.
    var skipsTitlePrefixes: [String] = []
    /// The most read from the feed, in bytes: a longer one stops there, and shows what it got.
    var sizeLimit = FeedParser.sizeLimit
    /// The feed it belongs to: a second source for the same product, shown under that feed's
    /// name and turned on and off with it.
    var partOf: String? = nil
    /// A repository's commit log (Claude Skills). Its entries can share a message ("Update pdf
    /// skill"), so they're told apart by link and ID, never folded or dropped by title; GitHub
    /// cuts a long message mid-word, so the cut word goes and the "…" stays; and a day's commits
    /// updating one thing ("Update claude-api skill: …") show as one row, the newest.
    var isCommitLog = false

    var kind: NewsSourceKind = .officialAnnouncement
    /// Legacy tool changelogs suppress repeated titles; people, incidents, and commits never do.
    var suppressesRepeatedTitles: Bool { kind == .officialAnnouncement && !isCommitLog }

    /// The name its items show, and fold duplicates under.
    var itemSource: String {
        partOf.flatMap { id in Self.catalog.first { $0.id == id }?.name } ?? name
    }

    /// Feeds people turn on and off; the ones `partOf` another follow it.
    static var toggles: [FeedSource] {
        catalog.filter { $0.partOf == nil }
    }

    static let catalog: [FeedSource] = [
        FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://code.claude.com/docs/en/changelog/rss.xml")!, provider: .claude),
        // The same versions as the changelog, often sooner; one shows when both have it.
        FeedSource(id: "claude-code-releases", name: "Claude Code releases", url: URL(string: "https://github.com/anthropics/claude-code/releases.atom")!, provider: .claude, skipsPrereleases: true, partOf: "claude-code"),
        // A weekly digest of the changelog, so its own toggle rather than part of it.
        FeedSource(id: "claude-code-whats-new", name: "Claude Code what's new", url: URL(string: "https://code.claude.com/docs/en/whats-new/rss.xml")!, provider: .claude),
        FeedSource(id: "claude-agent-sdk", name: "Claude Agent SDK", url: URL(string: "https://github.com/anthropics/claude-agent-sdk-python/releases.atom")!, provider: .claude, skipsPrereleases: true),
        // The skills repository's commits: each entry is a skill added or updated. Not releases, so
        // nothing is skipped as a pre-release.
        FeedSource(id: "claude-skills", name: "Claude Skills", url: URL(string: "https://github.com/anthropics/skills/commits/main.atom")!, provider: .claude, isCommitLog: true),
        FeedSource(id: "openai-news", name: "OpenAI", url: URL(string: "https://openai.com/news/rss.xml")!, provider: .openai),
        FeedSource(id: "codex-releases", name: "Codex", url: URL(string: "https://github.com/openai/codex/releases.atom")!, provider: .openai, skipsPrereleases: true),
        FeedSource(id: "gemini", name: "Google Gemini", url: URL(string: "https://blog.google/products-and-platforms/products/gemini/rss/")!, provider: .antigravity),
        FeedSource(id: "gemini-cli", name: "Gemini CLI", url: URL(string: "https://github.com/google-gemini/gemini-cli/releases.atom")!, provider: .antigravity, skipsPrereleases: true),
        FeedSource(id: "deepmind", name: "Google DeepMind", url: URL(string: "https://deepmind.google/blog/rss.xml")!, provider: .antigravity),
        FeedSource(id: "copilot", name: "GitHub Copilot", url: URL(string: "https://github.blog/changelog/label/copilot/feed/")!, provider: .copilot),
        FeedSource(id: "copilot-cli", name: "Copilot CLI", url: URL(string: "https://github.com/github/copilot-cli/releases.atom")!, provider: .copilot, skipsPrereleases: true),
        FeedSource(id: "cursor", name: "Cursor", url: URL(string: "https://cursor.com/changelog/rss.xml")!, provider: .cursor),
        FeedSource(id: "devin", name: "Devin", url: URL(string: "https://docs.devin.ai/desktop/changelog/rss.xml")!, provider: .devin),
        FeedSource(id: "zai", name: "Z.ai", url: URL(string: "https://docs.z.ai/release-notes/new-released/rss.xml")!, provider: .zai),
        FeedSource(id: "kimi-code", name: "Kimi Code", url: URL(string: "https://github.com/MoonshotAI/kimi-code/releases.atom")!, provider: .kimiCode, skipsPrereleases: true),
        // sst/opencode redirects here (October 2026). Its `github-v…` releases are its GitHub
        // integration's, and its "PR #…" ones a pull request's test artifacts, not OpenCode's.
        FeedSource(id: "opencode", name: "OpenCode", url: URL(string: "https://github.com/anomalyco/opencode/releases.atom")!, provider: .opencodeGo, skipsPrereleases: true, skipsTitlePrefixes: ["github-v", "PR #"]),
        FeedSource(id: "openrouter", name: "OpenRouter", url: URL(string: "https://openrouter.ai/blog/feed.xml")!, provider: .openrouter, linkContains: "/blog/announcements/"),
        // ChatGPT and Codex product notes: each links to a `#codex-…` anchor, ChatGPT's included.
        // Its `#github-release-…` entries are CLI releases, which `codex-releases` already has.
        // Those embed each release's full notes (up to 360 KB apiece), so the feed's size follows
        // them: 1.2 MB in September 2026, 850 KB of it the last 13 releases. 4 MB, twice the
        // usual limit, leaves room for a run of long ones.
        FeedSource(id: "codex-changelog", name: "ChatGPT & Codex", url: URL(string: "https://learn.chatgpt.com/docs/changelog/rss.xml")!, provider: .openai, linkContains: "#codex-", sizeLimit: 4 * 1024 * 1024),
        FeedSource(id: "antigravity-blog", name: "Antigravity", url: URL(string: "https://antigravity.google/blog/rss.xml")!, provider: .antigravity),
        FeedSource(id: "antigravity-cli", name: "Antigravity CLI", url: URL(string: "https://github.com/google-antigravity/antigravity-cli/releases.atom")!, provider: .antigravity, skipsPrereleases: true),
        FeedSource(id: "minimax-code", name: "MiniMax Code", url: URL(string: "https://github.com/MiniMax-AI/minimax-code/releases.atom")!, provider: .minimax, skipsPrereleases: true),
    ]
}

/// Reads RSS 2.0 and Atom leniently: titles as plain text, the first 30 items.
enum FeedParser {
    static let itemLimit = 30
    /// The most read from a feed that doesn't set its own. In September 2026 the feeds ran from
    /// 5 KB (Devin) to 750 KB (OpenAI News, which keeps every post): 2 MB leaves room to grow, and
    /// bounds what a broken server can make a phone download.
    static let sizeLimit = 2 * 1024 * 1024

    static func items(from data: Data, source: FeedSource) -> [FeedItem] {
        read(data, source: source).items
    }

    /// The feed's items, whether the whole document parsed as a feed, and how many entries it had
    /// before any were left out. One cut short at the size limit, or broken, still gives the items
    /// that ended before the break.
    static func read(_ data: Data, source: FeedSource) -> (items: [FeedItem], isComplete: Bool, entries: Int) {
        let delegate = FeedXMLDelegate(source: source)
        let parser = XMLParser(data: data.prefix(source.sizeLimit))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        // Some feeds repeat a title for every small update ("ChatGPT for iOS"); keep the first.
        var titles = Set<String>()
        var updates = Set<String>()
        let items = delegate.items
            .map { item in source.isCommitLog ? withWholeWords(item) : item }
            .filter { !source.skipsPrereleases || !isPrerelease($0.title) }
            .filter { item in source.linkContains.map { item.link?.absoluteString.contains($0) == true } ?? true }
            .filter { item in !source.skipsTitlePrefixes.contains { item.title.lowercased().hasPrefix($0.lowercased()) } }
            .filter { !source.suppressesRepeatedTitles || titles.insert($0.title.lowercased()).inserted }
            // Newest first, so the day's newest update to each thing stays.
            .filter { item in !source.isCommitLog || dailyUpdateKey(item).map { updates.insert($0).inserted } ?? true }
            .prefix(itemLimit)
        return (Array(items), parsed && delegate.isFeed && data.count <= source.sizeLimit, delegate.items.count)
    }

    /// A message GitHub cut mid-word ("Add guidance for structured outp…") ends at its last whole
    /// word instead ("Add guidance for structured…").
    static func withWholeWords(_ item: FeedItem) -> FeedItem {
        var item = item
        item.title = wholeWords(item.title)
        return item
    }

    static func wholeWords(_ title: String) -> String {
        guard title.hasSuffix("…") else { return title }
        var kept = title.dropLast()
        if let last = kept.last, !last.isWhitespace, let space = kept.lastIndex(where: \.isWhitespace) {
            kept = kept[..<space]
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",;:-–—")))
        return trimmed.isEmpty ? title : trimmed + "…"
    }

    /// "update claude-api 2026-10-21" for a commit updating one thing that day; nil for others.
    static func dailyUpdateKey(_ item: FeedItem) -> String? {
        guard let date = item.updatedAt ?? item.publisherPublishedAt ?? item.published,
              let match = item.title.range(of: #"(?i)^update\s+\S+"#, options: .regularExpression)
        else { return nil }
        let day = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return "\(item.title[match].lowercased()) \(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    /// An entry's link if it's a web page, resolved against the feed. Other schemes
    /// (`javascript:`, `file:`, an app's own) are dropped, so an item only ever opens the browser.
    static func webLink(_ text: String, feed: URL) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text, relativeTo: feed)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    /// Release titles like `@scope/package@2.1.1` read as the version alone.
    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^@[^/\s]+/[^@\s]+@"#, with: "", options: .regularExpression)
    }

    /// "0.158.0-alpha.14", "2.2.0 beta", "v0.67.0-nightly.20261021.gd00859d6b",
    /// "v0.66.0-preview.0", "1.0.0-canary.3", "1.2.0.dev1", and a numbered pre-release such as
    /// "1.0.102-0". The words other than alpha, beta, and rc only count right after a hyphen or a
    /// dot, so a title that mentions them ("What's next") isn't caught.
    static func isPrerelease(_ title: String) -> Bool {
        title.range(of: #"(?i)((-|\s)(alpha|beta|rc)|[-.](nightly|preview|canary|dev|next|snapshot))(\b|\.|\d)|\d+\.\d+\.\d+-\d+(\.\d+)*\b"#, options: .regularExpression) != nil
    }

    /// HTML elements a title may carry. Other text in angle brackets is kept: "<thinking> blocks",
    /// a `</s>` token, `Either<A, B>`.
    private static let htmlTag = #"</?(?:a|abbr|b|big|br|cite|code|del|div|em|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|q|small|span|strong|sub|sup|time|tt|u|ul|wbr)(?:\s[^<>]*)?/?>"#

    /// Strips HTML tags, decodes entities left over from HTML titles, and collapses whitespace.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: htmlTag, with: " ", options: .regularExpression)
        for (entity, character) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = decodeNumericEntities(text).replacingOccurrences(of: "&amp;", with: "&")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Excerpts can carry a complete HTML document; title token syntax stays
    /// governed by the narrower plainText contract above.
    static func plainExcerptText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<!--.*?-->"#, #"(?is)<(head|script|style)\b[^>]*>.*?</\1\s*>"#,
                        #"(?is)<!doctype[^>]*>"#,
                        #"(?i)</?(?:html|body|head|meta|link|section|article|header|footer|nav|aside|main|figure|figcaption|blockquote|table|thead|tbody|tfoot|tr|td|th|dl|dt|dd|video|audio|source|picture|button|form|input|label|script|style)(?:\s[^<>]*)?/?>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return plainText(text)
    }

    /// `&#8217;` and `&#x2019;`.
    static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: #"&#[xX]?[0-9a-fA-F]+;"#, options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let body = rest[range].dropFirst(2).dropLast()
            let value = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body, radix: 10)
            if let value, let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[range]
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    /// RSS dates (RFC 822, with or without seconds, two- or four-digit years) and ISO 8601 ones,
    /// with the variants feeds write: no time zone (read as UTC), a space for the `T`, no seconds.
    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = JSONFlex.parseISO(trimmed) {
            return iso
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    /// `yy` reads "26" as 2026 and "2026" as written; `yyyy` would read "26" as the year 26.
    private static let dateFormats = [
        "EEE, dd MMM yy HH:mm:ss Z", "EEE, dd MMM yy HH:mm:ss zzz", "EEE, dd MMM yy HH:mm Z", "EEE, dd MMM yy HH:mm zzz",
        "dd MMM yy HH:mm:ss Z", "dd MMM yy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss",
    ]
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    let source: FeedSource
    var items: [FeedItem] = []
    private(set) var isFeed = false
    private var path: [String] = []
    /// Depth inside the current item: 0 is the item, 1 its direct children. Nil between items.
    /// Direct children own fields; descendants of text fields may contain Atom XHTML.
    /// Unrelated nested titles (authors, cards) never become the entry title.
    private var depth: Int?
    private var element = ""
    private var title = ""
    private var link: String?
    private var identifier = ""
    private var published = ""
    private var updated = ""
    private var excerpt = ""
    private var excerptCandidate = ""
    private var capturesExcerpt = false
    private var excerptIsXMLText = false
    private var suppressedExcerptDepth: Int?

    init(source: FeedSource) {
        self.source = source
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let localName = String(name.split(separator: ":").last ?? Substring(name))
        path.append(localName)
        if path == ["feed"] || path == ["rss", "channel"] { isFeed = true }
        guard let current = depth else {
            if path == ["rss", "channel", "item"] || path == ["feed", "entry"] {
                depth = 0
                title = ""
                link = nil
                identifier = ""
                published = ""
                updated = ""
                excerpt = ""
                excerptCandidate = ""
                capturesExcerpt = false
                suppressedExcerptDepth = nil
            }
            return
        }
        depth = current + 1
        if current == 0 {
            element = name == "dc:date" || name == "content:encoded" ? name : localName
            capturesExcerpt = ["description", "summary", "content", "content:encoded"].contains(element) && excerpt.isEmpty
            excerptCandidate = ""
            // Atom text and XHTML have already been decoded by XMLParser.
            excerptIsXMLText = path.first == "feed" && ["text", "xhtml"].contains(attributes["type"] ?? "text")
        } else {
            if isExcerpt {
                excerptIsXMLText = true
                if suppressedExcerptDepth == nil, ["head", "script", "style"].contains(localName.lowercased()) { suppressedExcerptDepth = current + 1 }
            }
            appendMarkupBoundary()
        }
        // Atom links live in attributes; prefer rel="alternate".
        if current == 0, localName == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        append(String(decoding: block, as: UTF8.self))
    }

    private func append(_ string: String) {
        guard let depth, depth >= 1 else { return }
        if element == "title" { title += string; return }
        if isExcerpt {
            guard suppressedExcerptDepth == nil else { return }
            excerptCandidate += String(string.prefix(max(0, 2000 - excerptCandidate.count)))
            return
        }
        guard depth == 1 else { return }
        switch element {
        case "link": link = (link ?? "") + string.trimmingCharacters(in: .whitespacesAndNewlines)
        case "guid", "id": identifier += string
        case "pubDate", "published", "dc:date": published += string
        case "updated": updated += string
        default: break
        }
    }

    private var isExcerpt: Bool { capturesExcerpt && ["description", "summary", "content", "content:encoded"].contains(element) }
    private func appendMarkupBoundary() {
        if element == "title", !title.isEmpty, title.last?.isWhitespace == false { title += " " }
        if isExcerpt, suppressedExcerptDepth == nil, !excerptCandidate.isEmpty, excerptCandidate.last?.isWhitespace == false, excerptCandidate.count < 2000 { excerptCandidate += " " }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { path.removeLast() }
        guard let current = depth else { return }
        guard current == 0 else {
            if current == 1 {
                if isExcerpt {
                    let clean = excerptIsXMLText
                        ? excerptCandidate.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        : FeedParser.plainExcerptText(excerptCandidate)
                    if !clean.isEmpty { excerpt = String(clean.prefix(2000)) }
                }
                element = ""
                capturesExcerpt = false
            } else {
                if suppressedExcerptDepth == current { suppressedExcerptDepth = nil }
                appendMarkupBoundary()
            }
            depth = current - 1
            return
        }
        element = ""
        depth = nil
        let cleanTitle = FeedParser.cleanTitle(FeedParser.plainText(title))
        guard !cleanTitle.isEmpty else { return }
        let url = link.flatMap { FeedParser.webLink($0, feed: source.url) }
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(FeedItem(
            id: id.isEmpty ? (url?.absoluteString ?? cleanTitle) : id,
            title: cleanTitle,
            link: url,
            published: FeedParser.date(published),
            source: source.itemSource,
            sourceID: source.id, kind: source.kind,
            publisherPublishedAt: FeedParser.date(published),
            updatedAt: FeedParser.date(updated),
            excerpt: excerpt.isEmpty ? nil : excerpt,
            excerptIsPlainText: true
        ))
    }
}

extension Sequence where Element: Hashable {
    /// Keeps the first occurrence of each element, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
