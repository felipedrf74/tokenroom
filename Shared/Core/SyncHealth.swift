import Foundation
import os

struct SyncHealth: Codable, Equatable, Sendable {
    static let defaultsKey = "syncHealth"

    enum Channel: String, Codable, CaseIterable, Sendable {
        case cloudRead
        case handoffSend
        case handoffReceive
        case phoneReply
        case backgroundRefresh
        case cloudWrite
    }

    enum Code: String, Codable, CaseIterable, Sendable {
        case ok
        case noAccount
        case failed
        case timedOut
        case unavailable
        case held
        case dropped
        case trimmed
        case tooLarge
        case notPaired
        case notInstalled
        case inactive
    }

    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        var code: Code
        var lastOK: Date?
    }

    var entries: [String: Entry] = [:]

    func entry(_ channel: Channel) -> Entry? {
        entries[channel.rawValue]
    }

    mutating func record(_ channel: Channel, _ code: Code, at date: Date) {
        let wentWell = code == .ok || code == .trimmed
        let lastOK = wentWell ? date : entries[channel.rawValue]?.lastOK
        entries[channel.rawValue] = Entry(at: date, code: code, lastOK: lastOK)
    }

    static func load(from defaults: UserDefaults) -> SyncHealth {
        defaults.data(forKey: defaultsKey).flatMap { try? RelayEnvelope.decoder.decode(SyncHealth.self, from: $0) } ?? SyncHealth()
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? RelayEnvelope.encoder.encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

enum SyncHealthLog {
    private static let logger = Logger(subsystem: "app.tokenroom", category: "sync")

    private static let lock = NSLock()

    static func record(_ channel: SyncHealth.Channel, _ code: SyncHealth.Code, in defaults: UserDefaults, at date: Date = .now) {
        lock.lock()
        var health = SyncHealth.load(from: defaults)
        health.record(channel, code, at: date)
        health.save(to: defaults)
        lock.unlock()
        if code == .ok {
            logger.debug("\(channel.rawValue, privacy: .public) \(code.rawValue, privacy: .public)")
        } else {
            logger.notice("\(channel.rawValue, privacy: .public) \(code.rawValue, privacy: .public)")
        }
    }
}
