import XCTest
@testable import Tokenroom

final class WidgetArrangementTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        suites.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "tokenroom.tests.\(Self.self).\(suites.count)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let ranked = ["openai", "claude", "cursor", "grok"]

    private func arranged(_ arrangement: WidgetArrangement, _ ids: [String]? = nil) -> [String] {
        arrangement.arranged(ids ?? ranked, id: { $0 })
    }

    func testWithNoChoiceEveryProviderShowsMostUrgentFirst() {
        XCTAssertEqual(arranged(WidgetArrangement()), ranked)
        XCTAssertEqual(arranged(WidgetArrangement.load(from: makeDefaults())), ranked)
    }

    func testAHiddenProviderIsLeftOutInEitherOrder() {
        XCTAssertEqual(arranged(WidgetArrangement(hidden: ["claude"])), ["openai", "cursor", "grok"])
        XCTAssertEqual(arranged(WidgetArrangement(order: .manual, sequence: ["grok", "claude", "openai"], hidden: ["claude"])), ["grok", "openai", "cursor"])
    }

    func testASavedSequenceWaitsUntilTheUserPicksTheirOwnOrder() {
        let saved = WidgetArrangement(order: .urgency, sequence: ["grok", "cursor", "claude", "openai"])
        XCTAssertEqual(arranged(saved), ranked, "Most urgent first ignores the sequence, and keeps it for later")
        var manual = saved
        manual.order = .manual
        XCTAssertEqual(arranged(manual), ["grok", "cursor", "claude", "openai"])
    }

    func testAProviderConnectedSinceFollowsTheOrderedOnesAsRanked() {
        let arrangement = WidgetArrangement(order: .manual, sequence: ["grok", "claude", "grok"])
        XCTAssertEqual(arranged(arrangement, ["zai", "openai", "claude", "grok"]), ["grok", "claude", "zai", "openai"])
    }

    func testTheSettingsListKeepsHiddenProvidersInPlace() {
        let arrangement = WidgetArrangement(order: .urgency, sequence: ["grok", "claude"], hidden: ["grok"])
        XCTAssertEqual(arrangement.listed(ranked, id: { $0 }), ["grok", "claude", "openai", "cursor"])
        XCTAssertFalse(arrangement.isShown("grok"))
        XCTAssertTrue(arrangement.setting("grok", shown: true).isShown("grok"))
        XCTAssertFalse(arrangement.setting("claude", shown: false).isShown("claude"))
    }

    func testMovingARowSwitchesToTheUsersOrderAndKeepsAbsentProvidersPlaces() {
        let arrangement = WidgetArrangement(sequence: ["kimiCode", "openai", "claude"])
        let listed = arrangement.listed(ranked, id: { $0 })
        XCTAssertEqual(listed, ["openai", "claude", "cursor", "grok"])
        let down = arrangement.moving(listed, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(down.order, .manual)
        XCTAssertEqual(down.sequence, ["kimiCode", "claude", "cursor", "openai", "grok"], "Kimi keeps the first place")
        let up = down.moving(["claude", "cursor", "openai", "grok"], from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(up.sequence, ["kimiCode", "grok", "claude", "cursor", "openai"])
        XCTAssertEqual(arranged(up), ["grok", "claude", "cursor", "openai"])
        XCTAssertEqual(arranged(up, ["openai", "kimiCode", "grok"]), ["kimiCode", "grok", "openai"], "Back where it was left")
        let middle = WidgetArrangement(order: .manual, sequence: ["openai", "kimiCode", "claude"])
            .moving(["openai", "claude"], from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(middle.sequence, ["claude", "kimiCode", "openai"], "An absent provider stays between the two it was between")
    }

    func testChoosingYourOwnOrderAgainKeepsAnAbsentProvidersPlace() {
        var arrangement = WidgetArrangement(order: .urgency, sequence: ["claude", "cursor", "openai"])
        let onScreen = arrangement.listed(["openai", "cursor"], id: { $0 })
        arrangement = arrangement.placing(onScreen)
        arrangement.order = .manual
        XCTAssertEqual(arrangement.sequence, ["claude", "cursor", "openai"])
        XCTAssertEqual(arranged(arrangement, ["openai", "claude", "cursor"]), ["claude", "cursor", "openai"])
        let first = WidgetArrangement().placing(ranked)
        XCTAssertEqual(first.sequence, ranked)
        XCTAssertEqual(WidgetArrangement(sequence: ["grok"]).placing(ranked).sequence, ["grok", "openai", "claude", "cursor"])
    }

    func testTheChoiceSurvivesASaveAndTheDefaultLeavesNothingBehind() {
        let defaults = makeDefaults()
        let arrangement = WidgetArrangement(order: .manual, sequence: ["grok", "claude"], hidden: ["cursor", "openai"])
        arrangement.save(to: defaults)
        XCTAssertEqual(WidgetArrangement.load(from: defaults), arrangement)
        WidgetArrangement().save(to: defaults)
        XCTAssertNil(defaults.object(forKey: WidgetArrangement.defaultsKey))
    }

    func testASavedChoiceItCantReadFallsBackToEverything() throws {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: WidgetArrangement.defaultsKey)
        XCTAssertEqual(WidgetArrangement.load(from: defaults), WidgetArrangement())
        let newer = Data(#"{"order":"pinnedFirst","sequence":["claude"],"hidden":["grok"],"density":"compact"}"#.utf8)
        let decoded = try JSONDecoder().decode(WidgetArrangement.self, from: newer)
        XCTAssertEqual(decoded, WidgetArrangement(order: .urgency, sequence: ["claude"], hidden: ["grok"]))
    }

    func testOnlyProviderIDsAreSaved() throws {
        let data = try JSONEncoder().encode(WidgetArrangement(order: .manual, sequence: ["claude"], hidden: ["grok"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["order", "sequence", "hidden"])
    }
}
