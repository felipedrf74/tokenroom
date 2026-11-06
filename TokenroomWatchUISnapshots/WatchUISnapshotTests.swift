import XCTest

/// The Watch app from sample data, as real screenshots, written to `TOKENROOM_SNAPSHOT_DIR`. Run by
/// `./scripts/ui-snapshots.sh`; without the folder it skips.
final class WatchUISnapshotTests: XCTestCase {
    private var output: URL!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["TOKENROOM_SNAPSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TOKENROOM_SNAPSHOT_DIR to capture screenshots.")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"] + arguments
        app.launch()
        Thread.sleep(forTimeInterval: 2)
        return app
    }

    private func shoot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: output.appendingPathComponent("\(name).png"))
    }

    func testScreens() {
        let list = launch(["-sampleMode", "YES"])
        shoot("watch-list")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.45)
        Thread.sleep(forTimeInterval: 1)
        shoot("watch-list-scrolled")
        list.swipeUp()
        list.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        shoot("watch-list-end")
        for (id, name) in [("claude", "claude"), ("openai", "openai"), ("deepseek", "balance")] {
            let app = launch(["-sampleMode", "YES", "-TokenroomOpen", "tokenroom://provider/\(id)"])
            shoot("watch-detail-\(name)")
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.45)
            Thread.sleep(forTimeInterval: 1)
            shoot("watch-detail-\(name)-scrolled")
            app.swipeUp()
        }
        _ = launch(["-TokenroomEmpty", "YES"])
        shoot("watch-empty")
        _ = launch(["-TokenroomGallery", "YES"])
        shoot("watch-complications")
    }
}
