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
        result.items = UsageRanking.sorted(result.items, provider: \.provider, now: date, windowPace: { item, window in
            UsageRanking.pace(for: window, isStale: !item.provider.isLive, history: item.history[window.id], now: date)
        })
        return result
    }

    /// Membership comes from the newest envelope; older envelopes may advance retained readings,
    /// but cannot reintroduce removed providers or remove newly added ones.
    func mergingUpdate(_ incoming: ReadingCache) -> ReadingCache {
        guard !isSample, !incoming.isSample else { return incoming }
        if let reconciled = reconcilingSourceUpdate(incoming) { return reconciled }
        let newer = incoming.savedAt >= savedAt ? incoming : self
        let older = incoming.savedAt >= savedAt ? self : incoming
        let other = Dictionary(older.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = newer
        result.items = newer.items.map { item in
            guard let candidate = other[item.id] else { return item }
            let currentTime = item.provider.checkedAt ?? item.provider.fetchedAt ?? newer.savedAt
            let candidateTime = candidate.provider.checkedAt ?? candidate.provider.fetchedAt ?? older.savedAt
            return candidateTime > currentTime ? candidate : item
        }
        return result
    }

    func staleCount(at date: Date) -> Int {
        presented(at: date).items.filter { !$0.provider.isLive }.count
    }

    /// Predictable Watch reset boundaries used to request a Smart Stack refresh when the app
    /// gets a background turn. WidgetKit may still defer the actual redraw.
    func resetDates(after start: Date, through end: Date) -> [Date] {
        Set(items.flatMap { $0.provider.windows.compactMap(\.resetsAt) }
            .filter { $0 > start && $0 <= end }).sorted()
    }

    /// Timeline entries age readings even if WidgetKit postpones the next network reload.
    func presentationDates(after now: Date, until horizon: Date) -> [Date] {
        let dates = items.flatMap { item -> [Date] in
            let checked = item.provider.checkedAt ?? item.provider.fetchedAt ?? savedAt
            return item.provider.windows.compactMap(\.resetsAt) + [
                checked.addingTimeInterval(ReadingFreshness.staleAfter + 1),
                checked.addingTimeInterval(ReadingFreshness.expiresAfter + 1)
            ]
        }
        return Set(dates.filter { $0 > now && $0 < horizon }).sorted()
    }
}

extension ReadingCache.Item {
    /// The Watch's line saying where a reading came from. The Watch never collects, so the
    /// iPhone's readings are "your iPhone" there, never "This iPhone".
    var watchOriginLine: String {
        source == SampleData.sourceLabel ? "Sample data" : resolvedOrigin.watchPhrase
    }
}

/// A durable local gate shared by the Watch app and complications. The gate stays closed if
/// clearing or replacing the disk cache fails, and opens only after a validated read is saved.
enum WatchCacheAccess {
    static let cutoffKey = "watchSignedOutAt"
    static let validationKey = "watchAccountNeedsValidation"

    static func invalidate(in defaults: UserDefaults, at date: Date) {
        defaults.set(true, forKey: validationKey)
        defaults.set(date, forKey: cutoffKey)
    }

    /// Whether something read later (iCloud, the iPhone, the saved cache) may replace `current`.
    /// A launch showing sample readings (`-sampleMode YES`) keeps them for the whole launch, so a
    /// simulator without an iCloud account doesn't swap them for an empty account's.
    static func mayReplace(_ current: ReadingCache?, showsSample: Bool) -> Bool {
        !(showsSample && current?.isSample == true)
    }

    static func load(at url: URL?, defaults: UserDefaults) -> ReadingCache? {
        guard !defaults.bool(forKey: validationKey), let cache = url.flatMap(ReadingCache.load) else { return nil }
        guard (defaults.object(forKey: cutoffKey) as? Date).map({ cache.savedAt > $0 }) != false else { return nil }
        return cache
    }

    static func saveValidated(_ cache: ReadingCache, at url: URL?, defaults: UserDefaults, cutoff: Date?) throws {
        // Account changes during a read invalidate that result, even if the new account is available.
        guard (defaults.object(forKey: cutoffKey) as? Date) == cutoff,
              cutoff.map({ cache.savedAt > $0 }) != false, let url else { return }
        try cache.save(to: url)
        guard (defaults.object(forKey: cutoffKey) as? Date) == cutoff else { return }
        defaults.set(false, forKey: validationKey)
    }
}

/// Reconcile a complication's validated write with an app process that stayed alive. A failed
/// iCloud read must not leave its memory empty while a usable, gated reading exists on disk.
enum WatchCacheRecovery {
    static func recover(_ memory: ReadingCache?, at url: URL?, defaults: UserDefaults) -> ReadingCache? {
        guard let saved = WatchCacheAccess.load(at: url, defaults: defaults) else { return memory }
        return memory?.mergingUpdate(saved) ?? saved
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
