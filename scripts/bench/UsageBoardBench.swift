import Foundation
import Observation

struct UsageBenchRandom {
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

    mutating func pick<Value>(_ values: [Value]) -> Value {
        values[below(values.count)]
    }
}

@Observable
@MainActor
final class UsageBenchStore {
    struct Reading: Identifiable, Equatable {
        var provider: RelayProvider
        var source: String
        var history: [String: UsageHistory]
        var pace: Pace?
        var origin: CollectorKind

        var id: String { provider.id }

        init(_ item: ReadingCache.Item, now: Date) {
            provider = item.provider
            source = item.source
            history = item.history
            pace = ReadingAssembler.pace(for: item, now: now)
            origin = item.resolvedOrigin
        }
    }

    private var storedReadings: [Reading]
    private var presentationNow: Date
    var readings: [Reading] {
        storedReadings.compactMap { reading in
            guard let provider = ReadingFreshness.present(reading.provider, fallback: lastRefresh ?? .distantPast, now: presentationNow) else { return nil }
            var result = reading
            result.provider = provider
            result.pace = ReadingAssembler.pace(for: .init(provider: provider, source: reading.source, history: reading.history, origin: reading.origin), now: presentationNow)
            return result
        }
    }
    private(set) var disconnected: [Reading] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var sampleMode = false

    init(_ items: [ReadingCache.Item], now: Date) {
        storedReadings = items.map { Reading($0, now: now) }
        presentationNow = now
        lastRefresh = now.addingTimeInterval(-40)
    }

    var latestChecked: Date? {
        readings.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.max()
    }

    var sourceSummary: String? {
        let labels = Array(Set(readings.map(\.source))).sorted()
        switch labels.count {
        case 0: return nil
        case 1: return labels[0]
        default: return labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        }
    }
}

enum UsageBenchFixture {
    static let now = Calendar.gregorianUTC.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15, minute: 20))!
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
    static let firstPlans: [[Double]] = [[91, 84, 62], [88, 97], [57, 100], [83]]
    static let levels: [Double] = [9, 18, 27, 34, 46, 57, 64, 72, 78, 81, 86, 92, 96, 100]

    static func isStale(_ index: Int, of plans: Int) -> Bool {
        plans > 1 && index % 4 == 3
    }

    static func hasElapsedReset(_ index: Int, of plans: Int) -> Bool {
        plans > 1 && index % 5 == 1
    }

    static func items(plans: Int) -> [ReadingCache.Item] {
        let calendar = Calendar.gregorianUTC
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)!
        let items = Provider.allCases.prefix(plans).enumerated().map { index, provider -> ReadingCache.Item in
            var random = UsageBenchRandom(state: 0x746F_6B65_6E72 &+ UInt64(index) &* 7919)
            let stale = isStale(index, of: plans)
            let checked = now.addingTimeInterval(stale ? -Double(2 + random.below(5)) * hour - 600 : -Double(90 + random.below(500)))
            var given = index < firstPlans.count ? firstPlans[index] : []
            func used() -> Double {
                given.isEmpty ? random.pick(levels) : given.removeFirst()
            }
            func weekly(_ id: String, _ title: String) -> QuotaWindow {
                QuotaWindow(id: id, kind: .weekly, title: title, usedPercent: used(),
                            resetsAt: now.addingTimeInterval(Double(1 + random.below(6)) * day + Double(random.below(20)) * hour), windowSeconds: 7 * day)
            }
            func session() -> QuotaWindow {
                let resetsIn = hasElapsedReset(index, of: plans) ? -600 : Double(20 + random.below(250)) * 60
                return QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: used(), resetsAt: now.addingTimeInterval(resetsIn), windowSeconds: 5 * hour)
            }
            var windows: [QuotaWindow]
            switch index % 5 {
            case 0:
                windows = [weekly("weekly", "Weekly"), session(), weekly("opus-weekly", "Opus weekly")]
            case 1:
                windows = [weekly("weekly", "Weekly"), session()]
            case 2:
                let resetsAt = now.addingTimeInterval(Double(3 + random.below(24)) * day)
                windows = [
                    QuotaWindow(id: "cycle", kind: .billingCycle, title: "This cycle", usedPercent: used(), resetsAt: resetsAt, startsAt: resetsAt.addingTimeInterval(-30 * day)),
                    session(),
                ]
            case 3:
                let limit = 300.0
                let percent = used()
                windows = [QuotaWindow(
                    id: "premium_interactions", kind: .monthly, title: "Premium requests", usedPercent: percent, resetsAt: nextMonth, startsAt: monthStart,
                    amount: QuotaAmount(used: (percent * limit / 100).rounded(), limit: limit, remaining: limit - (percent * limit / 100).rounded(), unit: "requests")
                )]
            default:
                if index % 10 == 9 {
                    let spent = Double(40 + random.below(700))
                    windows = [QuotaWindow(id: "spend-month", kind: .monthly, title: "This month", usedPercent: spent / 10, resetsAt: nextMonth, startsAt: monthStart,
                                           amount: QuotaAmount(used: spent, limit: 1000, unit: "usd"))]
                } else {
                    windows = [QuotaWindow(id: "balance-usd", kind: .pool, title: "Balance", usedPercent: 0, resetsAt: nil,
                                           amount: QuotaAmount(remaining: Double(300 + random.below(4000)) / 100, unit: "usd"), metered: false)]
                }
            }
            var snapshot = try! QuotaSnapshot.headlined(by: windows, provider: provider, fetchedAt: checked, planLabel: index % 2 == 0 ? "Pro" : nil)
            if index % 5 == 1 {
                snapshot.banked = BankedResets(available: 2, expiries: [now.addingTimeInterval(5 * day), now.addingTimeInterval(12 * day)])
            }
            var relay = RelayProvider(provider: provider, status: .live(snapshot), checkedAt: checked)
            var history: [String: UsageHistory] = [:]
            for (position, window) in windows.enumerated() {
                if !window.isMetered, let remaining = window.amount?.remainingOrComputed {
                    history[window.id] = SampleData.balanceWeek(remaining: remaining, now: checked)
                }
                guard window.isMetered, let resetsAt = window.resetsAt,
                      let length = Pace.windowLength(kind: window.kind, resetsAt: resetsAt, startsAt: window.startsAt, windowSeconds: window.windowSeconds)
                else { continue }
                history[window.id] = SampleData.week(
                    current: window.usedPercent, opened: resetsAt.addingTimeInterval(-length), length: length,
                    previousPeak: min(95, window.usedPercent + 20 + Double(position * 7 % 15)), now: checked
                )
                if window.kind != .session, (index + position) % 3 == 0, resetsAt > now {
                    let left = resetsAt.timeIntervalSince(now)
                    relay.windows[position].pace = RelayPace(runsOutAt: now.addingTimeInterval(left * Double(15 + random.below(70)) / 100))
                }
            }
            let origin: CollectorKind = index % 3 == 1 ? .thisPhone : index % 7 == 6 ? .otherPhone : .mac
            let source = origin == .thisPhone ? "This iPhone" : origin == .otherPhone ? "iPhone" : "Mac"
            return ReadingCache.Item(provider: relay, source: source, history: history, origin: origin)
        }
        return UsageRanking.sorted(items, provider: \.provider, now: now, windowPace: { item, window in
            UsageRanking.pace(for: window, isStale: !item.provider.isLive, history: item.history[window.id], now: now)
        })
    }
}

