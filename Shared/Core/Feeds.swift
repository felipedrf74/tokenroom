import Foundation

struct ModelRelease: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var vendor: String
    var created: Date
    var contextLength: Int?
    var promptPrice: Double?
    var completionPrice: Double?
    var expires: Date?
    var firstSeenAt: Date? = nil

    var newsDate: Date { firstSeenAt ?? created }
}

enum ModelFeed {
    static let url = URL(string: "https://openrouter.ai/api/v1/models")!

    static let newestLimit = 50

    static let id = "openrouter-models"

    static let defaultVendors: Set<String> = ["anthropic", "openai", "x-ai", "google", "z-ai", "moonshotai", "minimax", "deepseek"]

    static let vendorNames: [String: String] = [
        "anthropic": "Anthropic", "openai": "OpenAI", "x-ai": "xAI", "google": "Google", "z-ai": "Z.ai",
        "moonshotai": "Moonshot AI", "minimax": "MiniMax", "deepseek": "DeepSeek",
    ]

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
            if byID[id] == nil || (variant == nil && byID[id]?.isBase == false) {
                byID[id] = (release, variant == nil)
            }
        }
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
        guard scaled.isFinite, scaled <= Double.greatestFiniteMagnitude / 1000 else { return nil }
        return scaled
    }
}

struct ModelFeedState: Codable, Equatable, Sendable {
    var newestSeen: Date?
    var seenIDs: [String] = []

    static let memory = 500

