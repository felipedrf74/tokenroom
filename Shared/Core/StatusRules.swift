import Foundation

extension ProviderStatus {
    static let expiredGrace: TimeInterval = 24 * 3600

    static func failure(_ error: ProviderError, cached: QuotaSnapshot?, lastChecked: Date?, now: Date) -> ProviderStatus {
        if error.isTransient, let cached, let checked = lastChecked ?? Optional(cached.fetchedAt),
           (0...ReadingFreshness.staleAfter).contains(now.timeIntervalSince(checked)) {
            return .live(cached)
        }
        switch error {
        case .signedOut(let hint):
            return .signedOut(hint)
        case .notEntitled(let hint):
            return .notEntitled(hint)
        case .expired(let hint):
            let checked = lastChecked ?? cached?.fetchedAt
            let recent = checked.map { now.timeIntervalSince($0) < expiredGrace } ?? false
            return .expired(hint, cached: recent ? cached : nil)
        case .rateLimited(let until):
            return .rateLimited(until: clampedRetry(until, now: now), cached: cached)
        case .unreachable, .parse:
            return cached.map(ProviderStatus.stale) ?? .unreachable(cached: nil)
        }
    }

    static func retryDate(after error: ProviderError, now: Date) -> Date? {
        guard case .rateLimited(let until) = error else { return nil }
        return clampedRetry(until, now: now)
    }

    static func clampedRetry(_ until: Date?, now: Date) -> Date {
        let wait = until.map { $0.timeIntervalSince(now) } ?? TokenroomHTTP.defaultRetryAfter
        return now.addingTimeInterval(min(max(wait, 60), longestRetry))
    }

    static let longestRetry: TimeInterval = 6 * 60 * 60

    var isDisconnected: Bool {
        switch self {
        case .signedOut, .notEntitled, .expired(_, nil), .unreachable(nil):
            true
        default:
            false
        }
    }
}

extension ProviderError {
    var isTransient: Bool {
        switch self {
        case .rateLimited, .unreachable, .parse: true
        case .signedOut, .expired, .notEntitled: false
        }
    }

    var logClass: String {
        switch self {
        case .signedOut: "signedOut"
        case .expired: "expired"
        case .notEntitled: "notEntitled"
        case .rateLimited: "rateLimited"
        case .unreachable: "unreachable"
        case .parse: "parse"
        }
    }
}

extension RelayProvider {
    init(provider: Provider, status: ProviderStatus, checkedAt: Date?) {
        let snapshot = status.snapshot
        self.init(
            id: provider.rawValue,
            name: provider.displayName,
            shortName: provider.shortName,
            monogram: provider.monogram,
            tint: provider.tintHex,
            state: status.relayState,
            message: status.relayMessage(for: provider),
            checkedAt: checkedAt,
            fetchedAt: snapshot?.fetchedAt,
            plan: snapshot?.planLabel,
            primaryWindowID: snapshot?.windows.first?.id,
            windows: snapshot?.windows.map(RelayWindow.init) ?? [],
            banked: snapshot?.banked,
            extra: snapshot?.extra,
            category: provider.category.rawValue
        )
    }

    var isLive: Bool {
        state == "live"
    }

    var isAwaitingFirstReading: Bool {
        state == "loading" && windows.isEmpty
    }

    var isDisconnected: Bool {
        switch state {
        case "signedOut", "notEntitled":
            true
        case "expired", "unreachable", "loading":
            windows.isEmpty
        default:
            false
        }
    }
}

extension RelayProvider {
    static let followHorizon: TimeInterval = 8 * 3600

    func windowToFollow(preferring preferred: String? = nil, now: Date = .now) -> RelayWindow? {
        let soon = windows.filter { window in
            guard window.isMetered, let resetsAt = window.resetsAt else { return false }
            return resetsAt > now && resetsAt.timeIntervalSince(now) <= Self.followHorizon
        }
        if let preferred, let shown = soon.first(where: { $0.id == preferred }) {
            return shown
        }
        return soon.first { $0.windowKind == .session }
            ?? soon.filter { $0.used >= 80 }.max { $0.used < $1.used }
    }
}

extension ReadingCache {
    func mostUrgentToFollow(at now: Date) -> (provider: RelayProvider, window: RelayWindow)? {
        guard !isSample else { return nil }
        for item in presented(at: now).items {
            if let window = item.provider.windowToFollow(now: now) {
                return (item.provider, window)
            }
        }
        return nil
    }
}

extension RelayWindow {
    init(_ window: QuotaWindow) {
        self.init(
            id: window.id,
            kind: window.kind.rawValue,
            title: window.title,
            used: window.usedPercent,
            resetsAt: window.resetsAt,
            periodSec: window.windowSeconds,
            startsAt: window.startsAt,
            amount: window.amount,
            metered: window.metered
        )
    }

    var windowKind: WindowKind {
        WindowKind(rawValue: kind) ?? .pool
    }

    var isMetered: Bool {
        metered ?? true
    }
}

extension ProviderStatus {
    var relayState: String {
        switch self {
        case .loading: "loading"
        case .live: "live"
        case .stale: "stale"
        case .signedOut: "signedOut"
        case .expired: "expired"
        case .notEntitled: "notEntitled"
        case .rateLimited: "rateLimited"
        case .unreachable: "unreachable"
        }
    }

    func relayMessage(for provider: Provider) -> String? {
        switch self {
        case .signedOut(let hint), .expired(let hint, _), .notEntitled(let hint):
            hint
        case .rateLimited(let until, _):
            "Couldn't refresh. \(provider.displayName) asked to wait until \(until.formatted(date: .omitted, time: .shortened))."
        case .unreachable:
            "Couldn't reach \(provider.displayName)."
        case .loading, .live, .stale:
            nil
        }
    }
}
