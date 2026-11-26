import SwiftUI
import XCTest
@testable import Tokenroom

@MainActor
final class MenuBarObservationTests: XCTestCase {
    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }

        func wait() async {
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            let all = waiting
            waiting = []
            all.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class Watch {
        let store: QuotaStore
        let gate = Gate()
        var reads = 0
        var applied: [MenuBarReading] = []
        var observation: BatchedObservation<MenuBarReading>?

        init(store: QuotaStore, settle: (@Sendable () async -> Void)? = nil) {
            self.store = store
            let gate = gate
            observation = BatchedObservation(
                settle: settle ?? { await gate.wait() },
                read: { [unowned self] in
                    self.reads += 1
                    return MenuBarReading(store)
                },
                apply: { [unowned self] in self.applied.append($0) }
            )
            observation?.start()
        }
    }

    private let moment = Date.now
    private let week: TimeInterval = 7 * 86_400

    private func weekly(_ used: Double, _ provider: Provider, resetsIn: TimeInterval = 3 * 86_400) throws -> QuotaSnapshot {
        try QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used,
            resetsAt: moment.addingTimeInterval(resetsIn), windowSeconds: week)], provider: provider, fetchedAt: moment)
    }

    private func makeStore(_ used: [Provider: Double], style: MenuBarStyle = .percents) throws -> QuotaStore {
        let suite = "tokenroom.tests.menubar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(used.keys.map(\.rawValue), forKey: "enabledProviders")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        settings.menuStyle = style
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: folder))
        for (provider, percent) in used {
            store.statuses[provider] = .live(try weekly(percent, provider))
            store.checkedAt[provider] = moment
        }
        store.ageReadings(at: moment)
        return store
    }

    private func turns(_ count: Int = 200) async {
        for _ in 0..<count { await Task.yield() }
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        var turns = 0
        while !condition(), turns < 20_000 {
            turns += 1
            await Task.yield()
        }
        XCTAssertTrue(condition(), "The batch never got there", file: file, line: line)
    }

    private func settle(_ watch: Watch, reads: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await until({ watch.gate.count == 1 }, file: file, line: line)
        watch.gate.open()
        await until({ watch.reads == reads }, file: file, line: line)
    }

    private func value(_ watch: Watch, _ provider: Provider) -> String? {
        watch.applied.last?.meters.first { $0.provider == provider }?.valueText
    }

    func testStartingReadsOnceAndShowsWhatTheStoreHolds() async throws {
        let store = try makeStore([.claude: 10, .cursor: 40], style: .meters)
        let watch = Watch(store: store)
        XCTAssertEqual(watch.reads, 1)
        XCTAssertEqual(watch.applied, [MenuBarReading(store)])
        XCTAssertEqual(watch.applied.first?.style, .meters)
        XCTAssertEqual(Set(watch.applied.first?.meters.map(\.provider) ?? []), [.claude, .cursor])
        await turns()
        XCTAssertEqual(watch.reads, 1, "Nothing changed, so nothing is read again")
        XCTAssertEqual(watch.gate.count, 0)
    }

    func testABurstIsReadOnceAndEndsOnItsLastState() async throws {
        let store = try makeStore([.claude: 10, .cursor: 40])
        let watch = Watch(store: store)
        for percent in [20.0, 30, 45, 61] {
            store.statuses[.claude] = .live(try weekly(percent, .claude))
            store.checkedAt[.claude] = moment
            await turns(5)
        }
        store.settings.menuStyle = .highest
        store.statuses[.cursor] = .live(try weekly(77, .cursor))
        await turns()
        XCTAssertEqual(watch.reads, 1, "The burst is still settling")
        XCTAssertEqual(watch.gate.count, 1, "One batch for the whole burst")

        watch.gate.open()
        await until { watch.reads == 2 }
        XCTAssertEqual(watch.applied.count, 2)
        XCTAssertEqual(watch.applied.last, MenuBarReading(store))
        XCTAssertEqual(value(watch, .claude), "61")
        XCTAssertEqual(value(watch, .cursor), "77")
        XCTAssertEqual(watch.applied.last?.style, .highest)

        await turns()
        XCTAssertEqual(watch.reads, 2, "The read that ends a batch starts no other")
        XCTAssertEqual(watch.gate.count, 0)
    }

    func testAChangeAfterABatchStartsTheNext() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store)
        store.statuses[.claude] = .live(try weekly(25, .claude))
        await settle(watch, reads: 2)
        XCTAssertEqual(value(watch, .claude), "25")

        store.statuses[.claude] = .live(try weekly(26, .claude))
        await settle(watch, reads: 3)
        XCTAssertEqual(value(watch, .claude), "26")

        store.statuses[.claude] = .signedOut("Run claude login")
        await settle(watch, reads: 4)
        XCTAssertEqual(watch.applied.last?.meters, [], "A signed-out provider leaves the menu bar")
    }

    func testAChangeMadeWhileABatchSettlesIsInItsRead() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store)
        store.statuses[.claude] = .live(try weekly(25, .claude))
        await until { watch.gate.count == 1 }
        store.statuses[.claude] = .live(try weekly(90, .claude))
        store.settings.menuStyle = .meters
        await turns()
        XCTAssertEqual(watch.gate.count, 1)
        watch.gate.open()
        await until { watch.reads == 2 }
        XCTAssertEqual(value(watch, .claude), "90")
        XCTAssertEqual(watch.applied.last?.style, .meters)
        await turns()
        XCTAssertEqual(watch.reads, 2)
    }

    func testTheStyleAloneStartsABatch() async throws {
        let store = try makeStore([.claude: 10, .cursor: 40])
        let watch = Watch(store: store)
        store.settings.menuStyle = .meters
        await settle(watch, reads: 2)
        XCTAssertEqual(watch.applied.last?.style, .meters)
        XCTAssertEqual(watch.applied.last?.meters, watch.applied.first?.meters)

        store.settings.setShowsInMenuBar(.cursor, false)
        await settle(watch, reads: 3)
        XCTAssertEqual(watch.applied.last?.meters.map(\.provider), [.claude])
    }

    func testWhatTheMenuBarDoesNotShowStartsNoBatch() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store)
        store.lastAttempt = moment
        store.isRefreshing = true
        store.settings.popoverStyle = .classic
        await turns()
        XCTAssertEqual(watch.reads, 1)
        XCTAssertEqual(watch.gate.count, 0)
    }

    func testAnUnchangedReadingComesBackEqual() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store)
        store.statuses[.claude] = .live(try weekly(10, .claude))
        await settle(watch, reads: 2)
        XCTAssertEqual(watch.applied.count, 2)
        XCTAssertEqual(watch.applied[0], watch.applied[1], "The status item draws nothing again for an equal reading")
    }

    func testAgingMarksTheMeterStaleWithItsAge() async throws {
        let store = try makeStore([.openai: 78])
        let watch = Watch(store: store)
        XCTAssertEqual(watch.applied.last?.meters.first?.isStale, false)
        XCTAssertEqual(MenuBarLayout.tooltip(for: watch.applied.last?.meters ?? []), "OpenAI 78% used")

        store.ageReadings(at: moment.addingTimeInterval(2 * 3600))
        await settle(watch, reads: 2)
        let meter = try XCTUnwrap(watch.applied.last?.meters.first)
        XCTAssertTrue(meter.isStale)
        XCTAssertEqual(MenuBarLayout.tooltip(for: [meter]), "OpenAI 78% used, last reading 2h ago")

        store.statuses[.openai] = .live(try QuotaSnapshot.headlined(by: [QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 80,
            resetsAt: moment.addingTimeInterval(3 * 86_400), windowSeconds: week)], provider: .openai, fetchedAt: moment.addingTimeInterval(2 * 3600)))
        store.checkedAt[.openai] = moment.addingTimeInterval(2 * 3600)
        await settle(watch, reads: 3)
        let fresh = try XCTUnwrap(watch.applied.last?.meters.first)
        XCTAssertFalse(fresh.isStale)
        XCTAssertEqual(MenuBarLayout.tooltip(for: [fresh]), "OpenAI 80% used")
    }

    func testAResetLeavesTheMeterAwaitingItsReading() async throws {
        let store = try makeStore([.claude: 64])
        store.statuses[.claude] = .live(try weekly(64, .claude, resetsIn: 600))
        let watch = Watch(store: store)
        XCTAssertEqual(watch.applied.last?.meters.first?.displayValue, "64%")

        store.ageReadings(at: moment.addingTimeInterval(601))
        await settle(watch, reads: 2)
        let meter = try XCTUnwrap(watch.applied.last?.meters.first)
        XCTAssertTrue(meter.isAwaitingReading)
        XCTAssertEqual(meter.displayValue, "—")
        XCTAssertEqual(meter.drawnUsedPercent, 0)
    }

    func testAStatusItemWidthFollowsTheReadingItWasGiven() async throws {
        let store = try makeStore([.claude: 10, .cursor: 40, .openai: 5])
        let watch = Watch(store: store)
        let wide = try XCTUnwrap(watch.applied.last)
        store.settings.menuStyle = .highest
        await settle(watch, reads: 2)
        let narrow = try XCTUnwrap(watch.applied.last)
        let widths = [wide, narrow].map { reading in
            NSHostingView(rootView: MenuBarLabel(meters: reading.meters, style: reading.style)).fittingSize.width
        }
        XCTAssertGreaterThan(widths[0], widths[1], "Three columns are wider than the most urgent one alone")
        XCTAssertEqual(MenuBarLayout.displayed(narrow.meters, style: narrow.style).map(\.provider), [.cursor])
        XCTAssertEqual(MenuBarLayout.tooltip(for: narrow.meters).split(separator: "\n").count, 3, "The tooltip still names every provider")
    }

    func testTheDefaultWindowDeliversTheLastStateOfABurst() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store, settle: BatchedObservation<MenuBarReading>.defaultSettle)
        let began = ContinuousClock.now
        for percent in stride(from: 11.0, through: 30, by: 1) {
            store.statuses[.claude] = .live(try weekly(percent, .claude))
            await Task.yield()
        }
        let burst = ContinuousClock.now - began
        let deadline = ContinuousClock.now + .seconds(5)
        while value(watch, .claude) != "30", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(value(watch, .claude), "30")
        XCTAssertEqual(watch.applied.last, MenuBarReading(store))
        if burst < .milliseconds(40) {
            XCTAssertEqual(watch.reads, 2, "Twenty changes inside one window are one read")
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(watch.applied.last, MenuBarReading(store))
        XCTAssertLessThanOrEqual(watch.reads, 21)
    }

    func testAnObservationThatIsGoneReadsNothing() async throws {
        let store = try makeStore([.claude: 10])
        let watch = Watch(store: store)
        watch.observation = nil
        store.statuses[.claude] = .live(try weekly(50, .claude))
        await turns()
        XCTAssertEqual(watch.reads, 1)
        XCTAssertEqual(watch.gate.count, 0)
    }
}
