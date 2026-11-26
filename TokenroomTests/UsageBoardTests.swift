import XCTest
@testable import Tokenroom

final class UsageBoardTests: XCTestCase {
    private typealias Reading = (provider: RelayProvider, history: [String: UsageHistory], source: String, origin: CollectorKind)

    private let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15, minute: 20))!
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    private struct Random {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func below(_ bound: Int) -> Int {
            Int(next() % UInt64(bound))
        }

        mutating func chance(_ percent: Int) -> Bool {
            below(100) < percent
        }

        mutating func pick<Value>(_ values: [Value]) -> Value {
            values[below(values.count)]
        }
    }

    private enum Earlier {
        static func closeWindows(_ readings: [(provider: RelayProvider, history: [String: UsageHistory])], now: Date) -> [CloseWindow] {
            var found: [CloseWindow] = []
            for reading in readings {
                for window in reading.provider.windows where window.isMetered && !window.isAwaitingReading(at: now) {
                    let pace = UsageRanking.pace(for: window, isStale: !reading.provider.isLive, history: reading.history[window.id], now: now)
                    if UsageTiles.isClose(window, pace: pace) {
                        found.append(CloseWindow(provider: reading.provider, window: window, pace: pace))
                    }
                }
            }
            return found.sorted { lhs, rhs in
                let lhsOut = lhs.window.used >= 100 || lhs.pace?.verdict == .limitReached
                let rhsOut = rhs.window.used >= 100 || rhs.pace?.verdict == .limitReached
                if lhsOut != rhsOut { return lhsOut }
                switch (lhs.pace?.runsOutAt, rhs.pace?.runsOutAt) {
                case let (l?, r?) where l != r: return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.window.used > rhs.window.used
                }
            }
        }

        static func closeWindows(_ readings: [Reading], now: Date) -> [CloseWindow] {
            closeWindows(readings.map { (provider: $0.provider, history: $0.history) }, now: now)
        }

        static func warnedWindows(for reading: Reading, close: [CloseWindow], showsAllClose: Bool) -> Set<String> {
            Set(close.prefix(showsAllClose ? .max : 4).filter { $0.provider.id == reading.provider.id }.map(\.window.id))
        }

        static func showsMixedOrigins(_ readings: [Reading]) -> Bool {
            Set(readings.map(\.origin)).count > 1
        }

        static func pace(_ window: RelayWindow, in reading: Reading, now: Date) -> Pace? {
            UsageRanking.pace(for: window, isStale: !reading.provider.isLive, history: reading.history[window.id], now: now)
        }

        static func isClose(_ reading: Reading, now: Date) -> Bool {
            let tile = UsageTiles.tile(for: reading.provider)
            return [tile.ring, tile.bar].compactMap { $0 }.contains { !$0.isAwaitingReading(at: now) && UsageTiles.isClose($0, pace: pace($0, in: reading, now: now)) }
        }

        static func sourceSummary(_ readings: [Reading]) -> String? {
            let labels = Array(Set(readings.map(\.source))).sorted()
            switch labels.count {
            case 0: return nil
            case 1: return labels[0]
            default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
            }
        }
    }

    private func provider(_ id: String, state: String = "live", checkedAgo: TimeInterval = 120, primary: String? = nil, _ windows: [RelayWindow]) -> RelayProvider {
        RelayProvider(
            id: id, name: id, shortName: id, monogram: "T", tint: "#D97757", state: state,
            checkedAt: now.addingTimeInterval(-checkedAgo), fetchedAt: now.addingTimeInterval(-checkedAgo),
            primaryWindowID: primary ?? windows.first?.id, windows: windows
        )
    }

    private func weekly(_ used: Double, resetsIn: TimeInterval = 3 * 86_400, runsOutIn: TimeInterval? = nil) -> RelayWindow {
        RelayWindow(id: "weekly", kind: "weekly", title: "Weekly", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 7 * 86_400,
                    pace: runsOutIn.map { RelayPace(runsOutAt: now.addingTimeInterval($0)) })
    }

    private func session(_ used: Double, resetsIn: TimeInterval = 2 * 3600) -> RelayWindow {
        RelayWindow(id: "session", kind: "session", title: "Session", used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: 5 * 3600)
    }

    private func reading(_ provider: RelayProvider, history: [String: UsageHistory] = [:], source: String = "Mac", origin: CollectorKind = .mac) -> Reading {
        (provider: provider, history: history, source: source, origin: origin)
    }

    private func week(rising used: Double, over hours: Int, endingAgo: TimeInterval = 0) -> UsageHistory {
        var history = UsageHistory(endingAt: now)
        for step in 0...hours {
            let date = now.addingTimeInterval(-endingAgo - Double(hours - step) * hour)
            history.record(used * Double(step + 1) / Double(hours + 1), at: date)
        }
        return history
    }

    private func readings(count: Int, seed: UInt64) -> [Reading] {
        var random = Random(state: seed &* 0x1000_0000_01B3 &+ UInt64(count))
        let sameOrigin = random.chance(20)
        return Provider.allCases.prefix(count).map { provider in
            let isStale = random.chance(25)
            let checkedAgo = isStale ? Double(2 + random.below(40)) * hour : Double(60 + random.below(1800))
            var windows: [RelayWindow] = []
            var history: [String: UsageHistory] = [:]
            let levels: [Double] = [3, 12, 37, 55, 64, 79, 79.6, 80, 86, 94, 95, 99.4, 100, 104]
            func metered(_ id: String, kind: String, title: String, period: Double) -> RelayWindow {
                let used = random.pick(levels)
                let resetsIn = random.chance(15) ? -Double(1 + random.below(7200)) : period * Double(5 + random.below(90)) / 100
                var window = RelayWindow(id: id, kind: kind, title: title, used: used, resetsAt: now.addingTimeInterval(resetsIn), periodSec: random.chance(80) ? period : nil)
                if kind == "billingCycle" { window.startsAt = window.resetsAt?.addingTimeInterval(-period) }
                if random.chance(30) {
                    window.pace = RelayPace(runsOutAt: random.chance(15) ? nil : now.addingTimeInterval(Double(random.below(Int(period))) - 1800))
                }
                if random.chance(70) {
                    history[id] = week(rising: used, over: 1 + random.below(150), endingAgo: isStale ? checkedAgo : Double(random.below(1800)))
                }
                return window
            }
            switch random.below(6) {
            case 0:
                windows = [metered("weekly", kind: "weekly", title: "Weekly", period: 7 * day)]
            case 1:
                windows = [metered("session", kind: "session", title: "Session", period: 5 * hour)]
            case 2:
                windows = [metered("cycle", kind: "billingCycle", title: "This cycle", period: 30 * day), metered("session", kind: "session", title: "Session", period: 5 * hour)]
            case 3:
                let remaining = Double(1 + random.below(4000)) / 100
                windows = [RelayWindow(id: "balance-usd", kind: "pool", title: "Balance", used: 0, resetsAt: nil, amount: QuotaAmount(remaining: remaining, unit: "usd"), metered: false)]
                if random.chance(40) { windows.append(metered("month", kind: "monthly", title: "This month", period: 30 * day)) }
            default:
                windows = [
                    metered("weekly", kind: "weekly", title: "Weekly", period: 7 * day),
                    metered("session", kind: "session", title: "Session", period: 5 * hour),
                ]
                if random.chance(50) { windows.append(metered("opus-weekly", kind: "weekly", title: "Opus weekly", period: 7 * day)) }
                if random.chance(25) { windows.append(metered("daily", kind: "daily", title: "Today", period: day)) }
            }
            if random.chance(8), var copy = windows.first(where: \.isMetered) {
                copy.used = random.pick(levels)
                windows.append(copy)
            }
            let origin: CollectorKind = sameOrigin ? .mac : random.pick(CollectorKind.allCases)
            let source = origin == .mac ? random.pick(["Mac", "Studio"]) : origin == .thisPhone ? "This iPhone" : "iPhone"
            let primary = random.chance(30) ? windows.last?.id : windows.first?.id
            return reading(
                self.provider(provider.rawValue, state: isStale ? "stale" : "live", checkedAgo: checkedAgo, primary: primary, windows),
                history: history, source: source, origin: origin
            )
        }
    }

    private func assertMatchesEarlier(_ readings: [Reading], showsAllClose: Bool, at date: Date, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let board = UsageBoard(readings, showsAllClose: showsAllClose, now: date)
        let close = Earlier.closeWindows(readings, now: date)
        XCTAssertEqual(board.close, close, label, file: file, line: line)
        XCTAssertEqual(board.plans.count, readings.count, label, file: file, line: line)
        for (reading, plan) in zip(readings, board.plans) {
            let tile = UsageTiles.tile(for: reading.provider)
            let id = "\(label) \(reading.provider.id)"
            XCTAssertEqual(plan.tile, tile, id, file: file, line: line)
            XCTAssertEqual(plan.ringPace, tile.ring.flatMap { Earlier.pace($0, in: reading, now: date) }, id, file: file, line: line)
            XCTAssertEqual(plan.barPace, tile.bar.flatMap { Earlier.pace($0, in: reading, now: date) }, id, file: file, line: line)
            XCTAssertEqual(plan.isClose, Earlier.isClose(reading, now: date), id, file: file, line: line)
            XCTAssertEqual(plan.warnedWindows, Earlier.warnedWindows(for: reading, close: close, showsAllClose: showsAllClose), id, file: file, line: line)
        }
        XCTAssertEqual(board.hasMixedOrigins, Earlier.showsMixedOrigins(readings), label, file: file, line: line)
        XCTAssertEqual(board.staleCount, readings.filter { !$0.provider.isLive }.count, label, file: file, line: line)
        XCTAssertEqual(board.latestChecked, readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max(), label, file: file, line: line)
        XCTAssertEqual(board.sourceSummary, Earlier.sourceSummary(readings), label, file: file, line: line)
    }

    func testOneEvaluationGivesWhatEachTileWorkedOutForItself() {
        var sawMoreThanTheRowsShown = false, sawStale = false, sawReset = false, sawMeasured = false, sawRepeatedWindow = false
        var sawWarnedDiffer = false, sawOneOrigin = false, sawMixedOrigins = false
        for count in [1, 4, 19] {
            for seed in UInt64(0)..<150 {
                let readings = readings(count: count, seed: seed)
                for date in [now, now.addingTimeInterval(45 * 60), now.addingTimeInterval(26 * hour)] {
                    for showsAllClose in [false, true] {
                        assertMatchesEarlier(readings, showsAllClose: showsAllClose, at: date, "\(count) plans, seed \(seed), all \(showsAllClose), \(date.timeIntervalSince(now))")
                    }
                    let collapsed = UsageBoard(readings, showsAllClose: false, now: date)
                    let expanded = UsageBoard(readings, showsAllClose: true, now: date)
                    XCTAssertEqual(collapsed.close, expanded.close)
                    if collapsed.close.count > UsageTiles.closeRowLimit { sawMoreThanTheRowsShown = true }
                    if collapsed.plans.map(\.warnedWindows) != expanded.plans.map(\.warnedWindows) { sawWarnedDiffer = true }
                    if collapsed.hasMixedOrigins { sawMixedOrigins = true } else if count > 1 { sawOneOrigin = true }
                }
                sawStale = sawStale || readings.contains { !$0.provider.isLive }
                sawReset = sawReset || readings.contains { $0.provider.windows.contains { $0.isAwaitingReading(at: now) } }
                sawMeasured = sawMeasured || readings.contains { $0.provider.windows.contains { $0.pace != nil } }
                sawRepeatedWindow = sawRepeatedWindow || readings.contains { Set($0.provider.windows.map(\.id)).count < $0.provider.windows.count }
            }
        }
        XCTAssertTrue(sawMoreThanTheRowsShown && sawWarnedDiffer, "Some case has more rows than Close to a limit shows collapsed")
        XCTAssertTrue(sawStale && sawReset && sawMeasured && sawRepeatedWindow, "The cases cover stale readings, elapsed resets, measured run-outs, and a repeated window ID")
        XCTAssertTrue(sawOneOrigin && sawMixedOrigins, "The cases cover one origin and several")
    }

    func testOnlyTheRowsShownHideATilesPace() {
        let burning = (0..<6).map { index in
            reading(provider("plan\(index)", [weekly(90 - Double(index), runsOutIn: Double(index + 2) * hour)]))
        }
        let collapsed = UsageBoard(burning, showsAllClose: false, now: now)
        XCTAssertEqual(collapsed.close.map(\.provider.id), ["plan0", "plan1", "plan2", "plan3", "plan4", "plan5"])
        XCTAssertEqual(collapsed.plans.map(\.warnedWindows), [["weekly"], ["weekly"], ["weekly"], ["weekly"], [], []],
                       "A row behind Show 2 more leaves its tile's run-out on the tile")
        XCTAssertTrue(collapsed.plans.allSatisfy(\.isClose), "A tile is close to a limit whether or not its row is shown")
        XCTAssertNotNil(collapsed.plans[5].ringPace?.runsOutAt)

        let expanded = UsageBoard(burning, showsAllClose: true, now: now)
        XCTAssertEqual(expanded.plans.map(\.warnedWindows), Array(repeating: ["weekly"], count: 6))
        XCTAssertEqual(expanded.close, collapsed.close)
    }

    func testEachTileKeepsItsOwnWindowsWarned() {
        let both = reading(provider("claude", [weekly(91), session(84)]))
        let one = reading(provider("openai", [weekly(40), session(97)]))
        let calm = reading(provider("cursor", [weekly(12)]))
        let board = UsageBoard([both, one, calm], showsAllClose: false, now: now)
        XCTAssertEqual(board.plans.map(\.warnedWindows), [["weekly", "session"], ["session"], []])
        XCTAssertEqual(board.plans.map(\.isClose), [true, true, false])
        XCTAssertEqual(board.plans[0].tile.ring?.id, "weekly")
        XCTAssertEqual(board.plans[0].tile.bar?.id, "session")
    }

    func testAStaleReadingAndAnElapsedResetReadAsTheTileReadThem() {
        let stale = reading(provider("claude", state: "stale", checkedAgo: 2 * hour, [weekly(60, runsOutIn: 5 * hour), session(88)]), source: "Mac", origin: .mac)
        let reset = reading(provider("openai", [weekly(96, resetsIn: -600), session(30)]), source: "This iPhone", origin: .thisPhone)
        let board = UsageBoard([stale, reset], showsAllClose: false, now: now)
        XCTAssertEqual(board.staleCount, 1)
        XCTAssertTrue(board.hasMixedOrigins)
        XCTAssertEqual(board.sourceSummary, "Mac and This iPhone")
        XCTAssertEqual(board.latestChecked, now.addingTimeInterval(-120))
        XCTAssertEqual(board.plans[0].ringPace?.isProjected, true, "A stale reading keeps its measured run-out, labeled projected")
        XCTAssertEqual(board.close.map(\.id), ["claude/weekly", "claude/session"])
        XCTAssertNil(board.plans[1].ringPace, "A window past its reset has no pace")
        XCTAssertFalse(board.plans[1].isClose, "96% before the reset isn't close to a limit after it")
        XCTAssertEqual(board.plans[1].warnedWindows, [])
        assertMatchesEarlier([stale, reset], showsAllClose: false, at: now, "stale and reset")
    }

    func testOneOriginShowsNoOriginOnTiles() {
        let mac = [reading(provider("claude", [weekly(10)])), reading(provider("openai", [weekly(20)]), source: "Studio")]
        let board = UsageBoard(mac, showsAllClose: false, now: now)
        XCTAssertFalse(board.hasMixedOrigins)
        XCTAssertEqual(board.sourceSummary, "Mac and Studio")
        XCTAssertNil(UsageBoard([], showsAllClose: false, now: now).sourceSummary)
        XCTAssertNil(UsageBoard([], showsAllClose: false, now: now).latestChecked)
        XCTAssertEqual(UsageBoard.sourceSummary(["Mac", "This iPhone", "Mac", "iPhone"]), "Mac, This iPhone and iPhone")
    }

    func testTilesStayWithTheirPlansInTheOrderLastRanked() {
        let readings = readings(count: 19, seed: 7)
        let board = UsageBoard(readings, showsAllClose: false, now: now)
        let ranked = Array(readings.map(\.provider.id).reversed().prefix(11))
        let tiles = UsageTiles.ordered(Array(zip(readings, board.plans)), id: \.0.provider.id, as: ranked)
        XCTAssertEqual(tiles.map(\.0.provider.id), UsageTiles.ordered(readings, id: \.provider.id, as: ranked).map(\.provider.id))
        let close = Earlier.closeWindows(readings, now: now)
        for (reading, plan) in tiles {
            XCTAssertEqual(plan.tile, UsageTiles.tile(for: reading.provider))
            XCTAssertEqual(plan.warnedWindows, Earlier.warnedWindows(for: reading, close: close, showsAllClose: false))
        }
    }

    func testCloseWindowsStillRanksAsItDid() {
        for count in [1, 4, 19] {
            for seed in UInt64(0)..<60 {
                let readings = readings(count: count, seed: seed).map { (provider: $0.provider, history: $0.history) }
                XCTAssertEqual(UsageTiles.closeWindows(readings, now: now), Earlier.closeWindows(readings, now: now), "\(count) plans, seed \(seed)")
            }
        }
    }
}