    mutating func takeNew(from releases: [ModelRelease], following vendors: Set<String>) -> [ModelRelease] {
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

struct FeedItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var link: URL?
    var published: Date?
    var source: String
    var alsoIn: String? = nil

    var sourceID: String? = nil
    var kind: NewsSourceKind? = nil
    var publisherPublishedAt: Date? = nil
    var updatedAt: Date? = nil
    var firstSeenAt: Date? = nil
    var excerpt: String? = nil
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

    var displayTitle: String {
        namedTitle.replacingOccurrences(of: #"\s*\(#\d+\)$"#, with: "", options: .regularExpression)
    }

    private var namedTitle: String {
        title.range(of: #"^v?\d+(\.\d+)+([-+.][0-9A-Za-z.]+)?$"#, options: .regularExpression) != nil
            ? "\(source) \(title)"
            : title
    }

    var duplicateKey: String {
        namedTitle.lowercased().replacingOccurrences(of: #"\sv(?=\d)"#, with: " ", options: .regularExpression)
    }
}

struct FeedSource: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: URL
    var provider: Provider?
    var skipsPrereleases = false
    var linkContains: String? = nil
    var skipsTitlePrefixes: [String] = []
    var sizeLimit = FeedParser.sizeLimit
    var partOf: String? = nil
    var isCommitLog = false
    var titleFoldGroup: String? = nil

    var startsOnForUpgraders = true

    var kind: NewsSourceKind = .officialAnnouncement
    var suppressesRepeatedTitles: Bool { kind == .officialAnnouncement && !isCommitLog }
    var datesEntriesByUpdate: Bool { url.path.hasSuffix("/releases.atom") || isCommitLog }

    var itemSource: String {
        partOf.flatMap { id in Self.catalog.first { $0.id == id }?.name } ?? name
    }

    static var toggles: [FeedSource] {
        catalog.filter { $0.partOf == nil }
    }

    static let catalog: [FeedSource] = [
        FeedSource(id: "claude-code", name: "Claude Code", url: URL(string: "https://code.claude.com/docs/en/changelog/rss.xml")!, provider: .claude),
        FeedSource(id: "claude-code-releases", name: "Claude Code releases", url: URL(string: "https://github.com/anthropics/claude-code/releases.atom")!, provider: .claude, skipsPrereleases: true, partOf: "claude-code"),
        FeedSource(id: "claude-code-whats-new", name: "Claude Code what's new", url: URL(string: "https://code.claude.com/docs/en/whats-new/rss.xml")!, provider: .claude),
        FeedSource(id: "claude-agent-sdk", name: "Claude Agent SDK", url: URL(string: "https://github.com/anthropics/claude-agent-sdk-python/releases.atom")!, provider: .claude, skipsPrereleases: true),
        FeedSource(id: "claude-skills", name: "Claude Skills", url: URL(string: "https://github.com/anthropics/skills/commits/main.atom")!, provider: .claude, isCommitLog: true),
        FeedSource(id: "openai-news", name: "OpenAI", url: URL(string: "https://openai.com/news/rss.xml")!, provider: .openai),
        FeedSource(id: "codex-releases", name: "Codex", url: URL(string: "https://github.com/openai/codex/releases.atom")!, provider: .openai, skipsPrereleases: true),
        FeedSource(id: "gemini", name: "Google Gemini", url: URL(string: "https://blog.google/products-and-platforms/products/gemini/rss/")!, provider: .antigravity, titleFoldGroup: "google"),
        FeedSource(id: "gemini-cli", name: "Gemini CLI", url: URL(string: "https://github.com/google-gemini/gemini-cli/releases.atom")!, provider: .antigravity, skipsPrereleases: true),
        FeedSource(id: "deepmind", name: "Google DeepMind", url: URL(string: "https://deepmind.google/blog/rss.xml")!, provider: .antigravity, titleFoldGroup: "google"),
        FeedSource(id: "copilot", name: "GitHub Copilot", url: URL(string: "https://github.blog/changelog/label/copilot/feed/")!, provider: .copilot),
        FeedSource(id: "copilot-cli", name: "Copilot CLI", url: URL(string: "https://github.com/github/copilot-cli/releases.atom")!, provider: .copilot, skipsPrereleases: true),
        FeedSource(id: "cursor", name: "Cursor", url: URL(string: "https://cursor.com/changelog/rss.xml")!, provider: .cursor),
        FeedSource(id: "devin", name: "Devin", url: URL(string: "https://docs.devin.ai/desktop/changelog/rss.xml")!, provider: .devin),
        FeedSource(id: "zai", name: "Z.ai", url: URL(string: "https://docs.z.ai/release-notes/new-released/rss.xml")!, provider: .zai),
        FeedSource(id: "kimi-code", name: "Kimi Code", url: URL(string: "https://github.com/MoonshotAI/kimi-code/releases.atom")!, provider: .kimiCode, skipsPrereleases: true),
        FeedSource(id: "opencode", name: "OpenCode", url: URL(string: "https://github.com/anomalyco/opencode/releases.atom")!, provider: .opencodeGo, skipsPrereleases: true, skipsTitlePrefixes: ["github-v", "PR #"]),
        FeedSource(id: "openrouter", name: "OpenRouter", url: URL(string: "https://openrouter.ai/blog/feed.xml")!, provider: .openrouter, linkContains: "/blog/announcements/"),
        FeedSource(id: "codex-changelog", name: "ChatGPT & Codex", url: URL(string: "https://learn.chatgpt.com/docs/changelog/rss.xml")!, provider: .openai, linkContains: "#codex-", sizeLimit: 8 * 1024 * 1024),
        FeedSource(id: "antigravity-blog", name: "Antigravity", url: URL(string: "https://antigravity.google/blog/rss.xml")!, provider: .antigravity),
        FeedSource(id: "antigravity-cli", name: "Antigravity CLI", url: URL(string: "https://github.com/google-antigravity/antigravity-cli/releases.atom")!, provider: .antigravity, skipsPrereleases: true),
        FeedSource(id: "minimax-code", name: "MiniMax Code", url: URL(string: "https://github.com/MiniMax-AI/minimax-code/releases.atom")!, provider: .minimax, skipsPrereleases: true),
        FeedSource(id: "mistral-news", name: "Mistral AI", url: URL(string: "https://mistral.ai/rss.xml")!, provider: nil, startsOnForUpgraders: false),
    ]
}

enum FeedParser {
    static let itemLimit = 30
    static let sizeLimit = 2 * 1024 * 1024

    static func items(from data: Data, source: FeedSource) -> [FeedItem] {
        read(data, source: source).items
    }

    static func read(_ data: Data, source: FeedSource) -> (items: [FeedItem], isComplete: Bool, entries: Int, isFeed: Bool) {
        let delegate = FeedXMLDelegate(source: source)
        let parser = XMLParser(data: data.prefix(source.sizeLimit))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        var titles = Set<String>()
        var updates = Set<String>()
        let items = delegate.items
            .map { item in source.isCommitLog ? withWholeWords(item) : item }
            .filter { !source.skipsPrereleases || !isPrerelease($0.title) }
            .filter { item in source.linkContains.map { item.link?.absoluteString.contains($0) == true } ?? true }
            .filter { item in !source.skipsTitlePrefixes.contains { item.title.lowercased().hasPrefix($0.lowercased()) } }
            .filter { !source.suppressesRepeatedTitles || titles.insert($0.title.lowercased()).inserted }
            .filter { item in !source.isCommitLog || dailyUpdateKey(item).map { updates.insert($0).inserted } ?? true }
            .prefix(itemLimit)
        return (Array(items), parsed && delegate.isFeed && data.count <= source.sizeLimit, delegate.items.count, delegate.isFeed)
    }

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

    static func dailyUpdateKey(_ item: FeedItem) -> String? {
        guard let date = item.updatedAt ?? item.publisherPublishedAt ?? item.published,
              let update = item.title.range(of: #"(?i)^update\s+"#, options: .regularExpression)
        else { return nil }
        var thing = item.title[update.upperBound...]
        if let end = thing.range(of: #":|\s[-–—]\s"#, options: .regularExpression) { thing = thing[..<end.lowerBound] }
        let words = thing
            .replacingOccurrences(of: #"\(#\d+\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^\s*the\s+"#, with: "", options: .regularExpression)
            .lowercased()
            .split { $0.isWhitespace || $0 == "…" }
        guard !words.isEmpty else { return nil }
        let day = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return "update \(words.joined(separator: " ")) \(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    static func webLink(_ text: String, feed: URL) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: text, relativeTo: feed)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    static func cleanTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^@[^/\s]+/[^@\s]+@"#, with: "", options: .regularExpression)
    }

    static func isPrerelease(_ title: String) -> Bool {
        title.range(of: #"(?i)((-|\s)(alpha|beta|rc)|[-.](nightly|preview|canary|dev|next|snapshot))(\b|\.|\d)|\d+\.\d+\.\d+-\d+(\.\d+)*\b"#, options: .regularExpression) != nil
    }

    private static let htmlTag = #"</?(?:a|abbr|b|big|br|cite|code|del|div|em|font|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|q|small|span|strong|sub|sup|time|tt|u|ul|wbr)(?:\s[^<>]*)?/?>"#

    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: htmlTag, with: " ", options: .regularExpression)
        if text.contains("&") {
            for (entity, character) in namedEntities {
                text = text.replacingOccurrences(of: entity, with: character)
            }
            text = decodeNumericEntities(text).replacingOccurrences(of: "&amp;", with: "&")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let namedEntities = [
        "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
        "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&laquo;": "\u{00AB}", "&raquo;": "\u{00BB}", "&middot;": "\u{00B7}", "&bull;": "\u{2022}",
        "&copy;": "\u{00A9}", "&reg;": "\u{00AE}", "&trade;": "\u{2122}",
    ]

    static func plainExcerptText(_ html: String) -> String {
        var text = html
        for pattern in [#"(?is)<!--.*?-->"#, #"(?is)<(head|script|style)\b[^>]*>.*?</\1\s*>"#,
                        #"(?is)<!doctype[^>]*>"#,
                        #"(?i)</?(?:html|body|head|meta|link|section|article|header|footer|nav|aside|main|figure|figcaption|blockquote|table|thead|tbody|tfoot|tr|td|th|dl|dt|dd|video|audio|source|picture|button|form|input|label|script|style)(?:\s[^<>]*)?/?>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return plainText(text)
    }

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

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let iso = JSONFlex.parseISO(trimmed) {
            return iso
        }
        return dateFormatters.date(from: trimmed)
    }

    private static let dateFormatters = FeedDateFormatters()
}

private final class FeedDateFormatters: @unchecked Sendable {
    private let lock = NSLock()
    private let formatters: [DateFormatter]

    private static let formats = [
        "EEE, dd MMM yy HH:mm:ss Z", "EEE, dd MMM yy HH:mm:ss zzz", "EEE, dd MMM yy HH:mm Z", "EEE, dd MMM yy HH:mm zzz",
        "dd MMM yy HH:mm:ss Z", "dd MMM yy HH:mm Z",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mmXXXXX", "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss",
    ]

    init() {
        formatters = Self.formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }

    func date(from text: String) -> Date? {
        lock.withLock {
            for formatter in formatters {
                if let date = formatter.date(from: text) {
                    return date
                }
            }
            return nil
        }
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    let source: FeedSource
    var items: [FeedItem] = []
    private(set) var isFeed = false
    private var path: [String] = []
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
            excerptIsXMLText = path.first == "feed" && ["text", "xhtml"].contains(attributes["type"] ?? "text")
        } else {
            if isExcerpt {
                excerptIsXMLText = true
                if suppressedExcerptDepth == nil, ["head", "script", "style"].contains(localName.lowercased()) { suppressedExcerptDepth = current + 1 }
            }
            appendMarkupBoundary()
        }
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
        let publishedAt = FeedParser.date(published)
        let updatedAt = FeedParser.date(updated)
        let datedByUpdate = publishedAt == nil && updatedAt != nil && source.datesEntriesByUpdate
        let releasedAt = datedByUpdate ? updatedAt : publishedAt
        items.append(FeedItem(
            id: id.isEmpty ? (url?.absoluteString ?? cleanTitle) : id,
            title: cleanTitle,
            link: url,
            published: releasedAt,
            source: source.itemSource,
            sourceID: source.id, kind: source.kind,
            publisherPublishedAt: releasedAt,
            updatedAt: datedByUpdate ? nil : updatedAt,
            excerpt: excerpt.isEmpty ? nil : excerpt,
            excerptIsPlainText: true
        ))
    }
}

extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
