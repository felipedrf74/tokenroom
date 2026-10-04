import CloudKit
import CryptoKit
import Foundation
import Synchronization

/// Tokenroom's records in the user's private CloudKit database, zone "Tokenroom".
///
/// - `Source`: one per collector (a Mac, or an iPhone with API keys). Only that collector writes it,
///   so saves never conflict. `payload` is a JSON `RelayEnvelope`.
/// - `History`: that collector's hourly usage for the last week (`hist-<source>`), sent hourly.
/// - `Event`: an alert (threshold crossed, test). The iPhone's query subscription turns each new
///   one into a visible notification, even when the app isn't running.
/// - `Prefs`: the alert preferences (`prefs-alerts`), shared by the iPhone and Macs; the newer copy wins.
///
/// Widgets and the Watch only read; their builds leave the write methods out
/// (`TOKENROOM_RELAY_READONLY`).
actor CloudRelay {
    private static let readers = Mutex<[String: CloudRelay]>([:])

    /// Reuse the zone cursor while a widget/Watch process remains alive, as the app does.
    static func shared(containerIdentifier: String) -> CloudRelay {
        readers.withLock { readers in
            if let reader = readers[containerIdentifier] { return reader }
            let reader = CloudRelay(containerIdentifier: containerIdentifier)
            readers[containerIdentifier] = reader
            return reader
        }
    }

    enum RecordType {
        static let source = "Source"
        static let history = "History"
        static let event = "Event"
        static let prefs = "Prefs"
    }

    static let alertPreferencesRecord = "prefs-alerts"
    /// Alert records older than this are deleted; the notification went out long ago.
    static let eventLifetime: TimeInterval = 14 * 86_400
    /// The most records CloudKit takes in one request.
    static let batchLimit = 400

    enum Field {
        /// A plain field, not `encryptedValues`: it holds usage numbers, names, and reset times
        /// only, and encrypted fields are lost if the account's keys are reset.
        static let payload = "payload"
        static let kind = "kind"
        static let label = "label"
        static let checkedAt = "checkedAt"
        static let schema = "schema"
        static let appVersion = "appVersion"
        static let provider = "provider"
        static let level = "level"
        static let title = "title"
        static let body = "body"
        static let resetsAt = "resetsAt"
        static let alertKind = "alertKind"
        /// `UsageAlert.key`, e.g. `threshold-80`; the iPhone's subscription filters on it.
        static let alertKey = "alertKey"
    }

    static let zoneID = CKRecordZone.ID(zoneName: "Tokenroom", ownerName: CKCurrentUserDefaultName)

    /// Everything readers need from the zone.
    struct Contents: Sendable {
        var sources: [Source]
        /// Keyed by source ID.
        var histories: [String: RelayHistory]
        var alertPreferences: AlertPreferences? = nil
        /// Alert record names and when each was created, for pruning.
        var events: [(id: String, createdAt: Date?)] = []
    }

    struct Source: Sendable, Identifiable {
        var id: String
        var kind: String
        var label: String
        var modifiedAt: Date?
        /// Nil when the payload is damaged or from a newer format this build can't read.
        var envelope: RelayEnvelope?
        var needsNewerApp: Bool
    }

    let containerIdentifier: String
    private let container: CKContainer
    private var zoneReady = false
    private var zoneEpoch: UUID?
    private let accountEpoch: RelayAccountEpoch
    private var subscriptionsWrite: Task<Bool, any Error>?
    private let zoneReader: RelayZoneReader<CKRecord.ID, CKRecord, CKServerChangeToken>
    private let accountObserver: RelayAccountObserver

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    /// Only call when `RelayAvailability` reports the container; CloudKit traps without the entitlement.
    init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        let database = container.privateCloudDatabase
        let epoch = RelayAccountEpoch()
        accountEpoch = epoch
        let reader = RelayZoneReader<CKRecord.ID, CKRecord, CKServerChangeToken>(fetch: { token in
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
            return .init(
                modifications: changes.modificationResultsByID.mapValues { $0.map(\.record) },
                deletions: changes.deletions.map(\.recordID),
                token: changes.changeToken,
                moreComing: changes.moreComing
            )
        }, recovery: { error in
            switch (error as? CKError)?.code {
            case .changeTokenExpired: .retryFromStart
            case .zoneNotFound: .emptyZone
            default: .fail
            }
        })
        zoneReader = reader
        accountObserver = RelayAccountObserver(name: .CKAccountChanged) {
            epoch.invalidate()
        }
    }

    func accountStatus() async throws -> CKAccountStatus {
        let status = try await container.accountStatus()
        if status == .noAccount { accountEpoch.invalidate(); await zoneReader.invalidate(); zoneReady = false }
        return status
    }

    /// Short, one-way fingerprint of this container's anonymous user ID. Two devices on the same
    /// iCloud account show the same value; used only in diagnostics, never stored in records.
    func accountFingerprint() async throws -> String {
        let id = try await container.userRecordID().recordName
        return SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func historyRecordName(for sourceID: String) -> String {
        "hist-\(sourceID)"
    }

    /// The shared alert preferences, or nil before either device has saved any.
    func alertPreferences() async throws -> AlertPreferences? {
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: Self.alertPreferencesRecord, zoneID: Self.zoneID))
            return (record[Field.payload] as? Data).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    /// Read a complete snapshot, then only the zone's deltas on later reads. Alert records no
    /// longer make every foreground refresh download the whole retained notification history.
    func contents() async throws -> Contents {
        let epoch = accountEpoch.value
        let records = try await zoneReader.contents(scope: epoch)
        guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
        var sources: [Source] = []
        var histories: [String: RelayHistory] = [:]
        var preferences: AlertPreferences?
        var events: [(id: String, createdAt: Date?)] = []
        for record in records.values {
            switch record.recordType {
            case RecordType.source:
                sources.append(Self.source(from: record))
            case RecordType.history:
                let name = record.recordID.recordName
                guard name.hasPrefix("hist-"),
                      let data = record[Field.payload] as? Data,
                      let history = try? RelayHistory.decode(data)
                else { continue }
                histories[String(name.dropFirst("hist-".count))] = history
            case RecordType.prefs where record.recordID.recordName == Self.alertPreferencesRecord:
                preferences = (record[Field.payload] as? Data).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) }
            case RecordType.event:
                events.append((record.recordID.recordName, record.creationDate))
            default:
                continue
            }
        }
        return Contents(sources: sources.sorted { $0.id < $1.id }, histories: histories, alertPreferences: preferences, events: events)
    }

    func sources() async throws -> [Source] {
        try await contents().sources
    }

    /// Whether a balance alert already went out, less than a day ago, under the name of the day
    /// before or after. Balances have no reset, so an alert is named by the day (UTC) a device saw
    /// it, and two devices on either side of midnight would otherwise alert twice for one crossing,
    /// whichever of them delivers first.
    func wentOutOnANeighbouringDay(_ alert: UsageAlert, now: Date = .now) async throws -> Bool {
        for name in AlertRules.neighbouringDayIDs(of: alert) {
            do {
                let record = try await database.record(for: CKRecord.ID(recordName: name, zoneID: Self.zoneID))
                if (record.creationDate ?? .distantPast) > now.addingTimeInterval(-86_400) {
                    return true
                }
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
                continue
            }
        }
        return false
    }

    private static func source(from record: CKRecord) -> Source {
        var envelope: RelayEnvelope?
        var needsNewerApp = false
        if let data = record[Field.payload] as? Data, let decoded = try? RelayEnvelope.decode(data) {
            if decoded.isReadable {
                envelope = decoded
            } else {
                needsNewerApp = true
            }
        }
        return Source(
            id: record.recordID.recordName,
            kind: record[Field.kind] as? String ?? "mac",
            label: record[Field.label] as? String ?? "Mac",
            modifiedAt: record.modificationDate,
            envelope: envelope,
            needsNewerApp: needsNewerApp
        )
    }
}