struct UsageBenchScreen: Equatable {
    struct Tile: Equatable {
        var id: String
        var tile: UsageTile
        var isClose: Bool
        var showsOrigin: Bool
        var ringMark: Double? = nil
        var ringStatus: Pace? = nil
        var barMark: Double? = nil
        var barStatus: Pace? = nil
    }

    var showsNotice = false
    var close: [CloseWindow] = []
    var chips: [String] = []
    var tiles: [Tile] = []
    var subtitle = ""
    var showsEmptyState = false
    var ids: [String] = []

    var checksum: Int {
        close.count &* 1_000_003 &+ tiles.count &* 1009 &+ ids.count &+ subtitle.utf8.count
    }
}

@MainActor
struct UsageBenchBefore {
    var store: UsageBenchStore
    var showsAllClose: Bool
    var order: [String]
    var clock: Date

    func screen(at date: Date) -> UsageBenchScreen {
        var screen = UsageBenchScreen()
        if !store.sampleMode, !store.readings.isEmpty || !store.disconnected.isEmpty {
            screen.showsNotice = true
        }
        let close = closeWindows(at: date)
        screen.close = close
        if !highlights.isEmpty, !store.readings.isEmpty {
            screen.chips = highlights
        }
        if !store.readings.isEmpty {
            screen.tiles = tiles(at: date)
        }
        screen.subtitle = header(at: date) ?? ""
        if store.readings.isEmpty, store.disconnected.isEmpty {
            screen.showsEmptyState = true
        }
        screen.ids = store.readings.map(\.id)
        return screen
    }

    private func tiles(at date: Date) -> [UsageBenchScreen.Tile] {
        orderedReadings.map { reading in
            tile(reading, date: date, showsOrigin: showsOrigin(reading),
                 warnedWindows: Set(closeWindows(at: date).prefix(showsAllClose ? .max : 4).filter { $0.provider.id == reading.id }.map(\.window.id)))
        }
    }

