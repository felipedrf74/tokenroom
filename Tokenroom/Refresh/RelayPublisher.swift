import CloudKit
import Foundation
import Observation
import os

protocol RelayCloud: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func accountFingerprint() async throws -> String
    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws
    func publishHistory(sourceID: String, history: RelayHistory) async throws
    func alertPreferences() async throws -> AlertPreferences?
    func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution
    func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date) async throws -> Bool
    func saveAlert(_ alert: UsageAlert) async throws -> Bool
    func pruneEvents(now: Date) async throws
    func saveEvent(id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String) async throws
    func resetZone() async
}

extension CloudRelay: RelayCloud {}

@Observable
@MainActor
final class RelayPublisher {
    enum State: Equatable {
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
                state = .waiting
                forgetWhatWasSent()
                retryAt = nil
                retryStartedAt = nil
                lastHistoryHour = nil
                Task { await relay.resetZone() }
            }
        }
    }

    var label: String {
        didSet {
            defaults.set(label, forKey: Keys.label)
            forgetWhatWasSent()
        }
    }

    var sharedLabel: String {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }

    let sourceID: String
    private let relay: (any RelayCloud)?
    private let defaults: UserDefaults
    private let iCloudBudget: TimeInterval
    private let maintenanceBudget: TimeInterval
    private var policy = RelayPublishPolicy()
    private var sentChecks: [String: Date] = [:]
    private var preferencesCache: (preferences: AlertPreferences?, readAt: Date)?
    private var retryAt: Date?
    private var retryStartedAt: Date?
    private var pruneRetryAt: Date?
    private var lastHistoryHour: Date?
    private var forgets = 0
    private var loggedAccount = false
    private let logger = Logger(subsystem: TokenroomIdentity.bundleID, category: "relay")

    convenience init(defaults: UserDefaults = .standard, containerIdentifier: String? = RelayAvailability.containerIdentifier) {
        self.init(defaults: defaults, cloud: containerIdentifier.map { CloudRelay(containerIdentifier: $0, zoneDeletion: RelayZoneDeletion(defaults: defaults),
                                                     zoneArchive: RelayZoneArchive.defaultURL(containerIdentifier: $0).map(RelayZoneArchive.init)) })
    }

    init(defaults: UserDefaults, cloud: (any RelayCloud)?, iCloudBudget: TimeInterval = 20, maintenanceBudget: TimeInterval = 120) {
        self.defaults = defaults
        self.iCloudBudget = iCloudBudget
        self.maintenanceBudget = maintenanceBudget
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

    func nextPublishDate(_ envelope: RelayEnvelope, now: Date) -> Date? {
        guard relay != nil, isEnabled else { return nil }
        switch state {
        case .unavailable, .off, .noAccount, .paused:
            return nil
        case .failed where retryAt == nil:
            return nil
        default:
            break
        }
        guard policy.hasChanges(envelope) || sentChecks != Self.checks(envelope) else { return nil }
        let due = policy.nextSendDate(envelope, now: now)
        return isWaiting(now) ? max(due, retryAt ?? due) : due
    }

    private static func checks(_ envelope: RelayEnvelope) -> [String: Date] {
        Dictionary(envelope.providers.map { ($0.id, $0.checkedAt ?? $0.fetchedAt ?? .distantPast) },
                   uniquingKeysWith: { first, _ in first })
    }

    func publish(_ envelope: RelayEnvelope, force: Bool = false, now: Date = .now) async {
        guard let relay, isEnabled else { return }
        if isWaiting(now), !force { return }
        guard policy.isDue(envelope, force: force, now: now) else { return }

        let sourceID = sourceID
        let label = sharedLabel
        let forgetsBefore = forgets
        let started = ContinuousClock.now
        do {
            if case .noAccount = state {
                guard try await iCloud({ try await relay.accountStatus() }) == .available else { return }
            }
            guard isEnabled else { return }
            try await iCloud { try await relay.publish(sourceID: sourceID, kind: "mac", label: label, envelope: envelope) }
            logger.notice("relay sent \(envelope.providers.count, privacy: .public) providers")
            if !loggedAccount, let fingerprint = try? await iCloud({ try await relay.accountFingerprint() }) {
                loggedAccount = true
                logger.notice("relay account \(fingerprint, privacy: .private)")
            }
            policy.didSend(envelope, at: now)
            sentChecks = Self.checks(envelope)
            if forgets != forgetsBefore {
                policy.reset()
            }
            retryAt = nil
            retryStartedAt = nil
            if isEnabled {
                state = .sent(now)
            }
        } catch {
            let elapsed = started.duration(to: .now).components
            handle(error, now: now.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18), attemptedAt: now)
        }
    }

    func providersChanged() {
        forgetWhatWasSent()
    }

    private func forgetWhatWasSent() {
        policy.reset()
        forgets += 1
    }

    func publishHistory(_ history: RelayHistory, now: Date = .now) async {
        guard let relay, isEnabled, !history.series.isEmpty else { return }
        if isWaiting(now) { return }
        let hour = UsageHistory.hourStart(now)
        guard lastHistoryHour != hour else { return }
        let sourceID = sourceID
        let forgetsBefore = forgets
        do {
            try await iCloud { try await relay.publishHistory(sourceID: sourceID, history: history) }
            if forgets == forgetsBefore {
                lastHistoryHour = hour
            }
        } catch {
            handle(error, now: now)
        }
    }

    private var preferencesBase: AlertPreferences? {
        get { defaults.data(forKey: Keys.preferencesBase).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? RelayEnvelope.encoder.encode($0) }, forKey: Keys.preferencesBase) }
    }

    var hasSharedAlertPreferences: Bool {
        preferencesBase != nil
    }

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
                handle(error, now: now)
                return local
            }
        }
        let resolution = AlertPreferencesSync.resolve(base: base, local: local, remote: remote)
        guard resolution.needsPublish else {
            preferencesBase = remote ?? resolution.preferences
            return resolution.preferences
        }
        guard isEnabled else { return local }
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

    func sendAlerts(_ alerts: [UsageAlert], now: Date = .now) async -> AlertLedger.Delivery {
        guard let relay, isEnabled else { return .init() }
        if isWaiting(now) { return .init() }
        return await Self.send(alerts, wentOutOnANeighbouringDay: { alert in
            try await self.iCloud { try await relay.wentOutOnANeighbouringDay(alert, now: now) }
        }, save: { alert in
            let created = try await self.iCloud { try await relay.saveAlert(alert) }
            self.logger.notice("relay alert sent \(alert.kind.rawValue, privacy: .public) \(alert.level, privacy: .public)")
            return created
        }, stops: { error in
            self.handle(error, now: now).stopsBatch
        }, continues: {
            self.isEnabled
        })
    }

    static func send(_ alerts: [UsageAlert], wentOutOnANeighbouringDay: (UsageAlert) async throws -> Bool,
                     save: (UsageAlert) async throws -> Bool, stops: (Error) -> Bool,
                     continues: () -> Bool = { true }) async -> AlertLedger.Delivery {
        var delivery = AlertLedger.Delivery()
        for alert in alerts {
            guard continues() else { break }
            do {
                if try await wentOutOnANeighbouringDay(alert) {
                    delivery.saved.append(alert.id)
                    delivery.announced.insert(alert.id)
                    continue
                }
                guard continues() else { break }
                if try await !save(alert) {
                    delivery.announced.insert(alert.id)
                }
                delivery.saved.append(alert.id)
            } catch {
                if stops(error) { break }
            }
        }
        return delivery
    }

    static let pruneRetry: TimeInterval = 3600

    func pruneEventsIfDue(now: Date = .now) async {
        guard let relay, isEnabled else { return }
        if isWaiting(now) { return }
        if let pruneRetryAt, pruneRetryAt > now, pruneRetryAt.timeIntervalSince(now) <= Self.pruneRetry { return }
        if let pruned = defaults.object(forKey: Keys.prunedAt) as? Date, (0..<86_400).contains(now.timeIntervalSince(pruned)) { return }
        do {
            try await iCloud(within: maintenanceBudget) { try await relay.pruneEvents(now: now) }
            defaults.set(now, forKey: Keys.prunedAt)
            pruneRetryAt = nil
        } catch is CancellationError {
            return
        } catch {
            pruneRetryAt = now.addingTimeInterval(Self.pruneRetry)
            logger.error("relay pruning failed: \(String(describing: error), privacy: .public)")
        }
    }

    func sendTestAlert(now: Date = .now) async {
        guard let relay, isEnabled else { return }
        let body = "Test alert from \(sharedLabel). Usage alerts will look like this."
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

    private func isWaiting(_ now: Date) -> Bool {
        guard let retryAt, retryAt > now else { return false }
        return retryStartedAt.map { now >= $0 } ?? true
    }

    private struct ICloudTimeout: Error {}

    private func iCloud<T: Sendable>(within budget: TimeInterval? = nil, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = await TimeLimit.run(budget ?? iCloudBudget, otherwise: Result<T, any Error>.failure(ICloudTimeout())) {
            do {
                return .success(try await work())
            } catch {
                return .failure(error)
            }
        }
        if case .failure(let error) = result, error is ICloudTimeout, Task.isCancelled {
            throw CancellationError()
        }
        return try result.get()
    }

    @discardableResult
    private func handle(_ error: Error, now: Date, attemptedAt: Date? = nil) -> RelayErrorPolicy.Outcome {
        logger.error("relay failed: \(String(describing: error), privacy: .public)")
        let outcome: RelayErrorPolicy.Outcome = error is ICloudTimeout
            ? .retry(after: Self.minimumInterval, message: "Couldn't reach iCloud. Trying again soon.")
            : RelayErrorPolicy.outcome(for: error, defaultRetry: Self.minimumInterval)
        guard isEnabled else { return outcome }
        switch outcome {
        case .noAccount:
            retryAt = nil
            retryStartedAt = nil
            state = .noAccount
        case .paused(let message):
            retryAt = nil
            retryStartedAt = nil
            state = .paused(message)
        case .retry(let after, let message):
            let delay = after.isFinite && after > 0 ? max(RelayPublishPolicy.statusInterval, after) : Self.minimumInterval
            retryAt = now.addingTimeInterval(delay)
            retryStartedAt = attemptedAt ?? now
            state = .failed(message)
        case .unavailable:
            retryAt = nil
            retryStartedAt = nil
            state = .unavailable
        case .cancelled:
            break
        case .failed(let message):
            retryAt = nil
            retryStartedAt = nil
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