#if !TOKENROOM_RELAY_READONLY
// Writes: the Mac and the iPhone app only.
extension CloudRelay {
    func publish(sourceID: String, kind: String, label: String, envelope: RelayEnvelope) async throws {
        let record = CKRecord(
            recordType: RecordType.source,
            recordID: CKRecord.ID(recordName: sourceID, zoneID: Self.zoneID)
        )
        record[Field.payload] = try envelope.encoded()
        record[Field.kind] = kind
        record[Field.label] = label
        record[Field.checkedAt] = envelope.checkedAt
        record[Field.schema] = envelope.v
        record[Field.appVersion] = envelope.appVersion
        try await save([record])
    }

    func publishHistory(sourceID: String, history: RelayHistory) async throws {
        let record = CKRecord(
            recordType: RecordType.history,
            recordID: CKRecord.ID(recordName: Self.historyRecordName(for: sourceID), zoneID: Self.zoneID)
        )
        record[Field.payload] = try history.encoded()
        record[Field.schema] = history.v
        try await save([record])
    }

    /// Saves an alert, unless a device already has: the subscription fires only when a record is
    /// created, so one already there means its notification went out. Left as it is, an iPhone's
    /// claim keeps its `shown:` key, which tells another iPhone that nothing reached it.
    func saveAlert(_ alert: UsageAlert) async throws {
        let record = Self.eventRecord(id: alert.id, provider: alert.provider, level: alert.level, title: alert.title, body: alert.body,
                                      resetsAt: alert.resetsAt, kind: alert.kind.rawValue, key: alert.key)
        do {
            try await save([record], policy: .ifServerRecordUnchanged)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already sent, by another device.
        }
    }

