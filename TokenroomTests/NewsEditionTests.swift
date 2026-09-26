import XCTest
@testable import Tokenroom

/// The News edition the iPhone's Today view and the Mac's News window show.
final class NewsEditionTests: XCTestCase {
    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!

    private func model(_ id: String, vendor: String = "anthropic", daysAgo: Double, expiresInDays: Double? = nil) -> ModelRelease {
        ModelRelease(
            id: "\(vendor)/\(id)", name: "Lab: \(id)", vendor: vendor, created: now.addingTimeInterval(-daysAgo * 86_400),
            contextLength: 1_000_000, promptPrice: 5, completionPrice: 25,
            expires: expiresInDays.map { now.addingTimeInterval($0 * 86_400) }
        )
    }

    private func item(_ title: String, source: String, hoursAgo: Double) -> FeedItem {
        FeedItem(id: "\(source)-\(title)", title: title, link: URL(string: "https://example.com/\(title)"), published: now.addingTimeInterval(-hoursAgo * 3600), source: source)
    }

    func testTheEditionLeadsWithTheNewestModelWhileItsRecent() {
        let models = [model("new", daysAgo: 2), model("older", daysAgo: 5), model("oldest", daysAgo: 20)]
        let edition = NewsEditions.today(models: models, announcements: [], retiring: [], since: now.addingTimeInterval(-3 * 86_400), now: now)
        XCTAssertEqual(edition.topStory?.id, "anthropic/new")
        XCTAssertEqual(edition.moreModels.map(\.id), ["anthropic/older", "anthropic/oldest"], "The top story isn't repeated below it")
        XCTAssertEqual(edition.digest.models, 1, "Only models since the last visit count as new")

        let stale = NewsEditions.today(models: [model("old", daysAgo: 20)], announcements: [], retiring: [], since: now, now: now)
        XCTAssertNil(stale.topStory, "A model from weeks ago isn't a top story")
        XCTAssertEqual(stale.moreModels.map(\.id), ["anthropic/old"])
    }

    func testToolsGroupTheirOwnNewsNewestToolFirst() {
        let announcements = [
            item("3.2", source: "Claude Code", hoursAgo: 1),
            item("Cloud tasks", source: "Codex", hoursAgo: 3),
            item("3.1", source: "Claude Code", hoursAgo: 30),
            item("3.0", source: "Claude Code", hoursAgo: 50),
            item("2.9", source: "Claude Code", hoursAgo: 70),
        ]
        let tools = NewsEditions.tools(announcements, since: now.addingTimeInterval(-24 * 3600))
        XCTAssertEqual(tools.map(\.source), ["Claude Code", "Codex"])
        XCTAssertEqual(tools[0].items.count, NewsEditions.itemsPerTool, "Up to three headlines a tool")
        XCTAssertEqual(tools[0].newCount, 1)
        XCTAssertEqual(tools[0].provider, .claude)
        XCTAssertEqual(tools[0].kind, "Changelog")
        XCTAssertEqual(tools[1].kind, "Releases", "Codex is read from its GitHub releases")
    }

    func testTheDigestCountsWhatsNewAndWhatRetiresSoon() {
        let retiring = [model("soon", daysAgo: 100, expiresInDays: 6), model("later", daysAgo: 100, expiresInDays: 45), model("gone", daysAgo: 100, expiresInDays: -1)]
        let edition = NewsEditions.today(
            models: [], announcements: [item("a", source: "Cursor", hoursAgo: 2), item("b", source: "Cursor", hoursAgo: 40)],
            retiring: retiring, since: now.addingTimeInterval(-24 * 3600), now: now
        )
        XCTAssertEqual(edition.digest, NewsEdition.Digest(models: 0, updates: 1, retiring: 1))
        XCTAssertEqual(edition.retiring.map(\.id), ["anthropic/soon"], "Only models retiring within 30 days, and not ones already gone")
        XCTAssertEqual(retiring[0].daysUntilRetirement(now: now), 6)
        XCTAssertFalse(edition.digest.isEmpty)
        XCTAssertTrue(NewsEditions.today(models: [], announcements: [], retiring: [], since: now, now: now).digest.isEmpty)
    }

    func testLabsShowTheirOrganizationsIcon() {
        XCTAssertEqual(NewsEditions.labProviders["anthropic"], .anthropicOrg)
        XCTAssertEqual(NewsEditions.labProviders["deepseek"], .deepseek)
        XCTAssertNil(NewsEditions.labProviders["google"], "Google has no organization icon; its models show a monogram")
        XCTAssertEqual(model("x", daysAgo: 1).contextText, "1M")
    }
}
