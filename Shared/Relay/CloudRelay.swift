import CloudKit
import CryptoKit
import Foundation
import Synchronization

actor CloudRelay {
    private static let readers = Mutex<[String: CloudRelay]>([:])

    static func shared(containerIdentifier: String) -> CloudRelay {
        readers.withLock { readers in
            if let reader = readers[containerIdentifier] { return reader }
            let reader = CloudRelay(containerIdentifier: containerIdentifier,
                                    zoneArchive: RelayZoneArchive.defaultURL(containerIdentifier: containerIdentifier).map(RelayZoneArchive.init))
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
    static let eventLifetime: TimeInterval = 14 * 86_400
    static let batchLimit = 400
    static let changesPageLimit = 100
    static let queryPageLimit = 10

    enum Field {
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
        static let alertKey = "alertKey"
    }

    static let zoneID = CKRecordZone.ID(zoneName: "Tokenroom", ownerName: CKCurrentUserDefaultName)

    struct Contents: Sendable {
        var sources: [Source]
        var histories: [String: RelayHistory]
        var alertPreferences: AlertPreferences? = nil
        var events: [(id: String, createdAt: Date?)] = []
        var deletedByUser = false
    }

    struct Source: Sendable, Identifiable {
        var id: String
        var kind: String
        var label: String
        var modifiedAt: Date?
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
    private let zoneArchive: RelayZoneArchive?
    private var restoredEpoch: UUID?
    private var queriesSources = true
    private var seenSources: (epoch: UUID, names: Set<String>)?
    private let accountObserver: RelayAccountObserver
    private let zoneDeletion: RelayZoneDeletion
    private var knownAccount: (epoch: UUID, fingerprint: String)?

    private var database: CKDatabase {
        container.privateCloudDatabase
    }

    init(containerIdentifier: String, zoneDeletion: RelayZoneDeletion = RelayZoneDeletion(defaults: .standard),
         zoneArchive: RelayZoneArchive? = nil) {
        self.containerIdentifier = containerIdentifier
        self.zoneDeletion = zoneDeletion
        self.zoneArchive = zoneArchive
        let container = CKContainer(identifier: containerIdentifier)
        self.container = container
        let database = container.privateCloudDatabase
        let epoch = RelayAccountEpoch()
        accountEpoch = epoch
        let reader = RelayZoneReader<CKRecord.ID, CKRecord, CKServerChangeToken>(fetch: { token in
            let changes = try await database.recordZoneChanges(inZoneWith: Self.zoneID, since: token,
                                                               resultsLimit: Self.changesPageLimit)
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
        }, retry: { ids in
            var retried: [CKRecord.ID: Result<CKRecord?, any Error>] = [:]
            for start in stride(from: 0, to: ids.count, by: Self.batchLimit) {
                try Task.checkCancellation()
                let batch = Array(ids[start..<min(start + Self.batchLimit, ids.count)])
                let results = try await database.records(for: batch)
                for (id, result) in results {
                    if case .failure(let error) = result, (error as? CKError)?.code == .unknownItem {
                        retried[id] = .success(nil)
                    } else {
                        retried[id] = result.map { Optional($0) }
                    }
                }
            }
            return retried
        })
        zoneReader = reader
        accountObserver = RelayAccountObserver(name: .CKAccountChanged) {
            epoch.invalidate()
            zoneDeletion.forgetUnattributed()
        }
    }

    func accountStatus() async throws -> CKAccountStatus {
        let status = try await container.accountStatus()
        if status == .noAccount {
            accountEpoch.invalidate(); await zoneReader.invalidate(); restoredEpoch = nil; zoneReady = false
            zoneDeletion.forgetUnattributed()
        }
        return status
    }

    private func currentAccount() async -> String? {
        let epoch = accountEpoch.value
        if let knownAccount, knownAccount.epoch == epoch { return knownAccount.fingerprint }
        guard let fingerprint = try? await accountFingerprint() else { return nil }
        if accountEpoch.value == epoch { knownAccount = (epoch, fingerprint) }
        return fingerprint
    }

    private func deletionStands() async -> Bool {
        guard zoneDeletion.isRecorded else { return false }
        return zoneDeletion.stands(for: await currentAccount())
    }

    func accountFingerprint() async throws -> String {
        let id = try await container.userRecordID().recordName
        return SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func historyRecordName(for sourceID: String) -> String {
        "hist-\(sourceID)"
    }

    func alertPreferences() async throws -> AlertPreferences? {
        let started = zoneDeletion.generation
        do {
            let record = try await database.record(for: CKRecord.ID(recordName: Self.alertPreferencesRecord, zoneID: Self.zoneID))
            return (record[Field.payload] as? Data).flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) }
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        } catch {
            throw await notingDeletion(error, since: started)
        }
    }

    func contents(known: [String] = []) async throws -> Contents {
        guard queriesSources else { return try await zoneContents() }
        do {
            return try await directContents(known: known)
        } catch let refused as RelayDirectRead.QueryRefused {
            if refused.isLasting { queriesSources = false }
            return try await zoneContents()
        } catch is RelayDirectRead.ZoneMissing {
            return try await zoneContents()
        }
    }

    private func directContents(known: [String]) async throws -> Contents {
        let epoch = accountEpoch.value
        let database = database
        let names = (seenSources?.epoch == epoch ? seenSources?.names ?? [] : []).union(known)
        guard let records = try await zoneDeletion.read(account: { await self.currentAccount() }, {
            try await Self.directRecords(database, known: names)
        }) else {
            guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
            zoneReady = false
            seenSources = nil
            await zoneReader.invalidate(); restoredEpoch = nil
            return Contents(sources: [], histories: [:], deletedByUser: true)
        }
        guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
        let contents = Self.contents(from: records)
        seenSources = (epoch, Set(contents.sources.map(\.id)))
        return contents
    }

    private static func directRecords(_ database: CKDatabase, known: Set<String>) async throws -> [CKRecord] {
        do {
            return try await RelayDirectRead.records(
                known: known,
                companions: { [historyRecordName(for: $0)] },
                always: [alertPreferencesRecord],
                discover: {
                    do {
                        return try await sourceNames(database)
                    } catch where isQueryUnsupported(error) {
                        throw RelayDirectRead.QueryRefused(isLasting: (error as? CKError)?.code == .invalidArguments)
                    }
                },
                fetch: { try await records(database, named: $0) }
            )
        } catch let error as CKError where error.code == .zoneNotFound {
            throw RelayDirectRead.ZoneMissing()
        }
    }

    private static func sourceNames(_ database: CKDatabase) async throws -> Set<String> {
        var names: Set<String> = []
        var page = try await database.records(
            matching: CKQuery(recordType: RecordType.source, predicate: NSPredicate(format: "%K > %d", Field.schema, 0)),
            inZoneWith: zoneID, desiredKeys: [], resultsLimit: CKQueryOperation.maximumResults
        )
        var pages = 1
        while true {
            for (id, _) in page.matchResults { names.insert(id.recordName) }
            guard let cursor = page.queryCursor, pages < queryPageLimit else { break }
            try Task.checkCancellation()
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [], resultsLimit: CKQueryOperation.maximumResults)
            pages += 1
        }
        return names
    }

    private static func records(_ database: CKDatabase, named names: [String]) async throws -> [String: Result<CKRecord?, any Error>] {
        var answers: [String: Result<CKRecord?, any Error>] = [:]
        for start in stride(from: 0, to: names.count, by: batchLimit) {
            try Task.checkCancellation()
            let batch = names[start..<min(start + batchLimit, names.count)]
            let results = try await database.records(for: batch.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
            for (id, result) in results {
                switch result {
                case .success(let record):
                    answers[id.recordName] = .success(record)
                case .failure(let error as CKError) where error.code == .unknownItem:
                    answers[id.recordName] = .success(nil)
                case .failure(let error):
                    answers[id.recordName] = .failure(error)
                }
            }
        }
        return answers
    }

    static func isQueryUnsupported(_ error: any Error) -> Bool {
        guard let code = (error as? CKError)?.code else { return false }
        return code == .invalidArguments || code == .serverRejectedRequest || code == .unknownItem
    }

    func zoneContents() async throws -> Contents {
        let epoch = accountEpoch.value
        await restoreZone(for: epoch)
        let reader = zoneReader
        guard let records = try await zoneDeletion.read(account: { await self.currentAccount() }, {
            try await reader.contents(scope: epoch)
        }) else {
            guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
            zoneReady = false
            await zoneReader.invalidate(); restoredEpoch = nil
            return Contents(sources: [], histories: [:], deletedByUser: true)
        }
        guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
        return Self.contents(from: records.values)
    }

    static func contents(from records: some Collection<CKRecord>) -> Contents {
        var sources: [Source] = []
        var histories: [String: RelayHistory] = [:]
        var preferences: AlertPreferences?
        var events: [(id: String, createdAt: Date?)] = []
        for record in records {
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

    private func restoreZone(for epoch: UUID) async {
        guard let zoneArchive, restoredEpoch != epoch else { return }
        guard let account = await currentAccount(), accountEpoch.value == epoch else { return }
        restoredEpoch = epoch
        await zoneReader.restore(zoneArchive.load(account: account), scope: epoch) { saved in
            zoneArchive.save(saved, account: account)
        }
    }

    struct SourceRead: Sendable {
        var sources: [Source]
        var missing: Set<String>
    }

    func sources(named ids: [String]) async throws -> SourceRead {
        let epoch = accountEpoch.value
        let names = Array(Set(ids)).sorted()
        var found: [Source] = []
        var missing: Set<String> = []
        for start in stride(from: 0, to: names.count, by: Self.batchLimit) {
            try Task.checkCancellation()
            let batch = names[start..<min(start + Self.batchLimit, names.count)]
            let results = try await database.records(
                for: batch.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) },
                desiredKeys: [Field.payload, Field.kind, Field.label]
            )
            for (id, result) in results {
                switch result {
                case .success(let record) where record.recordType == RecordType.source:
                    found.append(Self.source(from: record))
                case .success:
                    missing.insert(id.recordName)
                case .failure(let error as CKError) where error.code == .unknownItem:
                    missing.insert(id.recordName)
                case .failure:
                    continue
                }
            }
        }
        guard epoch == accountEpoch.value, !Task.isCancelled else { throw CancellationError() }
        return SourceRead(sources: found.sorted { $0.id < $1.id }, missing: missing)
    }

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

    private func notingDeletion(_ error: any Error, since generation: Int) async -> any Error {
        if RelayZoneDeletion.isUserDeletedZone(error) {
            zoneReady = false
            zoneDeletion.mark(for: await currentAccount(), since: generation)
        }
        return error
    }

    private func zoneIsBack() {
        zoneReady = true
        zoneEpoch = accountEpoch.value
    }

    private func forgetZone() {
        zoneReady = false
        zoneEpoch = nil
    }

    private static func source(from record: CKRecord) -> Source {
        let (envelope, needsNewerApp) = (record[Field.payload] as? Data).map(RelayEnvelope.read) ?? (nil, false)
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

    @discardableResult
    func saveAlert(_ alert: UsageAlert) async throws -> Bool {
        if let scope = AlertDeliveryCoordinator.scope(for: alert) {
            return try await coordinatedDelivery(alert, scope: scope, mode: .pushed).created
        }
        let record = Self.eventRecord(id: alert.id, provider: alert.provider, level: alert.level, title: alert.title, body: alert.body,
                                      resetsAt: alert.resetsAt, kind: alert.kind.rawValue, key: alert.key)
        do {
            try await save([record], policy: .ifServerRecordUnchanged)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false
        }
    }

    private func coordinatedDelivery(_ alert: UsageAlert, scope: AlertDeliveryCoordinator.Scope,
                                     mode: AlertDeliveryCoordinator.Mode) async throws -> AlertDeliveryCoordinator.Receipt {
        let epoch = accountEpoch.value
        try checkAlertAccount(epoch)
        let receipt = try await AlertDeliveryCoordinator.deliver(alert, scope: scope, mode: mode, read: {
            try await self.deliveryRevision(scope.recordName, epoch: epoch)
        }, legacy: { ids in
            try await self.legacyDeliveryEvents(ids, epoch: epoch)
        }, write: { data, record, event in
            try await self.writeDelivery(data, record: record, event: event, alert: alert, epoch: epoch)
        }, isConflict: { error in
            Self.isPreferenceConflict(error) || (error as? CKError)?.code == .zoneNotFound
        })
        try checkAlertAccount(epoch)
        return receipt
    }

    private func checkAlertAccount(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard accountEpoch.value == epoch else { throw CancellationError() }
    }

    private func deliveryRevision(_ name: String, epoch: UUID) async throws -> AlertDeliveryCoordinator.Versioned<CKRecord> {
        try checkAlertAccount(epoch)
        let id = CKRecord.ID(recordName: name, zoneID: Self.zoneID)
        do {
            let record = try await database.record(for: id)
            try checkAlertAccount(epoch)
            guard record.recordType == RecordType.prefs, let data = record[Field.payload] as? Data else {
                throw AlertDeliveryCoordinator.Failure.damaged
            }
            return .init(data: data, revision: record)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            try checkAlertAccount(epoch)
            if error.code == .zoneNotFound { zoneReady = false; zoneEpoch = nil }
            return .init(data: nil, revision: CKRecord(recordType: RecordType.prefs, recordID: id))
        }
    }

    private func legacyDeliveryEvents(_ names: [String], epoch: UUID) async throws -> [AlertDeliveryCoordinator.LegacyEvent] {
        try checkAlertAccount(epoch)
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: Self.zoneID) }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do { results = try await database.records(for: ids) }
        catch let error as CKError where error.code == .zoneNotFound {
            try checkAlertAccount(epoch)
            zoneReady = false; zoneEpoch = nil
            return []
        }
        try checkAlertAccount(epoch)
        var events: [AlertDeliveryCoordinator.LegacyEvent] = []
        for id in ids {
            guard let result = results[id] else { throw ProviderError.parse }
            switch result {
            case .failure(let error):
                guard let code = (error as? CKError)?.code, code == .unknownItem || code == .zoneNotFound else { throw error }
            case .success(let record):
                guard record.recordType == RecordType.event,
                      let provider = record[Field.provider] as? String,
                      let kind = record[Field.alertKind] as? String,
                      let level = record[Field.level] as? Int,
                      let key = record[Field.alertKey] as? String else { throw ProviderError.parse }
                events.append(.init(id: id.recordName, provider: provider, kind: kind, level: level, key: key,
                                    resetsAt: record[Field.resetsAt] as? Date))
            }
        }
        return events
    }

    private func writeDelivery(_ data: Data, record: CKRecord, event: AlertDeliveryCoordinator.Receipt?,
                               alert: UsageAlert, epoch: UUID) async throws {
        let started = zoneDeletion.generation
        try checkAlertAccount(epoch)
        record[Field.payload] = data
        var records = [record]
        if let event {
            records.append(Self.eventRecord(id: event.eventID, provider: alert.provider, level: alert.level,
                                            title: alert.title, body: alert.body, resetsAt: alert.resetsAt,
                                            kind: alert.kind.rawValue, key: event.mode == .shown ? alert.shownKey : alert.key))
        }
        try await ensureZone()
        try checkAlertAccount(epoch)
        do { try await modify(records, policy: .ifServerRecordUnchanged) }
        catch let error as CKError where error.code == .zoneNotFound {
            try checkAlertAccount(epoch)
            zoneReady = false; zoneEpoch = nil
            throw error
        } catch {
            throw await notingDeletion(error, since: started)
        }
        try checkAlertAccount(epoch)
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

    func pruneEvents(now: Date = .now) async throws {
        let events: [(id: String, createdAt: Date?)]
        do {
            events = try await Self.eventDates(database)
        } catch where Self.isQueryUnsupported(error) {
            events = try await zoneContents().events
        }
        let old = events.filter { event in
            event.createdAt.map { now.timeIntervalSince($0) > Self.eventLifetime } ?? false
        }
        try await deleteRecords(named: old.map(\.id))
    }

    private static func eventDates(_ database: CKDatabase) async throws -> [(id: String, createdAt: Date?)] {
        var events: [(id: String, createdAt: Date?)] = []
        do {
            var page = try await database.records(
                matching: CKQuery(recordType: RecordType.event, predicate: NSPredicate(format: "%K != %@", Field.alertKey, "")),
                inZoneWith: zoneID, desiredKeys: [], resultsLimit: CKQueryOperation.maximumResults
            )
            var pages = 1
            while true {
                for case (let id, .success(let record)) in page.matchResults { events.append((id.recordName, record.creationDate)) }
                guard let cursor = page.queryCursor, pages < queryPageLimit else { break }
                try Task.checkCancellation()
                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [], resultsLimit: CKQueryOperation.maximumResults)
                pages += 1
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return []
        }
        return events
    }

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

    func deleteAllData() async throws {
        let results = try await database.modifyRecordZones(saving: [], deleting: [Self.zoneID])
        zoneReady = false
        zoneDeletion.clear(for: await currentAccount())
        for (_, result) in results.deleteResults {
            guard case .failure(let error) = result else { continue }
            let code = (error as? CKError)?.code
            if code != .zoneNotFound, code != .userDeletedZone {
                throw error
            }
        }
        await zoneReader.invalidate(); restoredEpoch = nil
    }

    func resetZone() async {
        zoneReady = false
        zoneDeletion.clear(for: await currentAccount())
    }

    private func save(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys) async throws {
        try await zoneDeletion.save(
            account: { await self.currentAccount() },
            ensureZone: { try await self.ensureZone() },
            modify: { try await self.modify(records, policy: policy) },
            zoneBack: { await self.zoneIsBack() },
            zoneGone: { await self.forgetZone() }
        )
    }

    private func modify(_ records: [CKRecord], policy: CKModifyRecordsOperation.RecordSavePolicy) async throws {
        let results = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: policy,
            atomically: true
        )
        if let failure = Self.prioritizedSaveFailure(Array(results.saveResults.values)) { throw failure }
    }

    static func prioritizedSaveFailure(_ results: [Result<CKRecord, any Error>]) -> (any Error)? {
        let failures = results.compactMap { result -> (any Error)? in
            if case .failure(let error) = result { return error }
            return nil
        }
        return failures.first(where: Self.isPreferenceConflict) ?? failures.first
    }

    private func ensureZone() async throws {
        let epoch = accountEpoch.value
        guard !zoneReady || zoneEpoch != epoch else { return }
        guard !(await deletionStands()) else { throw CKError(.userDeletedZone) }
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

    @discardableResult
    func ensureSubscriptions(alertKeys: [String]) async throws -> Bool {
        let previous = subscriptionsWrite
        let epoch = accountEpoch.value
        let task = Task {
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

        do {
            try await saveSubscriptions([alertSubscription(NSPredicate(format: "%K IN %@", Field.alertKey, alertKeys))])
            try checkSubscriptionWrite(epoch: epoch)
            return true
        } catch let error as CKError where error.code == .invalidArguments || error.code == .serverRejectedRequest {
            try checkSubscriptionWrite(epoch: epoch)
            try await saveSubscriptions([alertSubscription(NSPredicate(value: true))])
            try checkSubscriptionWrite(epoch: epoch)
            return false
        }
    }

    enum Claim: Equatable {
        case created
        case pushed
        case shownElsewhere
    }

    func claimAlert(_ alert: UsageAlert) async throws -> Claim {
        if let scope = AlertDeliveryCoordinator.scope(for: alert) {
            let receipt = try await coordinatedDelivery(alert, scope: scope, mode: .shown)
            if receipt.created { return .created }
            return receipt.mode == .shown ? .shownElsewhere : .pushed
        }
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
        visible.titleLocalizationKey = "%1$@"
        visible.titleLocalizationArgs = [Field.title]
        visible.alertLocalizationKey = "%1$@"
        visible.alertLocalizationArgs = [Field.body]
        visible.soundName = "default"
        alerts.notificationInfo = visible
        return alerts
    }

    private func saveSubscriptions(_ subscriptions: [CKSubscription]) async throws {
        let started = zoneDeletion.generation
        do {
            let results = try await database.modifySubscriptions(saving: subscriptions, deleting: [])
            for (_, result) in results.saveResults {
                if case .failure(let error) = result {
                    throw error
                }
            }
        } catch {
            throw await notingDeletion(error, since: started)
        }
    }
}
#endif

struct RelayZoneDeletion: @unchecked Sendable {
    static let key = "relayZoneDeletedForAccounts"
    static let generationKey = "relayZoneDeletionGeneration"
    private let defaults: UserDefaults
    private let unattributed = Flag()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var accounts: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    var isRecorded: Bool {
        unattributed.isSet || !accounts.isEmpty
    }

    var generation: Int {
        defaults.integer(forKey: Self.generationKey)
    }

    func stands(for account: String?) -> Bool {
        if unattributed.isSet { return true }
        guard let account else { return !accounts.isEmpty }
        return accounts.contains(account)
    }

    func mark(for account: String?, since generation: Int? = nil) {
        if let generation, generation != self.generation { return }
        guard let account, !account.isEmpty else {
            unattributed.isSet = true
            return
        }
        guard !accounts.contains(account) else { return }
        defaults.set(accounts + [account], forKey: Self.key)
    }

    func clear(for account: String? = nil) {
        unattributed.isSet = false
        if let account {
            let left = accounts.filter { $0 != account }
            if left.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(left, forKey: Self.key) }
        } else {
            defaults.removeObject(forKey: Self.key)
        }
        defaults.set(generation &+ 1, forKey: Self.generationKey)
    }

    func forgetUnattributed() {
        unattributed.isSet = false
    }

    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool {
            get { value.withLock { $0 } }
            set { value.withLock { $0 = newValue } }
        }
    }

    static func isUserDeletedZone(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .userDeletedZone { return true }
        guard error.code == .partialFailure else { return false }
        return error.partialErrorsByItemID?.values.contains(where: isUserDeletedZone) == true
    }

    func read<Records: Collection & Sendable>(
        account: @Sendable () async -> String?,
        _ read: @Sendable () async throws -> Records
    ) async throws -> Records? {
        let started = generation
        do {
            let records = try await read()
            if !records.isEmpty, isRecorded { clear(for: await account()) }
            return records
        } catch where Self.isUserDeletedZone(error) {
            mark(for: await account(), since: started)
            return nil
        }
    }

    func save(
        account: @Sendable () async -> String?,
        ensureZone: @Sendable () async throws -> Void,
        modify: @Sendable () async throws -> Void,
        zoneBack: @Sendable () async -> Void,
        zoneGone: @Sendable () async -> Void
    ) async throws {
        let started = generation
        if isRecorded {
            let signedIn = await account()
            if stands(for: signedIn) {
                do {
                    try await modify()
                } catch where Self.isUserDeletedZone(error) || (error as? CKError)?.code == .zoneNotFound {
                    throw CKError(.userDeletedZone)
                }
                clear(for: signedIn)
                await zoneBack()
                return
            }
        }
        try await ensureZone()
        do {
            try await modify()
        } catch let error as CKError where error.code == .zoneNotFound {
            await zoneGone()
            try await ensureZone()
            try await modify()
        } catch where Self.isUserDeletedZone(error) {
            await zoneGone()
            mark(for: await account(), since: started)
            throw error
        }
    }
}