    func syncAlertPreferences(base: AlertPreferences?, local: AlertPreferences) async throws -> AlertPreferencesSync.Resolution {
        try await AlertPreferencesSync.synchronize(base: base, local: local, read: {
            try await self.preferenceRevision()
        }, write: { preferences, record in
            try await self.savePreferences(preferences, record: record)
        }, isConflict: Self.isPreferenceConflict)
    }

    static func isPreferenceConflict(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return true }
        guard error.code == .partialFailure else { return false }
        return error.partialErrorsByItemID?.values.contains(where: isPreferenceConflict) == true
    }

    private func preferenceRevision() async throws -> AlertPreferencesSync.Versioned<CKRecord> {
        let id = CKRecord.ID(recordName: Self.alertPreferencesRecord, zoneID: Self.zoneID)
        do {
            let record = try await database.record(for: id)
            guard let data = record[Field.payload] as? Data else { throw ProviderError.parse }
            let preferences = try RelayEnvelope.decoder.decode(AlertPreferences.self, from: data)
            return .init(preferences: preferences, revision: record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return .init(preferences: nil, revision: CKRecord(recordType: RecordType.prefs, recordID: id))
        }
    }

    private func savePreferences(_ preferences: AlertPreferences, record: CKRecord) async throws {
        record[Field.payload] = try RelayEnvelope.encoder.encode(preferences)
        try await save([record], policy: .ifServerRecordUnchanged)
    }

    /// Deletes in batches CloudKit accepts (at most 400 changes a request). Not atomic: a record
    /// another device already deleted doesn't stop the rest.
    func deleteRecords(named names: [String]) async throws {
        for start in stride(from: 0, to: names.count, by: Self.batchLimit) {
            let batch = names[start..<min(start + Self.batchLimit, names.count)]
            try Task.checkCancellation()
            let results = try await database.modifyRecords(
                saving: [],
                deleting: batch.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) },
                savePolicy: .changedKeys,
                atomically: false
            )
            for (_, result) in results.deleteResults {
                if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem { throw error }
            }
        }
    }

    /// Deletes alert records older than `eventLifetime`, whichever device made them. Their
    /// notifications went out long ago; the Mac and the iPhone both do this, so it happens
    /// without the other.
    func pruneEvents(now: Date = .now) async throws {
        let old = try await contents().events.filter { event in
            event.createdAt.map { now.timeIntervalSince($0) > Self.eventLifetime } ?? false
        }
        try await deleteRecords(named: old.map(\.id))
    }

    /// Record names are deterministic, so two Macs seeing the same crossing create one alert.
    func saveEvent(
        id: String,
        provider: String,
        level: Int,
        title: String,
        body: String,
        resetsAt: Date? = nil,
        kind: String = "test",
        key: String = "test"
    ) async throws {
        try await save([Self.eventRecord(id: id, provider: provider, level: level, title: title, body: body, resetsAt: resetsAt, kind: kind, key: key)])
    }

    private static func eventRecord(
        id: String, provider: String, level: Int, title: String, body: String, resetsAt: Date?, kind: String, key: String
    ) -> CKRecord {
        let record = CKRecord(recordType: RecordType.event, recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        record[Field.provider] = provider
        record[Field.level] = level
        record[Field.title] = title
        record[Field.body] = body
        record[Field.resetsAt] = resetsAt
        record[Field.alertKind] = kind
        record[Field.alertKey] = key
        return record
    }

    /// Deletes the zone with every record in it. CloudKit reports a failed deletion in the
    /// zone's own result rather than by throwing, so that's checked too.
    func deleteAllData() async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        zoneReady = false
        for (_, result) in results.deleteResults {
            guard case .failure(let error) = result else { continue }
            // Already gone, from this device or from iCloud settings: nothing left to delete.
            let code = (error as? CKError)?.code
            if code != .zoneNotFound, code != .userDeletedZone {
                throw error
            }
        }
        await zoneReader.invalidate()
    }

    /// Makes the next save create the zone again. For after the user deleted Tokenroom's iCloud
    /// data in Settings: CloudKit then refuses saves until the zone is re-created, which should
    /// only happen when the user asks (turning sync back on).
    func resetZone() {
        zoneReady = false
    }

    /// `.allKeys` replaces by name; `.ifServerRecordUnchanged` creates or checks a fetched change tag.
    private func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys) async throws {
        try await ensureZone()
        do {
            try await modify(records, policy: policy)
        } catch let error as CKError where error.code == .zoneNotFound {
            zoneReady = false
            try await ensureZone()
            try await modify(records, policy: policy)
        }
    }

    private func modify(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let results = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: policy,
            atomically: true
        )
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
    }

    private func ensureZone() async throws {
        let epoch = accountEpoch.value
        guard !zoneReady || zoneEpoch != epoch else { return }
        let results = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
        guard accountEpoch.value == epoch, !Task.isCancelled else { throw CancellationError() }
        zoneReady = true
        zoneEpoch = epoch
    }
}
#endif