    private func tile(_ reading: UsageBenchStore.Reading, date: Date, showsOrigin: Bool, warnedWindows: Set<String>) -> UsageBenchScreen.Tile {
        let provider = reading.provider
        let isStale = !provider.isLive
        func pace(_ window: RelayWindow) -> Pace? {
            UsageRanking.pace(for: window, isStale: isStale, history: reading.history[window.id], now: date)
        }
        let tile = UsageTiles.tile(for: provider)
        let isClose = [tile.ring, tile.bar].compactMap { $0 }.contains { !$0.isAwaitingReading(at: date) && UsageTiles.isClose($0, pace: pace($0)) }
        var result = UsageBenchScreen.Tile(id: reading.id, tile: tile, isClose: isClose, showsOrigin: showsOrigin)
        if let ring = tile.ring {
            result.ringMark = pace(ring)?.elapsedFraction
            result.ringStatus = warnedWindows.contains(ring.id) ? nil : pace(ring)
        }
        if let bar = tile.bar {
            result.barMark = pace(bar)?.elapsedFraction
            result.barStatus = warnedWindows.contains(bar.id) ? nil : pace(bar)
        }
        return result
    }

    private func showsOrigin(_ reading: UsageBenchStore.Reading) -> Bool {
        !store.sampleMode && Set(store.readings.map(\.origin)).count > 1
    }

    private var orderedReadings: [UsageBenchStore.Reading] {
        UsageTiles.ordered(store.readings, id: \.id, as: order)
    }

    private func closeWindows(at date: Date) -> [CloseWindow] {
        Self.closeWindows(store.readings.map { (provider: $0.provider, history: $0.history) }, now: date)
    }

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

    private var highlights: [String] {
        var items: [String] = []
        let banked = store.readings.filter { $0.provider.availableBanked(at: clock) != nil }
        let bankedCount = banked.reduce(0) { $0 + ($1.provider.availableBanked(at: clock)?.available ?? 0) }
        if bankedCount > 0, let first = banked.first {
            items.append((bankedCount == 1 ? "1 banked reset" : "\(bankedCount) banked resets") + " opens " + first.id)
        }
        return items
    }

    private func header(at date: Date) -> String? {
        guard !store.sampleMode, let source = store.sourceSummary else { return nil }
        let stale = store.readings.filter { !$0.provider.isLive }.count
        let staleNote = stale > 0 ? " · \(stale) stale" : ""
        if store.isRefreshing { return "From \(source) · checking…" + staleNote }
        guard let checked = store.latestChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked, now: date))" + staleNote
    }
}

@MainActor
struct UsageBenchAfter {
    var store: UsageBenchStore
    var showsAllClose: Bool
    var order: [String]
    var clock: Date

    func screen(at date: Date) -> UsageBenchScreen {
        let readings = store.readings
        let board = UsageBoard(
            readings.map { (provider: $0.provider, history: $0.history, source: $0.source, origin: $0.origin) },
            showsAllClose: showsAllClose, now: date
        )
        let close = board.close
        let highlights = highlights(in: readings)
        var screen = UsageBenchScreen()
        if !store.sampleMode, !readings.isEmpty || !store.disconnected.isEmpty {
            screen.showsNotice = true
        }
        screen.close = close
        if !highlights.isEmpty, !readings.isEmpty {
            screen.chips = highlights
        }
        if !readings.isEmpty {
            screen.tiles = tiles(readings, board: board, at: date)
        }
        screen.subtitle = header(board, at: date) ?? ""
        if readings.isEmpty, store.disconnected.isEmpty {
            screen.showsEmptyState = true
        }
        screen.ids = readings.map(\.id)
        return screen
    }

    private func tiles(_ readings: [UsageBenchStore.Reading], board: UsageBoard, at date: Date) -> [UsageBenchScreen.Tile] {
        let tiles = UsageTiles.ordered(Array(zip(readings, board.plans)), id: \.0.id, as: order)
        let showsOrigin = !store.sampleMode && board.hasMixedOrigins
        return tiles.map { reading, plan in
            tile(reading, plan: plan, showsOrigin: showsOrigin)
        }
    }

