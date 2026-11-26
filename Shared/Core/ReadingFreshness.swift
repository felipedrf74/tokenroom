import Foundation

enum ReadingFreshness {
    static let staleAfter: TimeInterval = 3600
    static let staleLead: TimeInterval = 5 * 60
    static let expiresAfter: TimeInterval = 7 * 86_400
    static let staleMessagePrefix = "Last successful check "

    static func present(_ provider: RelayProvider, fallback: Date, now: Date) -> RelayProvider? {
        let checked = provider.checkedAt ?? provider.fetchedAt ?? fallback
        guard now.timeIntervalSince(checked) <= expiresAfter else { return nil }
        var result = provider
        if result.checkedAt == nil, result.fetchedAt == nil { result.checkedAt = checked }
        if result.isLive, now.timeIntervalSince(checked) > staleAfter {
            result.state = "stale"
            result.message = staleMessage(checked: checked, now: now)
        } else if result.state == "stale", result.message?.hasPrefix(staleMessagePrefix) == true {
            result.message = staleMessage(checked: checked, now: now)
        }
        return result
    }

    static func staleMessage(checked: Date, now: Date) -> String {
        staleMessagePrefix + RelativeTime.ago(checked, now: now) + "."
    }

    static func ordering(_ date: Date, now: Date) -> Date {
        min(date, now)
    }

    static func ownOrdering(_ date: Date, now: Date) -> Date {
        date > now ? .distantPast : date
    }
}

extension RelayWindow {
    func isAwaitingReading(at date: Date = .now) -> Bool {
        resetsAt.map { $0 <= date } ?? false
    }

    func meterUsed(at date: Date) -> Double {
        MeterLayout.shownUsed(used, isAwaitingReading: isAwaitingReading(at: date))
    }
}

extension ReadingCache {
    static let countdownTicksWithin: TimeInterval = 3_600

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

    func mergingUpdate(_ incoming: ReadingCache, now: Date = .now) -> ReadingCache {
        guard !isSample, !incoming.isSample else { return incoming }
        if let reconciled = reconcilingSourceUpdate(incoming, now: now) { return reconciled }
        let incomingIsNewer = ReadingFreshness.ordering(incoming.savedAt, now: now) >= ReadingFreshness.ordering(savedAt, now: now)
        let newer = incomingIsNewer ? incoming : self
        let older = incomingIsNewer ? self : incoming
        let other = Dictionary(older.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = newer
        result.items = newer.items.map { item in
            guard let candidate = other[item.id] else { return item }
            let currentTime = item.provider.checkedAt ?? item.provider.fetchedAt ?? newer.savedAt
            let candidateTime = candidate.provider.checkedAt ?? candidate.provider.fetchedAt ?? older.savedAt
            return ReadingFreshness.ordering(candidateTime, now: now) > ReadingFreshness.ordering(currentTime, now: now) ? candidate : item
        }
        return result
    }

    func nearsStale(at date: Date) -> Bool {
        presented(at: date).items.contains { item in
            guard item.provider.isLive, let checked = item.provider.checkedAt ?? item.provider.fetchedAt else { return false }
            return date.timeIntervalSince(checked) >= ReadingFreshness.staleAfter - ReadingFreshness.staleLead
        }
    }

    func staleCount(at date: Date) -> Int {
        presented(at: date).items.filter { !$0.provider.isLive }.count
    }

    func resetDates(after start: Date, through end: Date) -> [Date] {
        Set(items.flatMap { $0.provider.windows.compactMap(\.resetsAt) }
            .filter { $0 > start && $0 <= end }).sorted()
    }

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

    func countdownDates(after now: Date, until horizon: Date, providers: Set<String>? = nil) -> [Date] {
        let shown = items.filter { providers?.contains($0.id) ?? true }
        let dates = Self.countdownDates(for: shown.flatMap { $0.provider.windows.compactMap(\.resetsAt) }, after: now, until: horizon)
        return Set(dates.starts + dates.wording).sorted()
    }

    static func countdownDates(for resets: [Date], after now: Date, until horizon: Date) -> (starts: [Date], wording: [Date]) {
        let within = { (date: Date) in date > now && date < horizon }
        var starts = Set<Date>()
        var wording = Set<Date>()
        for reset in Set(resets) {
            starts.insert(reset.addingTimeInterval(1 - countdownTicksWithin))
            let first = max(1, Int(((reset.timeIntervalSince(horizon) / 3_600) - 0.5).rounded(.down)))
            let last = Int((reset.timeIntervalSince(now) / 3_600) - 0.5)
            guard last >= first else { continue }
            for hours in first...last where RelativeTime.remaining(hours: hours + 1) != RelativeTime.remaining(hours: hours) {
                wording.insert(reset.addingTimeInterval(1 - (Double(hours) + 0.5) * 3_600))
            }
        }
        return (starts.filter(within).sorted(), wording.filter(within).sorted())
    }

    static func countdownEntries(for rows: [Item], after now: Date, until horizon: Date, limit: Int = 24) -> [Date] {
        countdownEntries(at: [now], until: horizon, limit: limit) { _ in rows }
    }

    static func countdownEntries(at dates: [Date], until horizon: Date, limit: Int = 24, rows: (Date) -> [Item]) -> [Date] {
        var starts: [Date] = []
        var wording: [Date] = []
        var rest: [Date] = []
        for date in dates {
            let shown = rows(date)
            let lead = shown.compactMap { $0.provider.leadWindow(now: date, history: $0.history)?.resetsAt }
            let others = shown.flatMap { $0.provider.windows.compactMap(\.resetsAt) }.filter { !lead.contains($0) }
            let first = countdownDates(for: lead, after: date, until: horizon)
            let second = countdownDates(for: others, after: date, until: horizon)
            starts += first.starts
            wording += first.wording
            rest += second.starts + second.wording
        }
        var kept: [Date] = []
        for date in starts.sorted() + wording.sorted() + rest.sorted() where kept.count < limit && !kept.contains(date) {
            kept.append(date)
        }
        return kept.sorted()
    }
}

extension ReadingCache.Item {
    var watchOriginLine: String {
        source == SampleData.sourceLabel ? "Sample data" : resolvedOrigin.watchPhrase
    }
}

enum WatchCacheAccess {
    static let cutoffKey = "watchSignedOutAt"
    static let validationKey = "watchAccountNeedsValidation"
    static let signedOutKey = "watchConfirmedNoAccount"