#if os(iOS) && !TOKENROOM_RELAY_READONLY
extension CloudRelay {
    static let changesSubscriptionID = "tokenroom-sources"
    static let alertsSubscriptionID = "tokenroom-alerts"

    /// Silent pushes when any source changes; visible notifications for new alert events of the
    /// kinds in `alertKeys` (`UsageAlert.key` values). Saving the same IDs again replaces them, so
    /// this is safe on every launch and whenever the alert preferences change. Returns whether the
    /// alert subscription filters by kind (false while `alertKey` isn't queryable yet).
    @discardableResult
    func ensureSubscriptions(alertKeys: [String]) async throws -> Bool {
        let previous = subscriptionsWrite
        let epoch = accountEpoch.value
        let task = Task {
            // Even an API call that ignores cancellation must finish before another writer can
            // replace its filter; older requests can never overtake newer choices.
            if let previous { _ = try? await previous.value }
            try checkSubscriptionWrite(epoch: epoch)
            return try await installSubscriptions(alertKeys: alertKeys, epoch: epoch)
        }
        subscriptionsWrite = task
        defer { if subscriptionsWrite == task { subscriptionsWrite = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func checkSubscriptionWrite(epoch: UUID) throws {
        try Task.checkCancellation()
        guard accountEpoch.value == epoch else { throw CancellationError() }
    }

    private func installSubscriptions(alertKeys: [String], epoch: UUID) async throws -> Bool {
        try checkSubscriptionWrite(epoch: epoch)
        try await ensureZone()
        try checkSubscriptionWrite(epoch: epoch)

        let changes = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.changesSubscriptionID)
        changes.recordType = RecordType.source
        let silent = CKSubscription.NotificationInfo()
        silent.shouldSendContentAvailable = true
        changes.notificationInfo = silent
        try await saveSubscriptions([changes])
        try checkSubscriptionWrite(epoch: epoch)

        // Filtering needs `alertKey` to be queryable in the schema. Until it is, every alert
        // comes through and the sending device filters by the same preferences.
        do {
            try await saveSubscriptions([alertSubscription(NSPredicate(format: "%K IN %@", Field.alertKey, alertKeys))])
            try checkSubscriptionWrite(epoch: epoch)
            return true
        } catch let error as CKError where error.code == .invalidArguments || error.code == .serverRejectedRequest {
            // What CloudKit says when the schema can't query `alertKey` yet. Other errors
            // (offline, busy) are thrown, to be retried with the filter.
            try checkSubscriptionWrite(epoch: epoch)
            try await saveSubscriptions([alertSubscription(NSPredicate(value: true))])
            try checkSubscriptionWrite(epoch: epoch)
            return false
        }
    }

    enum Claim: Equatable {
        /// This iPhone's record now stands for the alert.
        case created
        /// A Mac's record was there first, and its notification reached this iPhone.
        case pushed
        /// Another iPhone's record was there first. It showed the alert itself, and no
        /// subscription lists its key, so nothing reached this iPhone.
        case shownElsewhere
    }

    /// Before this iPhone shows an alert itself: creates the alert's record, under `shownKey`,
    /// only if no device has yet. A Mac that sees the same crossing later saves over this record,
    /// and an update sends no notification, so the alert shows once.
    func claimAlert(_ alert: UsageAlert) async throws -> Claim {
        let record = Self.eventRecord(id: alert.id, provider: alert.provider, level: alert.level, title: alert.title, body: alert.body,
                                      resetsAt: alert.resetsAt, kind: alert.kind.rawValue, key: alert.shownKey)
        do {
            try await save([record], policy: .ifServerRecordUnchanged)
            return .created
        } catch let error as CKError where error.code == .serverRecordChanged {
            let key = error.serverRecord?[Field.alertKey] as? String
            return key?.hasPrefix("shown:") == true ? .shownElsewhere : .pushed
        }
    }

    private func alertSubscription(_ predicate: NSPredicate) -> CKQuerySubscription {
        let alerts = CKQuerySubscription(
            recordType: RecordType.event,
            predicate: predicate,
            subscriptionID: Self.alertsSubscriptionID,
            options: [.firesOnRecordCreation]
        )
        alerts.zoneID = Self.zoneID
        let visible = CKSubscription.NotificationInfo()
        // A format-only key makes iOS show the record's own title and body.
        visible.titleLocalizationKey = "%1$@"
        visible.titleLocalizationArgs = [Field.title]
        visible.alertLocalizationKey = "%1$@"
        visible.alertLocalizationArgs = [Field.body]
        visible.soundName = "default"
        // No `collapseIDKey`: CloudKit sends its value as is, as every push's collapse ID, so
        // unseen alerts would replace each other across providers.
        alerts.notificationInfo = visible
        return alerts
    }

    private func saveSubscriptions(_ subscriptions: [CKSubscription]) async throws {
        let results = try await database.modifySubscriptions(saving: subscriptions, deleting: [])
        for (_, result) in results.saveResults {
            if case .failure(let error) = result {
                throw error
            }
        }
    }
}
#endif
