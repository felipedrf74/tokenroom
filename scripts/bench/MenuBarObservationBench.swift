import AppKit
import Foundation
import Observation

@MainActor
final class LegacyMenuObservation {
    private let read: () -> MenuBarReading
    private let apply: (MenuBarReading) -> Void
    private var renderTask: Task<Void, Never>?

    init(read: @escaping () -> MenuBarReading, apply: @escaping (MenuBarReading) -> Void) {
        self.read = read
        self.apply = apply
    }

    func start() {
        render()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = read()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRender()
                self?.observe()
            }
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            render()
        }
    }

    private func render() {
        apply(read())
    }
}

@MainActor
final class MenuBarTally {
    var reads = 0
    var readNanos: UInt64 = 0
    var applied: [(at: UInt64, reading: MenuBarReading)] = []
}

@main
@MainActor
enum MenuBarObservationBench {
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func makeStore() -> (QuotaStore, cleanup: () -> Void) {
        let moment = Date()
        let samples = SampleData.snapshots(now: moment)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomMenuBench-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var weeks: [String: UsageHistory] = [:]
        for snapshot in samples {
            for (window, week) in SampleData.history(for: snapshot, now: moment) {
                weeks[RelayHistory.key(provider: snapshot.provider.rawValue, window: window)] = week
            }
        }
        if let data = try? RelayEnvelope.encoder.encode(weeks) {
            try? data.write(to: scratch.appendingPathComponent(HistoryStore.fileName))
        }
        let suite = "TokenroomMenuBench-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        for provider in Provider.allCases {
            settings.setEnabled(provider, samples.contains { $0.provider == provider })
        }
        settings.menuStyle = .percents
        let store = QuotaStore(settings: settings, clients: [], cache: SnapshotCache(directory: scratch), relay: nil, news: nil)
        for snapshot in samples {
            store.statuses[snapshot.provider] = .live(snapshot)
            store.checkedAt[snapshot.provider] = moment
        }
        store.ageReadings(at: moment)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        })
    }

    static func bumped(_ snapshot: QuotaSnapshot, at date: Date) -> QuotaSnapshot {
        var next = snapshot
        next.fetchedAt = date
        for index in next.windows.indices where next.windows[index].isMetered {
            next.windows[index].usedPercent = min(99, next.windows[index].usedPercent + 1)
        }
        return next
    }

    static func run(batched: Bool, spacing: UInt64, store: QuotaStore) async -> String {
        let tally = MenuBarTally()
        let read: () -> MenuBarReading = {
            let began = now()
            let reading = MenuBarReading(store)
            tally.readNanos += now() - began
            tally.reads += 1
            return reading
        }
        let apply: (MenuBarReading) -> Void = { tally.applied.append((now(), $0)) }
        var legacy: LegacyMenuObservation?
        var batch: BatchedObservation<MenuBarReading>?
        if batched {
            batch = BatchedObservation(read: read, apply: apply)
            batch?.start()
        } else {
            legacy = LegacyMenuObservation(read: read, apply: apply)
            legacy?.start()
        }
        try? await Task.sleep(for: .milliseconds(150))
        let before = (reads: tally.reads, nanos: tally.readNanos, applied: tally.applied.count)
        let initial = MenuBarReading(store)
        let providers = Provider.allCases.filter { store.statuses[$0]?.snapshot != nil && store.settings.isEnabled($0) }
        let first = now()
        var last = first
        for provider in providers {
            guard let snapshot = store.statuses[provider]?.snapshot else { continue }
            let date = Date()
            store.statuses[provider] = .live(bumped(snapshot, at: date))
            store.checkedAt[provider] = date
            last = now()
            await Task.yield()
            store.ageReadings(at: Date())
            await Task.yield()
            if spacing > 0 { try? await Task.sleep(nanoseconds: spacing) }
        }
        try? await Task.sleep(for: .milliseconds(400))
        let final = MenuBarReading(store)
        let after = tally.applied.dropFirst(before.applied)
        let firstShown = after.first { $0.reading != initial }?.at
        let finalShown = after.first { $0.reading == final }?.at
        func ms(_ value: UInt64?, since: UInt64) -> String {
            guard let value else { return "never" }
            return String(format: "%.1f", (Double(value) - Double(since)) / 1_000_000)
        }
        _ = (legacy, batch)
        return [
            batched ? "batched" : "legacy",
            "\(providers.count)",
            String(format: "%.0f", Double(spacing) / 1_000_000),
            String(format: "%.1f", Double(last - first) / 1_000_000),
            "\(tally.reads - before.reads)",
            String(format: "%.3f", Double(tally.readNanos - before.nanos) / 1_000_000),
            "\(after.count)",
            ms(firstShown, since: first),
            ms(finalShown, since: last),
        ].joined(separator: ",")
    }

    static func main() async {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        var costs: [UInt64] = []
        for _ in 0..<500 {
            let began = now()
            _ = MenuBarReading(store)
            costs.append(now() - began)
        }
        costs.sort()
        print("one reading of the menu bar (\(MenuBarReading(store).meters.count) meters): median \(String(format: "%.1f", Double(costs[costs.count / 2]) / 1000)) us, p90 \(String(format: "%.1f", Double(costs[costs.count * 9 / 10]) / 1000)) us")
        print("observer,providers,spacing_ms,burst_ms,readings,reading_ms,applied,first_shown_after_first_change_ms,last_shown_after_last_change_ms")
        let rounds = Int(ProcessInfo.processInfo.environment["BENCH_ROUNDS"] ?? "5") ?? 5
        for spacing in [UInt64(0), 2_000_000, 10_000_000, 25_000_000, 60_000_000] {
            for _ in 0..<rounds {
                for batched in [false, true] {
                    print(await run(batched: batched, spacing: spacing, store: store))
                }
            }
        }
    }
}
