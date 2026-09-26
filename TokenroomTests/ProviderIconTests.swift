import XCTest
@testable import Tokenroom

/// Provider icons: every icon a provider names ships in the app, and the ones still missing are
/// the ones meant to be.
final class ProviderIconTests: XCTestCase {
    func testEveryNamedIconShips() {
        for provider in Provider.allCases {
            guard let name = provider.assetName else { continue }
            XCTAssertNotNil(TokenroomImage.named(name), "\(provider.rawValue): \(name) isn't in the app")
        }
    }

    func testProvidersWithoutAnIconAreTheOnesWaitingOnTheirOwners() {
        // xAI's kit isn't in yet.
        XCTAssertEqual(Set(Provider.allCases.filter { $0.assetName == nil }), [.xaiOrg])
    }

    func testGrokAndCopilotShowTheirOwnIcons() {
        XCTAssertEqual(Provider.grok.assetName, "ProviderBuild")
        XCTAssertEqual(Provider.grokBot.assetName, "ProviderBot")
        XCTAssertFalse(Provider.grokBot.iconIsMark, "Grok Bot's is an app icon, drawn as it is")
        XCTAssertEqual(Provider.copilot.assetName, "ProviderCopilot")
        XCTAssertTrue(Provider.copilot.iconIsMark, "GitHub's Copilot mark sits on a white tile")
    }

    func testOnlyMarksWithoutASquareGetATile() {
        XCTAssertFalse(Provider.claude.iconIsMark, "App icons are drawn as they are")
        XCTAssertFalse(Provider.devin.iconIsMark, "Devin's mark comes on its own square")
        XCTAssertTrue(Provider.deepseek.iconIsMark)
        XCTAssertTrue(Provider.anthropicOrg.iconIsMark)
    }
}