    static func invalidate(in defaults: UserDefaults, at date: Date) {
        defaults.set(true, forKey: validationKey)
        defaults.set(date, forKey: cutoffKey)
        defaults.removeObject(forKey: signedOutKey)
    }

    @discardableResult
    static func confirmNoAccount(in defaults: UserDefaults, at date: Date) -> Bool {
        if isStillSignedOut(in: defaults) { return false }
        invalidate(in: defaults, at: date)
        defaults.set(true, forKey: signedOutKey)
        return true
    }

    static func isStillSignedOut(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: signedOutKey) && defaults.object(forKey: cutoffKey) is Date
    }

    static func noteAccountAvailable(in defaults: UserDefaults) {
        defaults.removeObject(forKey: signedOutKey)
    }

    static func note(_ check: RelayAccountCheck, in defaults: UserDefaults) {
        if check == .available { noteAccountAvailable(in: defaults) }
    }

    static func mayReplace(_ current: ReadingCache?, showsSample: Bool) -> Bool {
        !(showsSample && current?.isSample == true)
    }

    static func load(at url: URL?, defaults: UserDefaults) -> ReadingCache? {
        guard !defaults.bool(forKey: validationKey), let cache = url.flatMap(ReadingCache.load) else { return nil }
        guard (defaults.object(forKey: cutoffKey) as? Date).map({ cache.savedAt > $0 }) != false else { return nil }
        return cache
    }

    static func saveValidated(_ cache: ReadingCache, at url: URL?, defaults: UserDefaults, cutoff: Date?) throws {
        guard (defaults.object(forKey: cutoffKey) as? Date) == cutoff,
              cutoff.map({ cache.savedAt > $0 }) != false, let url else { return }
        try cache.save(to: url)
        guard (defaults.object(forKey: cutoffKey) as? Date) == cutoff else { return }
        defaults.set(false, forKey: validationKey)
    }
}

enum WatchCacheRecovery {
    static func recover(_ memory: ReadingCache?, at url: URL?, defaults: UserDefaults) -> ReadingCache? {
        guard let saved = WatchCacheAccess.load(at: url, defaults: defaults) else { return memory }
        return memory?.mergingUpdate(saved) ?? saved
    }
}

struct WatchAccountGate {
    private(set) var validated = false
    private(set) var signedOutAt: Date?
    private(set) var account: WatchAccountKnowledge = .unknown

    init(signedOutAt: Date? = nil) { self.signedOutAt = signedOutAt }
    mutating func invalidate() { validated = false; account = .unknown }
    mutating func confirmAvailable() { validated = true; account = .available }
    mutating func signOut(at date: Date) { validated = false; account = .unknown; signedOutAt = date }
    mutating func note(_ knowledge: WatchAccountKnowledge) {
        guard !validated || knowledge == .noAccount else { return }
        account = knowledge
    }

    func decision(for cache: ReadingCache) -> WatchHandoffAcceptance.Decision {
        WatchHandoffAcceptance.decide(cache, validated: validated, account: account, signedOutAt: signedOutAt)
    }

    func accepts(_ cache: ReadingCache) -> Bool {
        decision(for: cache) == .apply
    }
}
