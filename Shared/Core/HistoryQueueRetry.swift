import Foundation
import Synchronization

struct HistoryQueueOutcome: Sendable {
    struct Failure: Sendable {
        let snapshot: QuotaSnapshot
        let domain: String
        let code: Int

        init(_ snapshot: QuotaSnapshot, _ error: any Error) {
            self.snapshot = snapshot
            domain = (error as NSError).domain
            code = (error as NSError).code
        }
    }

    var queued: [QuotaSnapshot] = []
    var failures: [Failure] = []

    var isComplete: Bool { failures.isEmpty }
    var isPartial: Bool { !failures.isEmpty && !queued.isEmpty }

    func retryDate(after readRetryAt: Date?, now: Date) -> Date? {
        readRetryAt ?? (isComplete ? nil : now)
    }
}

final class HistoryQueueRetry: Sendable {
    static let widgets = HistoryQueueRetry()

    private struct Slot: Hashable {
        let provider: Provider
        let hour: Date

        init(_ snapshot: QuotaSnapshot) {
            provider = snapshot.provider
            hour = UsageHistory.hourStart(snapshot.fetchedAt)
        }
    }

    private struct Pending {
        var generation: String?
        var readings: [Slot: QuotaSnapshot] = [:]
    }

    private let pending = Mutex(Pending())

    func queue(_ readings: [QuotaSnapshot], in directory: URL?, generation: String? = nil, now: Date = .now) -> HistoryQueueOutcome {
        pending.withLock { pending in
            if pending.generation != generation {
                pending = Pending(generation: generation)
            }
            let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
            var latest = pending.readings.filter { $0.key.hour >= cutoff }
            for reading in readings {
                let slot = Slot(reading)
                if let held = latest[slot], held.fetchedAt > reading.fetchedAt { continue }
                latest[slot] = reading
            }
            let outcome = HistoryStore.queue(latest.values.sorted { $0.fetchedAt < $1.fetchedAt }, in: directory, now: now)
            pending.readings = Dictionary(outcome.failures.map { (Slot($0.snapshot), $0.snapshot) }, uniquingKeysWith: { _, later in later })
            return outcome
        }
    }
}
