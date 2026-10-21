import CloudKit
import Foundation
import Observation
import os

/// What `RelayPublisher` asks of iCloud: `CloudRelay` in the app, a stand-in in tests.
protocol RelayCloud: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func accountFingerprint() async throws -> String
    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws
    func publishHistory(sourceID: String, history: RelayHistory) async throws
    func alertPreferences() async throws -> AlertPreferences?
    func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution
    func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date) async throws -> Bool
    func saveAlert(_ alert: UsageAlert) async throws
    func pruneEvents(now: Date) async throws
    func saveEvent(id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String) async throws
    func resetZone() async
}

extension CloudRelay: RelayCloud {}

/// Sends this Mac's readings to the user's iCloud so Tokenroom on iPhone and Apple Watch can show them.
/// Only percentages, reset times, labels, and plan names leave the Mac. Never tokens.
@Observable
@MainActor
final class RelayPublisher {
    enum State: Equatable {
        /// This copy isn't signed for iCloud (ad-hoc build).
        case unavailable
        case off
        case waiting
        case noAccount
        case sent(Date)
        case failed(String)
        case paused(String)
    }

    enum Keys {
        static let enabled = "relayEnabled"
        static let sourceID = "relaySourceID"
        static let label = "relayLabel"
        static let preferencesBase = "alertPreferencesBase"
        static let prunedAt = "eventsPrunedAt"
    }

    static let minimumInterval = RelayPublishPolicy.minimumInterval

