import Foundation

enum ReadingFreshness {
    static let staleAfter: TimeInterval = 3600
    static let expiresAfter: TimeInterval = 7 * 86_400

    static func present(_ provider: RelayProvider, fallback: Date, now: Date) -> RelayProvider? {
        let checked = provider.checkedAt ?? provider.fetchedAt ?? fallback
        guard now.timeIntervalSince(checked) <= expiresAfter else { return nil }
        var result = provider
        // Older payloads have only an envelope timestamp; keep it with this provider.
        if result.checkedAt == nil, result.fetchedAt == nil { result.checkedAt = checked }
        if result.isLive, now.timeIntervalSince(checked) > staleAfter {
            result.state = "stale"
            result.message = "Last successful check \(RelativeTime.ago(checked, now: now))."
        }
        return result
    }
}

extension RelayWindow {
    func isAwaitingReading(at date: Date = .now) -> Bool {
        resetsAt.map { $0 <= date } ?? false
    }
}

extension ReadingCache {
    func presented(at date: Date) -> ReadingCache {
        var result = self
        result.items = items.compactMap { item in
            guard let provider = ReadingFreshness.present(item.provider, fallback: savedAt, now: date) else { return nil }
            var item = item
            item.provider = provider
            return item
        }
        result.items = UsageRanking.sorted(result.items, provider: \.provider, now: date) { ReadingAssembler.pace(for: $0, now: date) }
        return result
    }

    /// Membership comes from the incoming cache; each retained provider keeps its newest value.
    func mergingUpdate(_ incoming: ReadingCache) -> ReadingCache {
        guard !isSample, !incoming.isSample else { return incoming }
        guard incoming.savedAt >= savedAt else { return self }
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = incoming
        result.items = incoming.items.map { item in
            guard let old = previous[item.id], let oldTime = old.provider.checkedAt ?? old.provider.fetchedAt else { return item }
            let newTime = item.provider.checkedAt ?? item.provider.fetchedAt ?? .distantPast
            return oldTime > newTime ? old : item
        }
        return result
    }

    func staleCount(at date: Date) -> Int {
        presented(at: date).items.filter { !$0.provider.isLive }.count
    }
}

/// A phone handover cannot restore readings after sign-out until iCloud is validated again.
struct WatchAccountGate {
    private(set) var validated = false
    private(set) var signedOutAt: Date?

    init(signedOutAt: Date? = nil) { self.signedOutAt = signedOutAt }
    mutating func invalidate() { validated = false }
    mutating func confirmAvailable() { validated = true }
    mutating func signOut(at date: Date) { validated = false; signedOutAt = date }
    func accepts(_ cache: ReadingCache) -> Bool {
        validated && signedOutAt.map { cache.savedAt > $0 } != false
    }
}