    private func tile(_ reading: UsageBenchStore.Reading, plan: UsageBoard.Plan, showsOrigin: Bool) -> UsageBenchScreen.Tile {
        let tile = plan.tile
        let isClose = plan.isClose
        var result = UsageBenchScreen.Tile(id: reading.id, tile: tile, isClose: isClose, showsOrigin: showsOrigin)
        if let ring = tile.ring {
            result.ringMark = plan.ringPace?.elapsedFraction
            result.ringStatus = plan.warnedWindows.contains(ring.id) ? nil : plan.ringPace
        }
        if let bar = tile.bar {
            result.barMark = plan.barPace?.elapsedFraction
            result.barStatus = plan.warnedWindows.contains(bar.id) ? nil : plan.barPace
        }
        return result
    }

    private func highlights(in readings: [UsageBenchStore.Reading]) -> [String] {
        var items: [String] = []
        let banked = readings.filter { $0.provider.availableBanked(at: clock) != nil }
        let bankedCount = banked.reduce(0) { $0 + ($1.provider.availableBanked(at: clock)?.available ?? 0) }
        if bankedCount > 0, let first = banked.first {
            items.append((bankedCount == 1 ? "1 banked reset" : "\(bankedCount) banked resets") + " opens " + first.id)
        }
        return items
    }

    private func header(_ board: UsageBoard, at date: Date) -> String? {
        guard !store.sampleMode, let source = board.sourceSummary else { return nil }
        let stale = board.staleCount
        let staleNote = stale > 0 ? " · \(stale) stale" : ""
        if store.isRefreshing { return "From \(source) · checking…" + staleNote }
        guard let checked = board.latestChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked, now: date))" + staleNote
    }
}

enum UsageBenchText {
    static let zone = TimeZone(identifier: "UTC")!

    static func lines(_ screen: UsageBenchScreen, readings: [UsageBenchStore.Reading], showsAllClose: Bool, date: Date) -> [String] {
        var lines = ["subtitle: \(screen.subtitle)", "iCloud notice considered: \(screen.showsNotice)", "empty state: \(screen.showsEmptyState)"]
        lines.append("reading IDs: " + screen.ids.joined(separator: ","))
        if !screen.close.isEmpty {
            lines.append("Close to a limit \(screen.close.count)")
            for item in screen.close.prefix(showsAllClose ? screen.close.count : UsageTiles.closeRowLimit) {
                lines.append("row \(item.id): \(item.provider.name) · \(item.window.displayTitle) · \(ReadingText.headline(item.window, now: date)) · \(caption(item, date: date))")
            }
            if screen.close.count > UsageTiles.closeRowLimit, !showsAllClose {
                lines.append("Show \(screen.close.count - UsageTiles.closeRowLimit) more")
            }
        }
        lines += screen.chips.map { "chip: \($0)" }
        if !screen.tiles.isEmpty, !screen.close.isEmpty { lines.append("All plans") }
        let byID = Dictionary(readings.map { ($0.id, $0) }) { first, _ in first }
        for tile in screen.tiles {
            guard let reading = byID[tile.id] else {
                lines.append("tile \(tile.id): no reading")
                continue
            }
            lines += self.lines(tile, reading: reading, date: date)
        }
        return lines
    }

    static func lines(_ tile: UsageBenchScreen.Tile, reading: UsageBenchStore.Reading, date: Date) -> [String] {
        let provider = reading.provider
        let isStale = !provider.isLive
        var lines = ["tile \(tile.id): \(provider.name)" + (tile.isClose ? " · value Close to a limit" : "")]
        if let ring = tile.tile.ring {
            lines.append("  ring \(ring.id): \(ring.displayTitle) · \(ReadingText.headline(ring, now: date)) · \(mark(tile.ringMark)) · \(status(ring, pace: tile.ringStatus, isStale: isStale, date: date))")
        } else if let balance = tile.tile.balance {
            var text = "  balance \(balance.id): \(ReadingText.headline(balance, now: date))"
            if balance.isAwaitingReading(at: date) {
                text += " · Reset · awaiting reading"
            } else if !isStale, let forecast = Forecast.text(for: balance, history: reading.history[balance.id], checkedAt: provider.checkedAt ?? provider.fetchedAt, now: date) {
                text += " · \(forecast)"
            }
            lines.append(text)
        }
        if let bar = tile.tile.bar {
            lines.append("  bar \(bar.id): \(bar.displayTitle) · \(ReadingText.headline(bar, now: date)) · \(mark(tile.barMark)) · \(status(bar, pace: tile.barStatus, isStale: isStale, date: date))")
        } else if tile.tile.balance == nil {
            if let amount = tile.tile.ring?.amount, let detail = ReadingText.amountDetail(amount) {
                lines.append("  detail: \(detail)")
            } else if let plan = provider.plan {
                lines.append("  detail: \(plan)")
            }
        }
        if let warning = UsageRanking.limitWarning(for: provider, now: date) {
            lines.append("  warning: \(warning)")
        }
        if isStale {
            lines.append("  stale: " + (provider.message ?? "Last reading \(RelativeTime.ago(provider.fetchedAt, now: date))."))
        }
        if tile.showsOrigin || isStale {
            let checked = (provider.checkedAt ?? provider.fetchedAt).map { " · \(RelativeTime.ago($0, now: date))" } ?? ""
            lines.append("  origin: " + reading.origin.phrase + checked)
        }
        return lines
    }

