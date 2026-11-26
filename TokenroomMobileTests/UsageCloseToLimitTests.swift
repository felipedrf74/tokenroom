import SwiftUI
import UIKit
import XCTest
@testable import TokenroomMobile

@MainActor
final class UsageCloseToLimitTests: XCTestCase {
    @MainActor private struct Element {
        let object: NSObject
        var label: String { object.accessibilityLabel ?? "" }
        var value: String { object.accessibilityValue ?? "" }
        var hint: String { object.accessibilityHint ?? "" }
        var text: String { label + " " + value }
    }

    private struct Screen: View {
        let store: MobileStore
        @State private var path: [String] = []

        var body: some View {
            UsageView(store: store, path: $path)
                .environment(\.mobileAllowsExternalEffects, false)
        }
    }

    private static let rowHint = "Shows every window and the last 7 days"
    private static let tileValue = "Close to a limit"
    private static let runOut = "Runs out"

    private func elements(under root: NSObject) -> [Element] {
        var seen: Set<ObjectIdentifier> = []
        var found: [Element] = []
        var pending = [root]
        while let object = pending.popLast() {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            found.append(Element(object: object))
            if let children = object.accessibilityElements {
                pending += children.compactMap { $0 as? NSObject }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    pending += (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
                }
            }
            if let view = object as? UIView { pending += view.subviews }
        }
        return found
    }

    private func row(_ name: String, in elements: [Element]) -> Element? {
        elements.first { $0.hint == Self.rowHint && $0.label.contains(name) }
    }

    private func tile(_ name: String, in elements: [Element]) -> Element? {
        elements.first { $0.value.contains(Self.tileValue) && $0.label.contains(name) }
    }

    private func eventually<Value>(within seconds: Double = 5, _ read: () -> Value?) async throws -> Value? {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while true {
            if let value = read() { return value }
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testShowMoreMovesTheFifthRunOutFromItsTileToItsRowInTheAccessibilityTree() async throws {
        let now = Date.now
        let checked = now.addingTimeInterval(-120)
        let plans: [(id: String, name: String)] = [
            ("claude", "Plan A"), ("openai", "Plan B"), ("cursor", "Plan C"), ("grok", "Plan D"), ("copilot", "Plan E"),
        ]
        let names = plans.map(\.name)
        let fifth = names[UsageTiles.closeRowLimit]
        let more = "Show \(plans.count - UsageTiles.closeRowLimit) more"
        let items = plans.enumerated().map { index, plan in
            ReadingCache.Item(provider: RelayProvider(
                id: plan.id, name: plan.name, shortName: plan.name, monogram: "P", tint: "#D97757", state: "live",
                checkedAt: checked, fetchedAt: checked, primaryWindowID: "weekly",
                windows: [RelayWindow(
                    id: "weekly", kind: "weekly", title: "Weekly", used: 90 - Double(index),
                    resetsAt: now.addingTimeInterval(3 * 86_400), periodSec: 7 * 86_400,
                    pace: RelayPace(runsOutAt: now.addingTimeInterval(Double(index + 2) * 3600))
                )]
            ), source: "Mac", origin: .mac)
        }

        let suite = "tokenroom.tests.\(Self.self).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ReadingCache(savedAt: checked, isSample: false, items: items).save(to: folder.appendingPathComponent(ReadingCache.fileName))
        let store = MobileStore(
            defaults: defaults, containerIdentifier: nil, keys: MobileFixtureKeychain().keys,
            directory: folder, connectOnIPhone: false,
            notificationScheduler: { _ in XCTFail("This fixture must not schedule a real notification") },
            allowsExternalEffects: false, platformEffects: .inert, launchDefaults: defaults, sessions: nil
        )
        XCTAssertEqual(store.readings.map(\.provider.name), names, "The store shows the five readings saved for it")

        let scene = try await eventually { UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first }
        let window = UIWindow(windowScene: try XCTUnwrap(scene, "The test host has no window scene to show Usage in"))
        window.rootViewController = UIHostingController(rootView: Screen(store: store))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: folder)
            defaults.removePersistentDomain(forName: suite)
        }

        let found = try await eventually { self.elements(under: window).first { $0.label.contains(more) } }
        let labelled = elements(under: window).filter { !$0.label.isEmpty }.count
        let disclosure = try XCTUnwrap(found, "No \"\(more)\" among the \(labelled) labelled elements the hosted Usage screen vends in this process")

        let collapsed = elements(under: window)
        XCTAssertEqual(names.filter { row($0, in: collapsed) != nil }, Array(names.prefix(UsageTiles.closeRowLimit)),
                       "Collapsed, Close to a limit lists the four most urgent windows")
        XCTAssertEqual(names.filter { tile($0, in: collapsed) != nil }, names, "Every plan's tile is marked close to a limit")
        XCTAssertEqual(tile(fifth, in: collapsed)?.text.contains(Self.runOut), true,
                       "The window behind \"\(more)\" keeps its run-out on its tile")
        XCTAssertEqual(tile(names[0], in: collapsed)?.text.contains(Self.runOut), false,
                       "A window with a row leaves its run-out to the row")
        XCTAssertEqual(row(names[0], in: collapsed)?.text.contains(Self.runOut), true)

        XCTAssertTrue(disclosure.object.accessibilityActivate(), "\"\(more)\" takes the activation")

        let shown = try await eventually { self.row(fifth, in: self.elements(under: window)) }
        XCTAssertEqual(shown?.text.contains(Self.runOut), true, "Expanded, the fifth window has a row with its run-out")
        let quiet = try await eventually {
            self.tile(fifth, in: self.elements(under: window)).flatMap { $0.text.contains(Self.runOut) ? nil : $0 }
        }
        XCTAssertNotNil(quiet, "Expanded, the fifth window's tile leaves its run-out to the row")

        let expanded = elements(under: window)
        XCTAssertEqual(names.filter { row($0, in: expanded) != nil }, names)
        XCTAssertEqual(names.filter { tile($0, in: expanded) != nil }, names)
        XCTAssertFalse(expanded.contains { $0.label.contains(more) }, "\"\(more)\" goes once every row is shown")
    }
}
