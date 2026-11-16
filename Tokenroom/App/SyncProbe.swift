import AppKit
import CloudKit
import Foundation

enum SyncProbe {
    static let argument = "TokenroomSyncProbe"
    static let limit: TimeInterval = 240

    static var isRequested: Bool {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return (arguments[argument] as? String).map { ["YES", "1", "true"].contains($0) } ?? false
    }

    @MainActor
    static func runIfRequested() -> Bool {
        guard isRequested else { return false }
        let ownSource = UserDefaults.standard.string(forKey: RelayPublisher.Keys.sourceID)
        Task.detached {
            let report = await TimeLimit.run(limit, otherwise: ["probe stopped after \(Int(limit))s"]) {
                await run(containerIdentifier: RelayAvailability.containerIdentifier, ownSource: ownSource)
            }
            print(report.joined(separator: "\n"))
            fflush(stdout)
            exit(0)
        }
        return true
    }

    static func run(containerIdentifier: String?, ownSource: String?) async -> [String] {
        guard let containerIdentifier else { return ["no iCloud container in this build"] }
        var lines: [String] = []
        let container = CKContainer(identifier: containerIdentifier)
        let database = container.privateCloudDatabase

        let account = await timed { try await container.accountStatus() }
        lines.append("account \(account.result.map { String($0.rawValue) } ?? "failed \(code(account.error))") \(account.seconds)")
        guard account.result == .available else { return lines }

        if let ownSource {
            let cold = await timed { try await database.records(for: [recordID(ownSource)], desiredKeys: desiredKeys) }
            lines.append("by-name own cold \(describe(cold.result?.values.map { $0 })) \(cold.seconds)")
        }

        let queries: [(String, String, @Sendable () -> NSPredicate)] = [
            ("source all", CloudRelay.RecordType.source, { NSPredicate(value: true) }),
            ("source kind", CloudRelay.RecordType.source, { NSPredicate(format: "%K IN %@", CloudRelay.Field.kind, ["mac", "iphone"]) }),
            ("source checkedAt", CloudRelay.RecordType.source, { NSPredicate(format: "%K > %@", CloudRelay.Field.checkedAt, Date.distantPast as NSDate) }),
            ("source schema", CloudRelay.RecordType.source, { NSPredicate(format: "%K > %d", CloudRelay.Field.schema, 0) }),
            ("history schema", CloudRelay.RecordType.history, { NSPredicate(format: "%K > %d", CloudRelay.Field.schema, 0) }),
            ("event all", CloudRelay.RecordType.event, { NSPredicate(value: true) }),
            ("event alertKey", CloudRelay.RecordType.event, { NSPredicate(format: "%K != %@", CloudRelay.Field.alertKey, "") }),
        ]
        for (name, type, predicate) in queries {
            let query = await timed {
                try await database.records(matching: CKQuery(recordType: type, predicate: predicate()), inZoneWith: CloudRelay.zoneID)
            }
            if let answer = query.result {
                lines.append("query \(name) found \(answer.matchResults.count) more \(answer.queryCursor != nil) \(query.seconds)")
            } else {
                let reason = (query.error as? CKError)?.localizedDescription ?? ""
                lines.append("query \(name) failed \(code(query.error)) \(query.seconds) \(reason.prefix(120))")
            }
        }

        var records: [CKRecord.ID: CKRecord] = [:]
        let paged = await zoneRead(database, from: nil, resultsLimit: CloudRelay.changesPageLimit, records: &records)
        lines.append(contentsOf: paged.lines.map { "zone paged " + $0 })
        lines.append("zone paged total \(paged.pages) pages \(paged.seconds) records \(records.count)")

        var again: [CKRecord.ID: CKRecord] = [:]
        let whole = await zoneRead(database, from: nil, resultsLimit: nil, records: &again)
        lines.append("zone unpaged total \(whole.pages) pages \(whole.seconds) records \(again.count)")

        if let token = paged.token {
            var delta: [CKRecord.ID: CKRecord] = [:]
            let next = await zoneRead(database, from: token, resultsLimit: CloudRelay.changesPageLimit, records: &delta)
            lines.append("zone delta total \(next.pages) pages \(next.seconds) records \(delta.count)")
        }

        let sources = records.values.filter { $0.recordType == CloudRelay.RecordType.source }
        if !sources.isEmpty {
            let warm = await timed { try await database.records(for: sources.map(\.recordID), desiredKeys: desiredKeys) }
            lines.append("by-name all warm \(describe(warm.result?.values.map { $0 })) \(warm.seconds)")
        }

        let suite = "TokenroomSyncProbeRelay"
        if let defaults = UserDefaults(suiteName: suite) {
            defaults.removePersistentDomain(forName: suite)
            let relay = CloudRelay(containerIdentifier: containerIdentifier, zoneDeletion: RelayZoneDeletion(defaults: defaults))
            let cold = await timed { try await relay.contents() }
            lines.append("direct cold \(describe(cold.result)) \(cold.error.map(code) ?? "") \(cold.seconds)")
            let names = sources.map(\.recordID.recordName)
            let fresh = CloudRelay(containerIdentifier: containerIdentifier, zoneDeletion: RelayZoneDeletion(defaults: defaults))
            let warm = await timed { try await fresh.contents(known: names + ["src-00000000-0000-0000-0000-000000000000"]) }
            lines.append("direct known \(describe(warm.result)) \(warm.error.map(code) ?? "") \(warm.seconds)")
            let again = await timed { try await fresh.contents() }
            lines.append("direct again \(describe(again.result)) \(again.error.map(code) ?? "") \(again.seconds)")
            defaults.removePersistentDomain(forName: suite)
        }

        let now = Date.now
        let types = Dictionary(grouping: records.values, by: \.recordType).mapValues(\.count)
        lines.append("types " + types.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        for record in sources.sorted(by: { $0.recordID.recordName < $1.recordID.recordName }) {
            let own = record.recordID.recordName == ownSource ? " own" : ""
            let kind = record[CloudRelay.Field.kind] as? String ?? "?"
            let envelope = (record[CloudRelay.Field.payload] as? Data).flatMap { RelayEnvelope.read($0).envelope }
            lines.append("source \(kind)\(own) app \(envelope?.appVersion ?? "?") modified \(age(record.modificationDate, now)) envelope \(age(envelope?.checkedAt, now))")
            for provider in envelope?.providers ?? [] {
                lines.append("  \(provider.id) \(provider.state) checked \(age(provider.checkedAt ?? provider.fetchedAt, now)) windows \(provider.windows.count)")
            }
        }
        for record in records.values where record.recordType == CloudRelay.RecordType.history {
            let bytes = (record[CloudRelay.Field.payload] as? Data)?.count ?? 0
            lines.append("history modified \(age(record.modificationDate, now)) bytes \(bytes)")
        }
        return lines
    }

    private static let desiredKeys = [CloudRelay.Field.payload, CloudRelay.Field.kind, CloudRelay.Field.label]

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: CloudRelay.zoneID)
    }

    private struct ZoneRead {
        var lines: [String] = []
        var pages = 0
        var seconds = ""
        var token: CKServerChangeToken?
    }

    private static func zoneRead(_ database: CKDatabase, from start: CKServerChangeToken?, resultsLimit: Int?,
                                 records: inout [CKRecord.ID: CKRecord]) async -> ZoneRead {
        var read = ZoneRead()
        var cursor = start
        let clock = ContinuousClock()
        let began = clock.now
        while true {
            let token = cursor
            let page = await timed {
                try await database.recordZoneChanges(inZoneWith: CloudRelay.zoneID, since: token, resultsLimit: resultsLimit)
            }
            read.pages += 1
            guard let changes = page.result else {
                read.lines.append("page \(read.pages) failed \(code(page.error)) \(page.seconds)")
                break
            }
            var failed = 0
            var byType: [String: Int] = [:]
            for (id, result) in changes.modificationResultsByID {
                switch result {
                case .success(let modification):
                    records[id] = modification.record
                    byType[modification.record.recordType, default: 0] += 1
                case .failure:
                    failed += 1
                }
            }
            for deletion in changes.deletions { records[deletion.recordID] = nil }
            let types = byType.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            read.lines.append("page \(read.pages) \(page.seconds) modified \(changes.modificationResultsByID.count) [\(types)] failed \(failed) deleted \(changes.deletions.count) more \(changes.moreComing)")
            cursor = changes.changeToken
            read.token = changes.changeToken
            if !changes.moreComing { break }
        }
        read.seconds = seconds(clock.now - began)
        return read
    }

    private static func timed<T: Sendable>(_ work: @Sendable () async throws -> T) async -> (result: T?, error: (any Error)?, seconds: String) {
        let clock = ContinuousClock()
        let began = clock.now
        do {
            let result = try await work()
            return (result, nil, seconds(clock.now - began))
        } catch {
            return (nil, error, seconds(clock.now - began))
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.2fs", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    private static func code(_ error: (any Error)?) -> String {
        guard let error else { return "?" }
        if let cloud = error as? CKError { return "CKError \(cloud.code.rawValue)" }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }

    private static func describe(_ results: [Result<CKRecord, any Error>]?) -> String {
        guard let results else { return "failed" }
        let found = results.filter { if case .success = $0 { true } else { false } }.count
        return "found \(found) of \(results.count)"
    }

    private static func describe(_ contents: CloudRelay.Contents?) -> String {
        guard let contents else { return "failed" }
        let readable = contents.sources.filter { $0.envelope != nil }.count
        return "sources \(contents.sources.count) readable \(readable) histories \(contents.histories.count) preferences \(contents.alertPreferences != nil) deleted \(contents.deletedByUser)"
    }

    private static func age(_ date: Date?, _ now: Date) -> String {
        guard let date else { return "?" }
        let seconds = Int(now.timeIntervalSince(date))
        return seconds < 120 ? "\(seconds)s ago" : seconds < 7200 ? "\(seconds / 60)m ago" : "\(seconds / 3600)h ago"
    }
}