    static func mark(_ fraction: Double?) -> String {
        fraction.map { "pace mark \(String(format: "%.6f", $0))" } ?? "no pace mark"
    }

    static func status(_ window: RelayWindow, pace: Pace?, isStale: Bool, date: Date) -> String {
        if let pace, pace.isProjected {
            return pace.caption(now: date, timeZone: zone)
        } else if !isStale, let pace, pace.verdict == .limitReached {
            return pace.caption(now: date, timeZone: zone)
        } else if !isStale, let pace, let runsOut = pace.currentRunOut {
            return "Runs out \(Pace.shortMoment(runsOut, now: date, timeZone: zone))"
        } else if let reset = ReadingText.reset(window, now: date) {
            return reset
        }
        return "no status"
    }

    static func caption(_ item: CloseWindow, date: Date) -> String {
        guard item.provider.isLive else {
            return "\(ReadingText.lastChecked(item.provider.checkedAt ?? item.provider.fetchedAt, now: date)) · \(liveCaption(item, date: date))"
        }
        return liveCaption(item, date: date)
    }

    static func liveCaption(_ item: CloseWindow, date: Date) -> String {
        if let pace = item.pace, pace.isProjected {
            return pace.caption(now: date, timeZone: zone)
        }
        if let pace = item.pace, pace.verdict == .limitReached {
            return pace.caption(now: date, timeZone: zone)
        }
        if let pace = item.pace, let runsOut = pace.currentRunOut {
            return "Runs out \(Pace.shortMoment(runsOut, now: date, timeZone: zone)) · \(UsageTiles.lead(runsOut: runsOut, resetsAt: pace.resetsAt))"
        }
        let level = AlertPreferences.supportedThresholds.filter { Double($0) <= item.window.used }.max() ?? Int(UsageTiles.closeUse)
        let reset = ReadingText.reset(item.window, now: date).map { " · \($0)" } ?? ""
        return "Past \(level)%\(reset)"
    }

    static func fingerprint(_ lines: [String]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in lines.joined(separator: "\n").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

nonisolated(unsafe) var usageBenchAllocations = 0
nonisolated(unsafe) var usageBenchAllocatedBytes = 0

enum UsageBenchMemory {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    static let logger: Logger = { type, _, size, resized, _, _ in
        guard type & 2 != 0, pthread_main_np() != 0 else { return }
        usageBenchAllocations += 1
        usageBenchAllocatedBytes += Int(type & 4 != 0 ? resized : size)
    }

    static func counting(_ work: () -> Void) -> (allocations: Int, bytes: Int)? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        guard slot.pointee == nil else { return nil }
        usageBenchAllocations = 0
        usageBenchAllocatedBytes = 0
        slot.pointee = logger
        work()
        slot.pointee = nil
        return (usageBenchAllocations, usageBenchAllocatedBytes)
    }

    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var size = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}

struct UsageBenchStats {
    var median: Double
    var minimum: Double
    var maximum: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        median = sorted.isEmpty ? 0 : sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        minimum = sorted.first ?? 0
        maximum = sorted.last ?? 0
    }
}

@MainActor
enum UsageBoardBench {
    enum Variant: String, CaseIterable {
        case before, after

        var summary: String {
            switch self {
            case .before: "the values UsageView.content(at:) and each UsageTileView body worked out at f694430, call for call: store.readings 11 + 2 × plans times (12 with a banked-resets chip), closeWindows once and again for every tile, every tile's own paces"
            case .after: "this checkout: store.readings once, one UsageBoard, tiles from its plans"
            }
        }
    }

    struct Scenario {
        var plans: Int
        var showsAllClose: Bool

        var name: String { "\(plans) \(plans == 1 ? "plan" : "plans"), Close to a limit \(state)" }
        var state: String { showsAllClose ? "expanded" : "collapsed" }
    }

    struct Sample {
        var cpuMs: Double
        var wallMedianMs: Double
        var footprintStartKB: Double
        var footprintPeakKB: Double
        var maxRSSKB: Double
        var allocations: Double?
        var allocatedKB: Double?
        var fingerprint: String
    }

    static let planCounts = [1, 4, 19]

