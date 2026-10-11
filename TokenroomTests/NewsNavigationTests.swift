import AppKit
import SwiftUI
import XCTest
@testable import Tokenroom

/// Hosts the actual reader views with the same toolbar bridge as AppDelegate.
@MainActor final class NewsNavigationTests: XCTestCase {
    func testPushedStoryOffersNativeBackToolbarItem() throws {
        let path = NewsTestNavigation(path: ["source", "story"])
        let library = NewsLibrary(directory: nil)
        let hosting = NSHostingController(rootView: NewsNavigationFixture(path: path, library: library))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 640))
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        settle(hosting.view)
        let back = try XCTUnwrap(window.toolbar?.items.first { $0.label == "Back" },
                                 "A pushed Mac story needs a native Back toolbar item")
        XCTAssertNotNil(back.view, "SwiftUI supplies a real toolbar button view")
        XCTAssertEqual(path.path, ["source", "story"], "Rendering navigation commands must not change the stack")
    }

    func testRootStoryDoesNotOfferBackThatCouldCloseItsWindow() {
        let hosting = NSHostingController(rootView: NavigationStack {
            NewsStoryDetail(item: Self.story, library: NewsLibrary(directory: nil))
        })
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 640))
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        settle(hosting.view)
        XCTAssertFalse(window.toolbar?.items.contains { $0.label == "Back" } ?? false)
    }

    func testPushedStoryRetainsWindowToolbarCommands() {
        let path = NewsTestNavigation(path: ["story"])
        let commands = NewsWindowCommands(isChecking: false, checkNow: {}, openSettings: {})
        let hosting = NSHostingController(rootView: NewsNavigationFixture(path: path, library: NewsLibrary(directory: nil), commands: commands))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 640))
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        settle(hosting.view)
        let labels = window.toolbar?.items.map(\.label) ?? []
        XCTAssertTrue(labels.contains("Back"))
        XCTAssertTrue(labels.contains("Check Now"), "Checking remains available while a reader is pushed")
        XCTAssertTrue(labels.contains { $0.hasPrefix("News Settings") }, "Window settings remain available while a reader is pushed")
        XCTAssertEqual(labels.count, 3, "The pushed reader publishes one copy of each window command")
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
    }
    fileprivate static var story: FeedItem {
        FeedItem(id: "fixture-story", title: "Fixture release", link: URL(string: "https://example.com/release"),
                 published: Date(timeIntervalSince1970: 10), source: "Fixture", sourceID: "fixture")
    }
}

@Observable @MainActor private final class NewsTestNavigation {
    var path: [String]
    init(path: [String]) { self.path = path }
}
private struct NewsNavigationFixture: View {
    @Bindable var path: NewsTestNavigation
    var library: NewsLibrary
    var commands: NewsWindowCommands? = nil
    var body: some View {
        NavigationStack(path: $path.path) {
            Text("Fixture root")
                .navigationDestination(for: String.self) { value in
                    if value == "story" {
                        NewsStoryDetail(item: NewsNavigationTests.story, library: library).newsNavigationBackButton()
                    }
                    else { Text("Fixture source").navigationTitle("Source") }
                }
        }
        .environment(\.newsWindowCommands, commands)
    }
}
