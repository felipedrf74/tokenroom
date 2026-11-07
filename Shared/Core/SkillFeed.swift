import Foundation
import CoreFoundation

enum SkillSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case trending, downloads, newest
    var id: String { rawValue }
    var apiValue: String { self == .newest ? "createdAt" : rawValue }
    var label: String {
        switch self { case .trending: "Trending"; case .downloads: "Most downloaded"; case .newest: "Newest" }
    }
    var explanation: String {
        switch self {
        case .trending: "ClawHub's trending ranking of its own uploads, from recent activity. Installs shown below are lifetime totals."
        case .downloads: "ClawHub's lifetime download ranking. Downloads do not establish compatibility."
        case .newest: "Recently published skills in ClawHub's catalog."
        }
    }
}

struct SkillListing: Codable, Equatable, Sendable, Identifiable {
    var owner: String
    var slug: String
    var name: String
    var summary: String?
    var version: String?
    var updatedAt: Date?
    var downloads: Int?
    var stars: Int?
    var requirements: [String]
    /// One-based position in the provider's response, before invalid/duplicate records are dropped.
    var sourceRank: Int? = nil
    /// Lifetime installs, which the trending ranking gives instead of downloads. Optional for
    /// saved lists from earlier releases.
    var installs: Int? = nil
    var id: String { owner + "/" + slug }
    var canonicalURL: URL { URL(string: "https://clawhub.ai/\(owner)/skills/\(slug)")! }
    var rankText: String { sourceRank.map { "Rank \($0)" } ?? "Rank not supplied" }
}
struct SkillPage: Sendable { var listings: [SkillListing]; var cursor: String? }
enum SkillFeed {
    static let sizeLimit = 2 * 1024 * 1024
    /// Shown under every ranking: ClawHub lists what anyone uploads.
    static let communityNote = "Community uploads. ClawHub doesn't review them, so read a skill before you install it."

    /// `sort=trending` on `/api/v1/skills` is deprecated (its `Link` header names the successor,
    /// November 2026); the other rankings stay there.
    static func request(sort: SkillSort) -> URLRequest {
        var components: URLComponents
        if sort == .trending {
            components = URLComponents(string: "https://clawhub.ai/api/v1/trending")!
            components.queryItems = [.init(name: "kind", value: "skills"), .init(name: "limit", value: "30"), .init(name: "nonSuspiciousOnly", value: "true")]
        } else {
            components = URLComponents(string: "https://clawhub.ai/api/v1/skills")!
            components.queryItems = [.init(name: "sort", value: sort.apiValue), .init(name: "limit", value: "30"), .init(name: "nonSuspiciousOnly", value: "true")]
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = TokenroomHTTP.timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Reads either shape: `/api/v1/skills`'s (`ownerHandle`, `stats`) or the trending
    /// endpoint's (`publisher.handle`, `rank`, `metrics`, `trust`). The trending list also carries
    /// skills.sh entries, which aren't ClawHub's and have no ClawHub page or verdict: those are
    /// left out, as is anything ClawHub's scan didn't call clean.
    static func parse(_ data: Data) throws -> SkillPage {
        guard data.count <= sizeLimit, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["items"] as? [[String: Any]] else { throw ProviderError.parse }
        var ids = Set<String>()
        let listings = items.prefix(30).enumerated().compactMap { position, item -> SkillListing? in
            if item["ownerHandle"] == nil, item["publisher"] != nil || item["sourceIdentity"] != nil || item["rank"] != nil {
                return trending(item, position: position, ids: &ids)
            }
            guard let owner = segment(item["ownerHandle"]), let slug = segment(item["slug"]),
                  let name = item["displayName"] as? String, !name.isEmpty, ids.insert(owner + "/" + slug).inserted else { return nil }
            let stats = item["stats"] as? [String: Any]
            let version = item["latestVersion"] as? [String: Any]
            let metadata = item["metadata"] as? [String: Any]
            let openclaw = metadata?["openclaw"] as? [String: Any]
            let requires = (metadata?["requires"] ?? openclaw?["requires"]) as? [String: Any]
            let runtime = ["bins", "anyBins", "env", "config"].flatMap { key in
                (requires?[key] as? [String] ?? []).map { "\(key): \($0)" }
            }
            let platforms = ["os", "systems"].flatMap { key in
                (metadata?[key] as? [String] ?? []).map { "\(key): \($0)" }
            }
            return SkillListing(owner: owner, slug: slug, name: String(name.prefix(500)), summary: (item["summary"] as? String).map { String($0.prefix(2000)) }, version: version?["version"] as? String,
                                updatedAt: date(item["updatedAt"]), downloads: count(stats?["downloads"]), stars: count(stats?["stars"]), requirements: Array((runtime + platforms).prefix(100)), sourceRank: position + 1)
        }
        // An explicit empty catalog is valid. A nonempty page with no usable record is
        // a schema failure, so it must not replace a previously usable ranking.
        guard items.isEmpty || !listings.isEmpty else { throw ProviderError.parse }
        return SkillPage(listings: listings, cursor: root["nextCursor"] as? String)
    }

    /// One entry of the trending endpoint, ranked as ClawHub ranked it (`rank`, else its position).
    private static func trending(_ item: [String: Any], position: Int, ids: inout Set<String>) -> SkillListing? {
        // Only what says it's ClawHub's and that ClawHub's scan called clean: an entry missing
        // either is left out, not given the benefit of the doubt.
        guard item["source"] as? String == "clawhub",
              (item["trust"] as? [String: Any])?["clawHubVerdict"] as? String == "clean" else { return nil }
        let publisher = item["publisher"] as? [String: Any]
        let identity = item["sourceIdentity"] as? [String: Any]
        guard let owner = segment(publisher?["handle"]) ?? segment(identity?["owner"]), let slug = segment(item["slug"]),
              let name = item["displayName"] as? String, !name.isEmpty, ids.insert(owner + "/" + slug).inserted else { return nil }
        let metrics = item["metrics"] as? [String: Any]
        let rank = count(item["rank"]).flatMap { $0 > 0 ? $0 : nil } ?? position + 1
        return SkillListing(owner: owner, slug: slug, name: String(name.prefix(500)), summary: (item["summary"] as? String).map { String($0.prefix(2000)) },
                            version: nil, updatedAt: date(metrics?["updatedAt"]), downloads: nil, stars: nil, requirements: [],
                            sourceRank: rank, installs: count(metrics?["lifetimeInstalls"]))
    }
    private static func segment(_ raw: Any?) -> String? {
        guard let text = raw as? String, text.count <= 100,
              text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        return text
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func count(_ raw: Any?) -> Int? {
        guard let n = number(raw), n >= 0, n < Double(Int.max), n.rounded(.towardZero) == n else { return nil }
        return Int(n)
    }
    private static func date(_ raw: Any?) -> Date? {
        guard let n = number(raw), n >= 0, n <= 253_402_300_799_000 else { return nil }
        return Date(timeIntervalSince1970: n / 1000)
    }
}
