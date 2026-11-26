import Foundation

enum WindowKind: String, Codable, Sendable {
    case weekly
    case session
    case daily
    case monthly
    case billingCycle
    case pool

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WindowKind(rawValue: raw) ?? .pool
    }
}

struct QuotaWindow: Equatable, Codable, Sendable, Identifiable {
    var id: String
    var kind: WindowKind
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    var windowSeconds: Double? = nil
    var startsAt: Date? = nil
    var amount: QuotaAmount? = nil
    var metered: Bool? = nil

    var isMetered: Bool {
        metered ?? true
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Equatable, Codable, Sendable {
    var provider: Provider
    var usedPercent: Double
    var resetsAt: Date?
    var fetchedAt: Date
    var primaryTitle: String
    var windows: [QuotaWindow]
    var planLabel: String? = nil
    var banked: BankedResets? = nil
    var extra: ExtraUsage? = nil
    var source: String? = nil

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    static func headlined(
        by windows: [QuotaWindow],
        provider: Provider,
        fetchedAt: Date,
        planLabel: String? = nil,
        extra: ExtraUsage? = nil
    ) throws -> QuotaSnapshot {
        guard let primary = windows.first else { throw ProviderError.parse }
        return QuotaSnapshot(
            provider: provider,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt,
            fetchedAt: fetchedAt,
            primaryTitle: primary.title,
            windows: windows,
            planLabel: planLabel,
            extra: extra
        )
    }
}

struct QuotaAmount: Equatable, Codable, Sendable {
    var used: Double? = nil
    var limit: Double? = nil
    var remaining: Double? = nil
    var unit: String
    var isBudget: Bool? = nil

    var remainingOrComputed: Double? {
        remaining ?? limit.flatMap { limit in used.map { limit - $0 } }
    }
}

struct BankedResets: Equatable, Codable, Sendable {
    var available: Int
    var expiries: [Date] = []

    func nextExpiry(after now: Date = .now) -> Date? {
        expiries.filter { $0 > now }.min()
    }

    func current(at now: Date, measuredAt: Date?) -> BankedResets? {
        let lapsed = expiries.filter { expiry in
            expiry <= now && measuredAt.map { expiry > $0 } ?? true
        }.count
        let left = max(available - lapsed, 0)
        guard left > 0 else { return nil }
        return BankedResets(available: left, expiries: expiries.filter { $0 > now })
    }
}

extension QuotaSnapshot {
    func availableBanked(at now: Date) -> BankedResets? {
        banked?.current(at: now, measuredAt: fetchedAt)
    }
}

extension RelayProvider {
    func availableBanked(at now: Date) -> BankedResets? {
        banked?.current(at: now, measuredAt: fetchedAt)
    }
}

struct ExtraUsage: Equatable, Codable, Sendable {
    var title: String
    var amount: QuotaAmount
    var isEnabled: Bool = true
}

enum ProviderError: Error, Equatable, Sendable {
    case signedOut(String)
    case expired(String)
    case notEntitled(String)
    case rateLimited(until: Date?)
    case unreachable
    case parse
}

enum ProviderStatus: Equatable, Sendable {
    case loading
    case live(QuotaSnapshot)
    case stale(QuotaSnapshot)
    case signedOut(String)
    case expired(String, cached: QuotaSnapshot?)
    case notEntitled(String)
    case rateLimited(until: Date, cached: QuotaSnapshot?)
    case unreachable(cached: QuotaSnapshot?)

    var snapshot: QuotaSnapshot? {
        switch self {
        case .live(let snapshot), .stale(let snapshot):
            snapshot
        case .unreachable(let cached), .expired(_, let cached), .rateLimited(_, let cached):
            cached
        default:
            nil
        }
    }

    var isStale: Bool {
        switch self {
        case .stale, .unreachable(cached: .some), .expired(_, cached: .some), .rateLimited(_, cached: .some):
            true
        default:
            false
        }
    }
}
