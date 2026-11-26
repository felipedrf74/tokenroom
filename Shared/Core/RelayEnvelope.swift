import Foundation

struct RelayEnvelope: Codable, Equatable, Sendable {
    static let version = 1

    var v: Int = RelayEnvelope.version
    var minReader: Int = 1
    var producer: String
    var appVersion: String
    var checkedAt: Date
    var providers: [RelayProvider]

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RelayEnvelope {
        try decoder.decode(RelayEnvelope.self, from: data)
    }

    var isReadable: Bool {
        minReader <= Self.version
    }

    static func read(_ data: Data) -> (envelope: RelayEnvelope?, needsNewerApp: Bool) {
        if let decoded = try? decode(data) {
            return decoded.isReadable ? (decoded, false) : (nil, true)
        }
        struct Gate: Decodable { var minReader: Int? }
        let minReader = (try? decoder.decode(Gate.self, from: data))?.minReader ?? 1
        return (nil, minReader > version)
    }

    var materialHash: Int {
        var hasher = Hasher()
        for provider in providers {
            hasher.combine(provider.id)
            hasher.combine(provider.state)
            hasher.combine(provider.plan)
            hasher.combine(provider.banked?.available)
            hasher.combine(provider.banked?.expiries.first)
            hasher.combine(provider.extra?.isEnabled)
            Self.combine(provider.extra?.amount, into: &hasher)
            for window in provider.windows {
                hasher.combine(window.id)
                hasher.combine(Int(window.used.rounded()))
                hasher.combine(window.resetsAt.map { Int(($0.timeIntervalSince1970 / 60).rounded()) })
                Self.combine(window.amount, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    static let runOutStep: TimeInterval = 3_600

    var runOuts: [String: Date] {
        var runOuts: [String: Date] = [:]
        for provider in providers {
            for window in provider.windows {
                guard let pace = window.pace else { continue }
                let end = window.resetsAt ?? .distantFuture
                runOuts[provider.id + "/" + window.id] = min(pace.runsOutAt ?? end, end)
            }
        }
        return runOuts
    }

    private static func combine(_ amount: QuotaAmount?, into hasher: inout Hasher) {
        hasher.combine(amount?.unit)
        guard let amount else { return }
        let scale: Double = amount.unit == "usd" || amount.unit == "cny" ? 100 : 10
        for value in [amount.used, amount.limit, amount.remaining] {
            hasher.combine(value.map { ($0 * scale).rounded() })
        }
    }
}

struct RelayProvider: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var shortName: String
    var monogram: String
    var tint: String
    var state: String
    var message: String?
    var checkedAt: Date?
    var fetchedAt: Date?
    var plan: String?
    var primaryWindowID: String?
    var windows: [RelayWindow]
    var banked: BankedResets? = nil
    var extra: ExtraUsage? = nil
    var category: String? = nil

    var primaryWindow: RelayWindow? {
        windows.first { $0.id == primaryWindowID } ?? windows.first
    }
}

struct RelayWindow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var title: String
    var used: Double
    var resetsAt: Date?
    var periodSec: Double? = nil
    var startsAt: Date? = nil
    var amount: QuotaAmount? = nil
    var metered: Bool? = nil
    var pace: RelayPace? = nil
}

struct RelayPace: Codable, Equatable, Sendable {
    var runsOutAt: Date?
}
