import XCTest
@testable import Tokenroom

final class ProviderUpgradeTests: XCTestCase {
    private func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try! Data(contentsOf: url)
    }

    // MARK: Codex

    func testCodexPlanCreditsBankedAndNamedLimits() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-credits-banked"))
        XCTAssertEqual(snapshot.planLabel, "Plus")
        XCTAssertEqual(snapshot.usedPercent, 37, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly", "code-review", "extra-0"], "Unused named limits stay hidden")
        XCTAssertEqual(snapshot.windows.first?.windowSeconds, 604_800)
        XCTAssertEqual(snapshot.windows.last?.title, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(snapshot.windows.last?.kind, .session)
        XCTAssertEqual(snapshot.banked?.available, 2, "Only credits usable on this plan count")
        XCTAssertEqual(snapshot.extra?.title, "Credits")
        XCTAssertEqual(snapshot.extra?.amount.remaining ?? 0, 1240.5, accuracy: 0.001)
    }

    func testCodexSnapshotCarriesNoIdentity() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-credits-banked"))
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("placeholder"), "Account and user IDs are never kept")
    }

    func testResetCreditExpiriesSkipRedeemedUnsupportedAndExpired() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        let expiries = try OpenAIParser.availableResetExpiries(from: fixture("openai-reset-credits"), now: now)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(expiries, [iso.date(from: "2026-10-03T00:00:00Z")!, iso.date(from: "2026-10-10T00:00:00Z")!])
    }

    func testCachedResetExpiriesFitOnlyTheSameCount() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let dates = [now.addingTimeInterval(86_400), now.addingTimeInterval(2 * 86_400)]
        let entry = OpenAIClient.ExpiryEntry(count: 2, expiries: dates, at: now)
        XCTAssertEqual(OpenAIClient.cachedExpiries(entry, count: 2, now: now.addingTimeInterval(60), ttl: 3_600), dates)
        XCTAssertNil(OpenAIClient.cachedExpiries(entry, count: 2, now: now.addingTimeInterval(3_600), ttl: 3_600), "Looked up again after the TTL")
        XCTAssertEqual(OpenAIClient.cachedExpiries(entry, count: 2, now: now.addingTimeInterval(86_400)), dates, "A failed lookup keeps dates for the same count")
        XCTAssertNil(OpenAIClient.cachedExpiries(entry, count: 1, now: now.addingTimeInterval(60)), "One redeemed: the old two dates no longer fit")
        XCTAssertNil(OpenAIClient.cachedExpiries(nil, count: 0, now: now))
    }

    func testSpendControlBecomesAMeteredDollarWindow() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-spend-control"))
        XCTAssertEqual(snapshot.planLabel, "Business")
        let spend = try XCTUnwrap(snapshot.windows.first { $0.id == "spend" })
        XCTAssertEqual(spend.usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(spend.amount?.limit ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(spend.amount?.unit, "usd")
        XCTAssertNil(snapshot.extra, "No credits when has_credits is false")
    }

    func testBankedAndCreditCaptions() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let banked = BankedResets(available: 2, expiries: [now.addingTimeInterval(86_400 * 12)])
        XCTAssertTrue(ReadingText.banked(banked, now: now).hasPrefix("2 banked resets · next expires "))
        XCTAssertEqual(ReadingText.banked(BankedResets(available: 1), now: now), "1 banked reset")
        let credits = ExtraUsage(title: "Credits", amount: QuotaAmount(remaining: 1240.5, unit: "credits"))
        XCTAssertEqual(ReadingText.extra(credits)?.hasPrefix("Credits · "), true)
        XCTAssertEqual(AmountFormat.text(12.4, unit: "usd", locale: Locale(identifier: "en_US")), "$12.40")
    }

    // MARK: Grok

    /// `GET /v1/settings`: only the plan's display name is read, trimmed.
    func testGrokPlanLabelFromSettings() {
        XCTAssertEqual(GrokParser.planLabel(fromSettings: fixture("grok-settings")), "SuperGrok Heavy")
        XCTAssertNil(GrokParser.planLabel(fromSettings: Data(#"{"subscription_tier_display":""}"#.utf8)))
        XCTAssertNil(GrokParser.planLabel(fromSettings: Data(#"{"subscription_tier":"SUBSCRIPTION_TIER_FREE"}"#.utf8)), "The internal tier name is never shown")
        XCTAssertNil(GrokParser.planLabel(fromSettings: Data("not json".utf8)))
    }

    // MARK: Fixtures

    /// Fixtures must stay anonymous: no emails, API keys, JWTs, or GitHub tokens.
    func testFixturesContainNoSecretsOrIdentity() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        let patterns = ["@", "sk-", "eyJ", "ghp_", "gho_", "ghu_", "github_pat_"]
        for file in files where file.pathExtension == "json" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for pattern in patterns {
                XCTAssertFalse(text.contains(pattern), "\(file.lastPathComponent) contains \(pattern)")
            }
        }
    }
}