    static func evaluation(_ variant: Variant, store: UsageBenchStore, showsAllClose: Bool, order: [String]) -> (Date) -> UsageBenchScreen {
        switch variant {
        case .before:
            let view = UsageBenchBefore(store: store, showsAllClose: showsAllClose, order: order, clock: UsageBenchFixture.now)
            return { view.screen(at: $0) }
        case .after:
            let view = UsageBenchAfter(store: store, showsAllClose: showsAllClose, order: order, clock: UsageBenchFixture.now)
            return { view.screen(at: $0) }
        }
    }

    static func setting(_ name: String, default value: Int, least: Int) -> Int {
        max(least, Int(ProcessInfo.processInfo.environment[name] ?? "") ?? value)
    }

    static func cell(_ variant: Variant, _ scenario: Scenario) {
        let now = UsageBenchFixture.now
        let store = UsageBenchStore(UsageBenchFixture.items(plans: scenario.plans), now: now)
        let order = store.readings.map(\.id)
        let evaluate = evaluation(variant, store: store, showsAllClose: scenario.showsAllClose, order: order)
        let expected = evaluate(now)
        let fingerprint = UsageBenchText.fingerprint(UsageBenchText.lines(expected, readings: store.readings, showsAllClose: scenario.showsAllClose, date: now))
        let checksum = expected.checksum
        let evaluations = setting("BENCH_EVALS", default: 300, least: 20)
        let counted = setting("BENCH_ALLOC_EVALS", default: 20, least: 1)
        for _ in 0..<setting("BENCH_WARMUP", default: 30, least: 1) {
            precondition(evaluate(now).checksum == checksum)
        }
        var walls: [Double] = []
        walls.reserveCapacity(evaluations)
        let start = UsageBenchMemory.footprint()
        let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        for _ in 0..<evaluations {
            let began = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            let screen = evaluate(now)
            let ended = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
            precondition(screen.checksum == checksum, "\(variant.rawValue) changed its answer between evaluations")
            walls.append(Double(ended - began) / 1_000_000)
        }
        let cpuEnd = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let end = UsageBenchMemory.footprint()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let allocations = UsageBenchMemory.counting {
            for _ in 0..<counted {
                precondition(evaluate(now).checksum == checksum)
            }
        }
        precondition(evaluate(now) == expected, "\(variant.rawValue) changed its answer after timing")
        let fields: [String] = [
            "cell", variant.rawValue, "\(scenario.plans)", scenario.state,
            "\(Double(cpuEnd - cpuStart) / 1_000_000 / Double(evaluations))",
            "\(UsageBenchStats(walls).median)",
            "\(Double(start.now) / 1024)", "\(Double(end.peak) / 1024)", "\(Double(usage.ru_maxrss) / 1024)",
            allocations.map { "\(Double($0.allocations) / Double(counted))" } ?? "-",
            allocations.map { "\(Double($0.bytes) / 1024 / Double(counted))" } ?? "-",
            fingerprint,
        ]
        print(fields.joined(separator: "\t"))
    }

