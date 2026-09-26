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
        // GitHub's terms need written permission for the Copilot icon; xAI's kit isn't in yet.
        XCTAssertEqual(Set(Provider.allCases.filter { $0.assetName == nil }), [.copilot, .xaiOrg])
    }

    func testOnlyMarksWithoutASquareGetATile() {
        XCTAssertFalse(Provider.claude.iconIsMark, "App icons are drawn as they are")
        XCTAssertFalse(Provider.devin.iconIsMark, "Devin's mark comes on its own square")
        XCTAssertTrue(Provider.deepseek.iconIsMark)
        XCTAssertTrue(Provider.anthropicOrg.iconIsMark)
    }
}