    private(set) var state: State
    var lastSent: Date? {
        policy.lastSent
    }

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                state = relay == nil ? .unavailable : .off
            } else if let relay, !oldValue {
                // Keyed on the switch, not on `state`: a send that was out when sync went off
                // doesn't change what turning it back on does.
                state = .waiting
                policy.reset()
                retryAt = nil
                lastHistoryHour = nil
                // Turning sync back on is how someone who deleted Tokenroom's iCloud data in
                // Settings starts again: the zone is created anew (the choices go back when
                // iCloud turns out to have none).
                Task { await relay.resetZone() }
            }
        }
    }

    var label: String {
        didSet {
            defaults.set(label, forKey: Keys.label)
            policy.reset()
        }
    }

    let sourceID: String
    private let relay: (any RelayCloud)?
    private let defaults: UserDefaults
    /// The longest a sharing round waits for any one iCloud call, as on the iPhone.
    private let iCloudBudget: TimeInterval
    private var policy = RelayPublishPolicy()
    /// The shared alert choices as iCloud last had them (nil: none yet).
    private var preferencesCache: (preferences: AlertPreferences?, readAt: Date)?
    private var retryAt: Date?
    private var lastHistoryHour: Date?
    private var loggedAccount = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "relay")

    convenience init(defaults: UserDefaults = .standard, containerIdentifier: String? = RelayAvailability.containerIdentifier) {
        self.init(defaults: defaults, cloud: containerIdentifier.map { CloudRelay(containerIdentifier: $0, zoneDeletion: RelayZoneDeletion(defaults: defaults)) })
    }

    /// `cloud` is nil when this copy can't use iCloud. Tests pass a stand-in and a short budget.
    init(defaults: UserDefaults, cloud: (any RelayCloud)?, iCloudBudget: TimeInterval = 20) {
        self.defaults = defaults
        self.iCloudBudget = iCloudBudget
        if let existing = defaults.string(forKey: Keys.sourceID) {
            sourceID = existing
        } else {
            sourceID = "src-\(UUID().uuidString.lowercased())"
            defaults.set(sourceID, forKey: Keys.sourceID)
        }
        label = defaults.string(forKey: Keys.label) ?? "Mac"
        relay = cloud
        let enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        isEnabled = enabled
        state = relay == nil ? .unavailable : (enabled ? .waiting : .off)
    }

    var isAvailable: Bool {
        relay != nil
    }

    /// Sends when usage changed materially (at most every 5 minutes), when a provider's status
    /// changed (after a minute), or every 30 minutes as a heartbeat.
    func publish(_ envelope: RelayEnvelope, force: Bool = false, now: Date = .now) async {
        guard let relay, isEnabled else { return }
        if isWaiting(now), !force { return }
        guard policy.isDue(envelope, force: force, now: now) else { return }

        let sourceID = sourceID
        let label = label
        do {
            if case .noAccount = state {
                guard try await iCloud({ try await relay.accountStatus() }) == .available else { return }
            }
            try await iCloud { try await relay.publish(sourceID: sourceID, kind: "mac", label: label, envelope: envelope) }
            logger.notice("relay sent \(envelope.providers.count, privacy: .public) providers")
            if !loggedAccount, let fingerprint = try? await iCloud({ try await relay.accountFingerprint() }) {
                loggedAccount = true
                // Private: even hashed, it's the same value on every device of the account.
                logger.notice("relay account \(fingerprint, privacy: .private)")
            }
            policy.didSend(envelope, at: now)
            retryAt = nil
            // Turned off while it was out: the switch keeps saying Off.
            if isEnabled {
                state = .sent(now)
            }
        } catch {
            handle(error, now: now)
        }
    }

    /// The providers this Mac shares changed (one was turned on or off in Settings): the next
    /// round sends what it has, rather than waiting out the minute since the last send.
    func providersChanged() {
        policy.reset()
    }

    /// Sends the week of hourly history once per hour.
    func publishHistory(_ history: RelayHistory, now: Date = .now) async {
        guard let relay, isEnabled, !history.series.isEmpty else { return }
        if isWaiting(now) { return }
        let hour = UsageHistory.hourStart(now)
        guard lastHistoryHour != hour else { return }
        let sourceID = sourceID
        do {
            try await iCloud { try await relay.publishHistory(sourceID: sourceID, history: history) }
            lastHistoryHour = hour
        } catch {
            handle(error, now: now)
        }
    }

    /// The alert choices this Mac last knew to match iCloud. What differs from them in Settings
    /// is a change made here that iCloud doesn't have yet (made offline, say): it goes out on the
    /// next refresh, laid over whatever the iPhone changed meanwhile.
    private var preferencesBase: AlertPreferences? {
        get { defaults.data(forKey: Keys.preferencesBase).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? RelayEnvelope.encoder.encode($0) }, forKey: Keys.preferencesBase) }
    }

    /// Whether this Mac's alert choices were ever in step with iCloud's, so its copy may hold
    /// another device's time zone.
    var hasSharedAlertPreferences: Bool {
        preferencesBase != nil
    }

    /// The alert choices to use now, in step with iCloud: a change made on the iPhone is taken,
    /// and one made here goes out on top of the newest shared copy, so neither undoes the
    /// other. While nothing changed here, iCloud is read at most every half hour.
    func syncAlertPreferences(local: AlertPreferences, now: Date = .now) async -> AlertPreferences {
        guard let relay, isEnabled else { return local }
        if isWaiting(now) { return local }
        let base = preferencesBase
        let remote: AlertPreferences?
        if local.sameChoices(as: base), let cached = preferencesCache, (0..<(30 * 60)).contains(now.timeIntervalSince(cached.readAt)) {
            remote = cached.preferences
        } else {
            do {
                remote = try await iCloud { try await relay.alertPreferences() }
                preferencesCache = (remote, now)
            } catch {
                // Kept as they are here; a change made here goes out on a later refresh.
                handle(error, now: now)
                return local
            }
        }
        let resolution = AlertPreferencesSync.resolve(base: base, local: local, remote: remote)
        guard resolution.needsPublish else {
            // In step: iCloud's copy, or with none there, choices nobody changed.
            preferencesBase = remote ?? resolution.preferences
            return resolution.preferences
        }
        do {
            let saved = try await iCloud { try await relay.syncAlertPreferences(base: base, local: local) }
            preferencesBase = saved.preferences
            preferencesCache = (saved.preferences, now)
            return saved.preferences
        } catch {
            handle(error, now: now)
            return local
        }
    }

    /// Sends alerts to the iPhone; returns the IDs that went out (or already had), and of those
    /// the ones another device announced under the neighbouring day, which this Mac doesn't show
    /// either. The rest stay queued.
    func sendAlerts(_ alerts: [UsageAlert], now: Date = .now) async -> (saved: [String], announced: Set<String>) {
        guard let relay, isEnabled else { return ([], []) }
        if isWaiting(now) { return ([], []) }
        var saved: [String] = []
        var announced: Set<String> = []
        for alert in alerts {
            do {
                // A balance crossing another device announced on the other side of midnight
                // (UTC) has that day's name; don't announce it again under this one's.
                if try await iCloud({ try await relay.wentOutOnANeighbouringDay(alert, now: now) }) {
                    saved.append(alert.id)
                    announced.insert(alert.id)
                    continue
                }
                try await iCloud { try await relay.saveAlert(alert) }
                saved.append(alert.id)
                logger.notice("relay alert sent \(alert.kind.rawValue, privacy: .public) \(alert.level, privacy: .public)")
            } catch {
                if handle(error, now: now).stopsBatch { break }
            }
        }
        return (saved, announced)
    }

    /// Once a day, deletes alert records older than two weeks, so they don't pile up in iCloud
    /// on a Mac used without the iPhone app.
    func pruneEventsIfDue(now: Date = .now) async {
        guard let relay, isEnabled else { return }
        if isWaiting(now) { return }
        if let pruned = defaults.object(forKey: Keys.prunedAt) as? Date, (0..<86_400).contains(now.timeIntervalSince(pruned)) { return }
        do {
            try await iCloud { try await relay.pruneEvents(now: now) }
            defaults.set(now, forKey: Keys.prunedAt)
        } catch {
            logger.error("relay pruning failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Creates an alert event the iPhone shows as a notification. Used by "Send Test Alert".
    func sendTestAlert(now: Date = .now) async {
        guard let relay, isEnabled else { return }
        let body = "Test alert from \(label). Usage alerts will look like this."
        do {
            try await iCloud {
                try await relay.saveEvent(
                    id: "evt-test-\(Int(now.timeIntervalSince1970))",
                    provider: "tokenroom",
                    level: 0,
                    title: "Tokenroom",
                    body: body,
                    resetsAt: nil,
                    kind: "test",
                    key: "test"
                )
            }
            logger.notice("relay test alert sent")
        } catch {
            handle(error, now: now)
        }
    }

    /// Whether iCloud asked to wait. A wait further off than an hour means the clock was set back
    /// since it was saved.
    private func isWaiting(_ now: Date) -> Bool {
        guard let retryAt, retryAt > now else { return false }
        return retryAt.timeIntervalSince(now) <= 3600
    }

    private struct ICloudTimeout: Error {}

    /// `work`'s answer within `iCloudBudget`, or `ICloudTimeout`: a call that never answers
    /// (account status, say, which ignores cancellation) counts as iCloud being unreachable
    /// rather than holding the sharing round, and every one queued behind it, forever.
    private func iCloud<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = await TimeLimit.run(iCloudBudget, otherwise: Result<T, any Error>.failure(ICloudTimeout())) {
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        // Let go because the round was cancelled (going to sleep): not iCloud's doing.
        if case .failure(let error) = result, error is ICloudTimeout, Task.isCancelled {
            throw CancellationError()
        }
        return try result.get()
    }

    @discardableResult
    private func handle(_ error: Error, now: Date) -> RelayErrorPolicy.Outcome {
        logger.error("relay failed: \(String(describing: error), privacy: .public)")
        // A call that didn't answer in time is waited out like a dropped connection, so the
        // rest of the round doesn't wait on iCloud call by call.
        let outcome: RelayErrorPolicy.Outcome = error is ICloudTimeout
            ? .retry(after: Self.minimumInterval, message: "Couldn't reach iCloud. Trying again soon.")
            : RelayErrorPolicy.outcome(for: error, defaultRetry: Self.minimumInterval)
        // Turned off while the call was out: the switch keeps saying Off, and turning it back on
        // starts afresh.
        guard isEnabled else { return outcome }
        switch outcome {
        case .noAccount:
            state = .noAccount
        case .paused(let message):
            state = .paused(message)
        case .retry(let after, let message):
            retryAt = now.addingTimeInterval(after)
            state = .failed(message)
        case .unavailable:
            state = .unavailable
        case .cancelled:
            break
        case .failed(let message):
            state = .failed(message)
        }
        return outcome
    }

    var statusText: String {
        switch state {
        case .unavailable:
            "iPhone sync needs the signed download. This copy is signed on this Mac."
        case .off:
            "Off"
        case .waiting:
            "On · waiting for the first reading"
        case .noAccount:
            "Couldn't reach iCloud. Sign in to iCloud on this Mac."
        case .sent(let date):
            "On · sent \(RelativeTime.ago(date))"
        case .failed(let message), .paused(let message):
            message
        }
    }
}