    static func child(_ variant: Variant, _ scenario: Scenario) -> Sample {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--cell", variant.rawValue, "\(scenario.plans)", scenario.state]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            print("Couldn't start \(variant.rawValue) for \(scenario.name): \(error.localizedDescription)")
            exit(1)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("cell\t") }
        let fields = line.map { $0.split(separator: "\t").map(String.init) } ?? []
        guard process.terminationStatus == 0, fields.count == 12, let cpu = Double(fields[4]), let wall = Double(fields[5]),
              let start = Double(fields[6]), let peak = Double(fields[7]), let rss = Double(fields[8])
        else {
            print("\(variant.rawValue) for \(scenario.name) didn't finish (status \(process.terminationStatus))")
            exit(1)
        }
        return Sample(cpuMs: cpu, wallMedianMs: wall, footprintStartKB: start, footprintPeakKB: peak, maxRSSKB: rss,
                      allocations: Double(fields[9]), allocatedKB: Double(fields[10]), fingerprint: fields[11])
    }

    static func format(_ value: Double, _ digits: Int = 3) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func csvField(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func check(_ scenario: Scenario) -> String {
        let now = UsageBenchFixture.now
        let items = UsageBenchFixture.items(plans: scenario.plans)
        let store = UsageBenchStore(items, now: now)
        let readings = store.readings
        let order = readings.map(\.id)
        let before = evaluation(.before, store: store, showsAllClose: scenario.showsAllClose, order: order)(now)
        let after = evaluation(.after, store: store, showsAllClose: scenario.showsAllClose, order: order)(now)
        let beforeLines = UsageBenchText.lines(before, readings: readings, showsAllClose: scenario.showsAllClose, date: now)
        let afterLines = UsageBenchText.lines(after, readings: readings, showsAllClose: scenario.showsAllClose, date: now)
        guard before == after, beforeLines == afterLines else {
            print("MISMATCH: after differs from before in \(scenario.name)")
            for (index, pair) in zip(beforeLines, afterLines).enumerated() where pair.0 != pair.1 {
                print("line \(index + 1) before: \(pair.0)")
                print("line \(index + 1)  after: \(pair.1)")
            }
            exit(1)
        }
        let windows = readings.flatMap(\.provider.windows)
        let stale = readings.filter { !$0.provider.isLive }.count
        let elapsed = windows.filter { $0.isAwaitingReading(at: now) }.count
        let shown = min(before.close.count, scenario.showsAllClose ? before.close.count : UsageTiles.closeRowLimit)
        if scenario.plans > 1 {
            precondition(before.close.count > UsageTiles.closeRowLimit, "\(scenario.name) needs more rows than Close to a limit shows collapsed")
            precondition(stale > 0 && stale < readings.count && elapsed > 0, "\(scenario.name) needs stale and live readings and an elapsed reset")
        }
        let fingerprint = UsageBenchText.fingerprint(beforeLines)
        print("")
        print("## \(scenario.name)")
        print("readings \(readings.count) (\(stale) stale), windows \(windows.count) (\(elapsed) past their reset, \(windows.filter { $0.pace != nil }.count) with a measured run-out), "
            + "history: \(readings.reduce(0) { $0 + $1.history.count }) weeks, \(readings.reduce(0) { $0 + $1.history.values.reduce(0) { $0 + $1.points.count } }) hourly points, "
            + "origins \(Set(readings.map(\.origin)).count)")
        print("Close to a limit: \(before.close.count) rows, \(shown) shown; tiles with a window among the rows shown: \(tilesWarned(readings, close: before.close, shown: shown)); "
            + "tiles in grid order: \(before.tiles.map(\.id).joined(separator: ","))")
        print("equality: before and after give equal values (every close row, tile, pace, flag, ID and the subtitle) and the same \(beforeLines.count) lines of text, FNV-1a \(fingerprint)")
        return fingerprint
    }

    static func tilesWarned(_ readings: [UsageBenchStore.Reading], close: [CloseWindow], shown: Int) -> Int {
        Set(close.prefix(shown).map(\.provider.id)).intersection(readings.map(\.id)).count
    }

    static func report(_ scenario: Scenario, fingerprint: String, runs: Int, raw: inout [String]) {
        var samples: [Variant: [Sample]] = [.before: [], .after: []]
        var wins = 0
        for run in 0..<runs {
            var taken: [Variant: Sample] = [:]
            for variant in run % 2 == 0 ? [Variant.before, .after] : [.after, .before] {
                let sample = child(variant, scenario)
                guard sample.fingerprint == fingerprint else {
                    print("MISMATCH: \(variant.rawValue) gave other text in its own process for \(scenario.name)")
                    exit(1)
                }
                taken[variant] = sample
                samples[variant]!.append(sample)
                raw.append([
                    "\(scenario.plans)", scenario.state, variant.rawValue, "\(run)", "\(sample.cpuMs)", "\(sample.wallMedianMs)",
                    "\(sample.footprintStartKB)", "\(sample.footprintPeakKB)", "\(sample.maxRSSKB)",
                    sample.allocations.map { "\($0)" } ?? "", sample.allocatedKB.map { "\($0)" } ?? "", sample.fingerprint,
                ].map(csvField).joined(separator: ","))
            }
            if taken[.after]!.cpuMs < taken[.before]!.cpuMs { wins += 1 }
        }
        print("| series | CPU ms per evaluation, median across \(runs) | min | max | wall ms, median | allocations per evaluation | KB allocated per evaluation | footprint at loop start, MB | peak footprint, MB | max RSS, MB |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        var medians: [Variant: (cpu: Double, allocations: Double?, bytes: Double?)] = [:]
        for variant in Variant.allCases {
            let series = samples[variant]!
            let cpu = UsageBenchStats(series.map(\.cpuMs))
            let allocations = series.compactMap(\.allocations)
            let bytes = series.compactMap(\.allocatedKB)
            medians[variant] = (cpu.median, allocations.isEmpty ? nil : UsageBenchStats(allocations).median, bytes.isEmpty ? nil : UsageBenchStats(bytes).median)
            print("| \(variant.rawValue) | \(format(cpu.median, 4)) | \(format(cpu.minimum, 4)) | \(format(cpu.maximum, 4)) | \(format(UsageBenchStats(series.map(\.wallMedianMs)).median, 4)) | "
                + "\(medians[variant]!.allocations.map { format($0, 1) } ?? "not counted") | \(medians[variant]!.bytes.map { format($0, 1) } ?? "not counted") | "
                + "\(format(UsageBenchStats(series.map(\.footprintStartKB)).median / 1024, 2)) | \(format(UsageBenchStats(series.map(\.footprintPeakKB)).median / 1024, 2)) | "
                + "\(format(UsageBenchStats(series.map(\.maxRSSKB)).median / 1024, 2)) |")
        }
        let before = medians[.before]!, after = medians[.after]!
        var summary = "CPU: before ÷ after \(format(before.cpu / after.cpu, 2))×, after lower in \(wins) of \(runs) paired processes"
        if let old = before.allocations, let new = after.allocations, new > 0, let oldBytes = before.bytes, let newBytes = after.bytes, newBytes > 0 {
            summary += "; allocations \(format(old / new, 2))×, bytes \(format(oldBytes / newBytes, 2))×"
        }
        print(summary)
    }

    static func run() {
        let arguments = CommandLine.arguments
        if arguments.count == 5, arguments[1] == "--cell", let variant = Variant(rawValue: arguments[2]), let plans = Int(arguments[3]), planCounts.contains(plans) {
            cell(variant, Scenario(plans: plans, showsAllClose: arguments[4] == "expanded"))
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let runs = setting("BENCH_RUNS", default: 7, least: 1)
        var raw = ["plans,close_to_a_limit,series,run,cpu_ms_per_evaluation,wall_median_ms,footprint_start_kb,footprint_peak_kb,max_rss_kb,allocations_per_evaluation,allocated_kb_per_evaluation,text_fnv1a"]
        print("Tokenroom iPhone Usage tab: what one evaluation of UsageView.content(at:) and its tiles works out")
        print("commit: \(environment["BENCH_COMMIT"] ?? "unknown")")
        print("build: \(environment["BENCH_BUILD"] ?? "unknown")")
        print("host: \(environment["BENCH_HOST"] ?? "unknown"), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("processes: every series of every scenario runs in processes of its own, \(runs) each, before and after alternating which goes first; "
            + "each process builds the fixture, warms up \(setting("BENCH_WARMUP", default: 30, least: 1)) evaluations, times \(setting("BENCH_EVALS", default: 300, least: 20)), "
            + "then counts allocations over \(setting("BENCH_ALLOC_EVALS", default: 20, least: 1)) more")
        print("CPU: the process's CPU time (CLOCK_PROCESS_CPUTIME_ID) across the timed evaluations, divided by their number; wall: the median evaluation in that process (CLOCK_MONOTONIC_RAW)")
        print("memory: allocations and bytes asked of malloc on the main thread per evaluation (malloc_logger, after timing, so it doesn't slow the timed loop); "
            + "peak footprint and max RSS are the process's whole life, fixture included, read when the timed loop ends")
        print("one evaluation: content(at:) once and every tile's body once, as on the minute's tick or a new reading, when the date or the reading each tile is given has changed")
        print("this is a Mac running the shared code the iPhone's Usage tab calls, not an iPhone and not SwiftUI: TokenroomMobile doesn't compile for macOS")
        print("copied into the bench from TokenroomMobile: MobileStore.Reading and MobileStore.readings (an @Observable main-actor store, as there), "
            + "and the order of calls in UsageView.content(at:) and UsageTileView.body, at f694430 for before and at this checkout for after")
        print("after calls the shipped UsageBoard, UsageTiles, UsageRanking, Pace and ReadingFreshness; before calls the same shipped code and its own copy of closeWindows as it was at f694430")
        print("not timed: SwiftUI's diffing, layout and drawing, VoiceOver, Live Activities, the text below (built from the timed values by the bench's copy of the views' wording), any network, disk or iCloud; "
            + "fixtures are synthetic; banked resets are counted at the fixture's date, where the app counts them at the clock's")
        for variant in Variant.allCases {
            print("series \(variant.rawValue): \(variant.summary)")
        }
        for plans in planCounts {
            for showsAllClose in [false, true] {
                let scenario = Scenario(plans: plans, showsAllClose: showsAllClose)
                let fingerprint = check(scenario)
                report(scenario, fingerprint: fingerprint, runs: runs, raw: &raw)
            }
        }
        if let path = environment["BENCH_RAW"], !path.isEmpty {
            do {
                try raw.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                print("\nraw samples: \(path)")
            } catch {
                print("\nraw samples not written: \(error.localizedDescription)")
            }
        }
    }
}

@main
struct UsageBoardBenchMain {
    @MainActor
    static func main() {
        UsageBoardBench.run()
    }
}
