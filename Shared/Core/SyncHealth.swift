import Foundation
import os

/// A device's own note of how its sync paths last went: when each last ran, what came of it as
/// a code, and when it last went well. Kept in that device's App Group (the iPhone's, shared with
/// its widgets; the Watch's, shared with its complications), never sent anywhere. Dates and enum
/// codes only: no reading, size, provider, account, token, or identity. A screen for it comes
/// later; for now it's there to read in a sysdiagnose or a debugger, beside the log lines
/// `SyncHealthLog` writes.
struct SyncHealth: Codable, Equatable, Sendable {
    static let defaultsKey = "syncHealth"

    /// Which path.
    enum Channel: String, Codable, CaseIterable, Sendable {
        /// Reading the user's private iCloud database.
        case cloudRead
        /// The iPhone handing readings to the Watch (`updateApplicationContext`).
        case handoffSend
        /// The Watch taking a handover from the iPhone.
        case handoffReceive
        /// The Watch's request for the iPhone to collect, and its reply.
        case phoneReply
        /// A background refresh this device was given.
        case backgroundRefresh
    }

    /// What came of it.
    enum Code: String, Codable, CaseIterable, Sendable {
        case ok
        case noAccount
        case failed
        case timedOut
        case unavailable
        /// A handover kept until the Watch knows its account.
        case held
        /// A handover saved before the last sign-out, or not readable here.
        case dropped
        /// Sent, with its history cut to fit (`WatchHandoff.payloadLimit`).
        case trimmed
        /// Didn't fit even without history; sent anyway, and WatchConnectivity may refuse it.
        case tooLarge
        case notPaired
        case notInstalled
        case inactive
    }

    struct Entry: Codable, Equatable, Sendable {
        var at: Date
        var code: Code
        /// When this path last ended `ok` or `trimmed`.
        var lastOK: Date?
    }

    /// Keyed by `Channel.rawValue`, so the record stays a plain JSON object.
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

/// Records a `SyncHealth` entry and logs it. The log line holds the channel and code only, both
/// fixed words, so they're `.public`.
enum SyncHealthLog {
    private static let logger = Logger(subsystem: "app.tokenroom", category: "sync")

    /// The main actor and WatchConnectivity's queue both record: one load-change-save at a time,
    /// so neither drops the other's entry.
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
