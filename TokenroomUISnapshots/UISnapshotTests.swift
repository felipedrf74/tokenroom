import XCTest

/// Every iPhone screen from sample data, as real screenshots, written to the folder in
/// `TOKENROOM_SNAPSHOT_DIR`. Run by `./scripts/ui-snapshots.sh`; without the folder it skips, so it
/// can't fail anywhere else. `TOKENROOM_SNAPSHOT_FIXTURE` is the synthetic News fixture.
final class UISnapshotTests: XCTestCase {
    private var output: URL!
    private var fixture = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TOKENROOM_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TOKENROOM_SNAPSHOT_DIR to capture screenshots.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        fixture = environment["TOKENROOM_SNAPSHOT_FIXTURE"] ?? ""
    }

    private enum Look: String, CaseIterable {
        case light, dark
        var suffix: String { self == .dark ? "-dark" : "" }
        var appearance: XCUIDevice.Appearance { self == .dark ? .dark : .light }
    }

    private func launch(_ arguments: [String], look: Look = .light, sample: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.appearance = look.appearance
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-TokenroomSnapshotNews", fixture, "-TokenroomSnapshotConnect", "YES", "-AppleLocale", "en_US", "-AppleLanguages", "(en)"]
            + (sample ? ["-sampleMode", "YES"] : []) + arguments
        app.launch()
        Thread.sleep(forTimeInterval: 1.6)
        return app
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func tab(_ app: XCUIApplication, _ title: String) {
        let button = app.tabBars.buttons[title].firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() } else { app.buttons[title].firstMatch.tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    private func tap(_ app: XCUIApplication, _ title: String) {
        let button = app.buttons[title].firstMatch
        if button.waitForExistence(timeout: 3) { button.tap() } else { XCTContext.runActivity(named: "No button \(title)") { _ in } }
        Thread.sleep(forTimeInterval: 1)
    }

    func testUsage() {
        for look in Look.allCases {
            let app = launch(["-onboarded", "YES"], look: look)
            shoot("iphone-usage\(look.suffix)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shoot("iphone-usage-scrolled\(look.suffix)")
        }
    }

    func testProviderDetails() {
        for (id, name) in [("claude", "claude"), ("openai", "openai"), ("deepseek", "balance"), ("anthropicOrg", "org")] {
            for look in Look.allCases {
                let app = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://provider/\(id)"], look: look)
                shoot("iphone-detail-\(name)\(look.suffix)")
                if name == "claude" {
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.8)
                    shoot("iphone-detail-\(name)-scrolled\(look.suffix)")
                }
            }
        }
    }

    func testNews() {
        for look in Look.allCases {
            let app = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://news"], look: look)
            shoot("iphone-news-today\(look.suffix)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shoot("iphone-news-today-scrolled\(look.suffix)")
            app.swipeDown()
            for destination in ["Following", "Skills", "Saved"] {
                tap(app, destination)
                shoot("iphone-news-\(destination.lowercased())\(look.suffix)")
                if destination == "Skills" {
                    app.swipeUp()
                    app.swipeUp()
                    Thread.sleep(forTimeInterval: 0.8)
                    shoot("iphone-news-skills-end\(look.suffix)")
                }
            }
            // A story collection, then a model collection: each reached from Today's "See All".
            tap(app, "Today")
            for (index, name) in ["releases", "models"].enumerated() {
                let links = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] 'See All'"))
                if links.count > index {
                    links.element(boundBy: index).tap()
                    Thread.sleep(forTimeInterval: 1)
                    shoot("iphone-news-collection-\(name)\(look.suffix)")
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    Thread.sleep(forTimeInterval: 0.8)
                }
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    func testSettings() {
        for look in Look.allCases {
            let app = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://settings"], look: look)
            shoot("iphone-settings\(look.suffix)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shoot("iphone-settings-scrolled\(look.suffix)")
            _ = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://alerts"], look: look)
            shoot("iphone-settings-alerts\(look.suffix)")
            _ = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://keys"], look: look)
            shoot("iphone-settings-keys\(look.suffix)")
            _ = launch(["-onboarded", "YES", "-TokenroomOpen", "tokenroom://connect"], look: look)
            shoot("iphone-settings-plans\(look.suffix)")
        }
    }

    func testFirstRun() {
        for look in Look.allCases {
            _ = launch(["-onboarded", "NO"], look: look, sample: false)
            shoot("iphone-onboarding\(look.suffix)")
            _ = launch(["-onboarded", "YES"], look: look, sample: false)
            shoot("iphone-empty\(look.suffix)")
        }
    }

    func testWidgets() {
        for look in Look.allCases {
            let app = launch(["-onboarded", "YES", "-TokenroomGallery", "home"], look: look)
            shoot("iphone-widgets-home\(look.suffix)")
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.8)
            shoot("iphone-widgets-home-scrolled\(look.suffix)")
        }
        let app = launch(["-onboarded", "YES", "-TokenroomGallery", "lock"])
        shoot("iphone-widgets-lock")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.8)
        shoot("iphone-widgets-lock-scrolled")
    }
}
