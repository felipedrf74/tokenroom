import Foundation

@MainActor
final class HistoryStore {
    static let recentCapacity = 72

    private(set) var weeks: [String: UsageHistory] = [:]
    private var recent: [String: [(date: Date, used: Double)]] = [:]
    private var dirty = false
    private var taken: [String: Date] = [:]
    private var held: Set<String> = []
    private var hasExposedConflict = false
    private var lastClaim = 0
    private var unloaded = false
    private var unsaved: [Observation] = []
    private var recoveryDirty = false
    private var recoveryUnreadable = false
    private var recoveryOnDisk = false
    private var nextUnsavedPrune = Date.distantPast
    private var clock = Date.distantPast
    private let fileURL: URL?

    init(directory: URL?) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        switch Self.read([String: UsageHistory].self, from: fileURL) {
        case .value(let saved):
            weeks = Self.migrated(saved)
            dirty = weeks != saved
        case .missing:
            break
        case .unavailable:
            unloaded = true
        }
        switch Self.read(Recovery.self, from: recoveryURL, preserveMalformed: true) {
        case .value(let recovery):
            restoreRecovery(recovery)
        case .unavailable:
            recoveryUnreadable = true
            unloaded = true
        case .missing:
            break
        }
    }

    nonisolated static let fileName = "history.json"

    private nonisolated static let recoveryName = "history-recovery.json"

    private var recoveryURL: URL? {
        fileURL?.deletingLastPathComponent().appendingPathComponent(Self.recoveryName)
    }

    private struct FileRevision: Codable, Equatable {
        let inode: UInt64
        let modified: Double
        let size: UInt64

        init?(_ url: URL?) {
            guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else { return nil }
            self.inode = inode.uint64Value
            self.modified = modified.timeIntervalSinceReferenceDate
            self.size = size.uint64Value
        }
    }

    private struct Observation: Codable, Equatable {
        var snapshot: QuotaSnapshot
        let revision: FileRevision?

        init(snapshot: QuotaSnapshot, revision: FileRevision?) {
            self.snapshot = snapshot
            self.revision = revision
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.snapshot) {
                snapshot = try values.decode(QuotaSnapshot.self, forKey: .snapshot)
                revision = try values.decodeIfPresent(FileRevision.self, forKey: .revision)
            } else {
                snapshot = try QuotaSnapshot(from: decoder)
                revision = nil
            }
        }

        func reconciling(with saved: [String: UsageHistory], revision current: FileRevision?) -> QuotaSnapshot {
            guard revision == nil || revision != current else { return snapshot }
            var result = snapshot
            for index in result.windows.indices {
                let key = RelayHistory.key(provider: result.provider.rawValue, window: result.windows[index].id)
                if let checked = saved[key]?.amountCheckedAt, checked == result.fetchedAt {
                    result.windows[index].amount = nil
                }
            }
            return result
        }
    }

    private struct Recovery: Codable {
        var clock: Date
        var samples: [Observation]
        var claimed: [String: Date]
        var waiting: Set<String>

        func apply(to weeks: inout [String: UsageHistory], revision: FileRevision?) {
            let saved = weeks
            var recovered: [String: UsageHistory] = [:]
            for sample in samples {
                let reading = sample.reconciling(with: saved, revision: revision)
                _ = HistoryStore.fold(reading, into: &weeks, now: clock)
                _ = HistoryStore.fold(reading, into: &recovered, now: clock)
            }
            for (key, history) in recovered where history.amountUnit == weeks[key]?.amountUnit {
                weeks[key]?.restoreMissingAmounts(from: history)
            }
            let cutoff = clock.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
            weeks = weeks.filter { $0.value.end > cutoff }
        }
    }

    nonisolated static func load(from directory: URL?) -> [String: UsageHistory] {
        guard case .value(let saved) = read([String: UsageHistory].self, from: directory?.appendingPathComponent(fileName)) else { return [:] }
        return migrated(saved)
    }

    private nonisolated static func diskWeeks(from directory: URL?, claimed: inout Set<String>) -> [String: UsageHistory] {
        var weeks = load(from: directory)
        switch read(Recovery.self, from: directory?.appendingPathComponent(recoveryName)) {
        case .value(let recovery):
            recovery.apply(to: &weeks, revision: FileRevision(directory?.appendingPathComponent(fileName)))
            claimed = Set(recovery.claimed.keys)
        case .unavailable:
            if let directory {
                claimed = Set((queuedFiles(in: directory.appendingPathComponent(takingFolderName)) ?? []).map(\.name))
            }
        case .missing:
            break
        }
        return weeks
    }

    private enum Saved<Value> {
        case value(Value)
        case missing
        case unavailable
    }

    private nonisolated static func read<Value: Decodable>(_ type: Value.Type, from url: URL?, preserveMalformed: Bool = false) -> Saved<Value> {
        guard let url else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            return .value(try RelayEnvelope.decoder.decode(type, from: data))
        } catch is DecodingError where preserveMalformed {
            let preserved = url.appendingPathExtension("damaged-" + UUID().uuidString)
            return move(url, to: preserved) == 0 ? .missing : .unavailable
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unavailable
        }
    }

    private func restoreRecovery(_ recovery: Recovery) {
        clock = max(clock, recovery.clock)
        unsaved = recovery.samples + unsaved
        taken.merge(recovery.claimed) { _, newer in newer }
        held.formUnion(recovery.waiting)
        for name in recovery.claimed.keys {
            lastClaim = max(lastClaim, QueuedFile(URL(fileURLWithPath: name)).claim)
        }
        unloaded = false
        let saved = Self.load(from: fileURL?.deletingLastPathComponent())
        let revision = FileRevision(fileURL)
        for sample in unsaved { record(sample.reconciling(with: saved, revision: revision), now: clock) }
        var restored = saved
        Recovery(clock: clock, samples: unsaved, claimed: taken, waiting: held).apply(to: &restored, revision: revision)
        weeks = restored
        unloaded = true
        recoveryOnDisk = true
    }

    private func loadSavedIfUnloaded() -> Bool {
        guard unloaded else { return true }
        if recoveryUnreadable {
            switch Self.read(Recovery.self, from: recoveryURL, preserveMalformed: true) {
            case .value(let recovery): restoreRecovery(recovery)
            case .missing: break
            case .unavailable:
                if !unsaved.isEmpty, case .value(let saved) = Self.read([String: UsageHistory].self, from: fileURL), let fileURL {
                    var updated = Self.migrated(saved)
                    Recovery(clock: clock, samples: unsaved, claimed: [:], waiting: []).apply(to: &updated, revision: FileRevision(fileURL))
                    do {
                        if updated != saved { try RelayEnvelope.encoder.encode(updated).write(to: fileURL, options: .atomic) }
                        weeks = updated
                        unsaved.removeAll()
                        recoveryDirty = false
                    } catch { return false }
                }
                return false
            }
            recoveryUnreadable = false
        }
        let recovery = Recovery(clock: clock, samples: unsaved, claimed: taken, waiting: held)
        if recoveryDirty, let recoveryURL {
            do {
                try RelayEnvelope.encoder.encode(recovery).write(to: recoveryURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                return false
            }
            recoveryDirty = false
            recoveryOnDisk = true
        }
        guard !hasExposedConflict else { return false }
        let saved: [String: UsageHistory]
        switch Self.read([String: UsageHistory].self, from: fileURL) {
        case .value(let existing): saved = existing
        case .missing: saved = [:]
        case .unavailable: return false
        }
        var restored = Self.migrated(saved)
        recovery.apply(to: &restored, revision: FileRevision(fileURL))
        do {
            if restored != saved, let fileURL {
                try RelayEnvelope.encoder.encode(restored).write(to: fileURL, options: .atomic)
            }
            discardTaken()
            guard taken.isEmpty else { return false }
            if recoveryOnDisk, let recoveryURL {
                try FileManager.default.removeItem(at: recoveryURL)
            }
        } catch {
            return false
        }
        weeks = restored
        unloaded = false
        recoveryOnDisk = false
        unsaved = []
        dirty = false
        return true
    }

    private func keepUnsaved(_ snapshot: QuotaSnapshot, now: Date) {
        clock = max(clock, now)
        if clock >= nextUnsavedPrune {
            let cutoff = clock.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
            unsaved.removeAll { $0.snapshot.fetchedAt < cutoff }
            nextUnsavedPrune = clock.addingTimeInterval(UsageHistory.step)
        }
        let windows = snapshot.windows.map { window in
            var window = window
            window.title = ""
            return window
        }
        let sample = QuotaSnapshot(provider: snapshot.provider, usedPercent: 0, fetchedAt: snapshot.fetchedAt,
                                   primaryTitle: "", windows: windows)
        let observation = Observation(snapshot: sample, revision: FileRevision(fileURL))
        if unsaved.last != observation {
            unsaved.append(observation)
        }
    }

    private nonisolated static func migrated(_ saved: [String: UsageHistory]) -> [String: UsageHistory] {
        var weeks = saved
        for (key, week) in weeks {
            let providerID = String(key.split(separator: "/").first ?? "")
            weeks[key] = week.migratingLegacyAmounts(for: providerID)
        }
        let copilot = Provider.copilot.rawValue
        let old = RelayHistory.key(provider: copilot, window: CopilotBilling.legacyWindowID)
        guard let week = weeks[old] else { return weeks }
        weeks[old] = nil
        let current = RelayHistory.key(provider: copilot, window: CopilotBilling.windowID)
        if weeks[current] == nil {
            weeks[current] = week
        }
        return weeks
    }

    func record(_ snapshot: QuotaSnapshot) {
        record(snapshot, now: .now)
    }

    @discardableResult
    func record(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
        record(snapshot, now: now, alreadyQueued: false)
    }

    @discardableResult
    private func record(_ snapshot: QuotaSnapshot, now: Date, alreadyQueued: Bool) -> Bool {
        guard Self.accepts(snapshot, now: now) else { return false }
        if unloaded {
            keepUnsaved(snapshot, now: now)
            if !alreadyQueued || recoveryOnDisk { recoveryDirty = true }
        }
        if Self.fold(snapshot, into: &weeks, now: now) {
            dirty = true
        }
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var samples = recent[key] ?? []
            if let last = samples.last, last.date >= snapshot.fetchedAt {
                var low = 0
                var high = samples.count - 1
                while low < high {
                    let middle = (low + high) / 2
                    if samples[middle].date < snapshot.fetchedAt {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                if samples[low].date == snapshot.fetchedAt {
                    samples[low].used = window.usedPercent
                } else {
                    samples.insert((snapshot.fetchedAt, window.usedPercent), at: low)
                }
            } else {
                samples.append((snapshot.fetchedAt, window.usedPercent))
            }
            if samples.count > Self.recentCapacity {
                samples.removeFirst(samples.count - Self.recentCapacity)
            }
            recent[key] = samples
        }
        prune(now: now)
        return true
    }

    nonisolated static func accepts(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
        snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step)
    }

    nonisolated static func fold(_ snapshot: QuotaSnapshot, into weeks: inout [String: UsageHistory], now: Date) -> Bool {
        guard accepts(snapshot, now: now) else { return false }
        var anyChanged = false
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var week = weeks[key] ?? UsageHistory(endingAt: snapshot.fetchedAt)
            if week.start > now {
                week = UsageHistory(endingAt: snapshot.fetchedAt)
            }
            let previous = week
            var changed = week.record(window.usedPercent, at: snapshot.fetchedAt)
            if let amount = window.amount, let remaining = amount.remainingOrComputed, amount.unit == "usd" || amount.unit == "cny" {
                changed = week.recordAmount(remaining, unit: amount.unit, at: snapshot.fetchedAt) || changed
            }
            let length = window.resetsAt.flatMap {
                Pace.windowLength(kind: window.kind, resetsAt: $0, startsAt: window.startsAt, windowSeconds: window.windowSeconds)
            }
            changed = week.recordResetTime(window.resetsAt, used: window.usedPercent, length: length, at: snapshot.fetchedAt) || changed
            if changed || week != previous || weeks[key] == nil {
                weeks[key] = week
                anyChanged = true
            }
        }
        return anyChanged
    }

    nonisolated static let pendingFolderName = "history-pending"
    nonisolated static let takingFolderName = "history-taking"
    nonisolated static let heldExtension = "held"

    nonisolated static func pending(in directory: URL?) -> [QuotaSnapshot] {
        pending(in: directory, excluding: [])
    }

    private nonisolated static func pending(in directory: URL?, excluding claimed: Set<String>) -> [QuotaSnapshot] {
        guard let directory else { return [] }
        let taken = (queuedFiles(in: directory.appendingPathComponent(takingFolderName)) ?? []).sorted { $0.claim < $1.claim }
        let saved = latestSaved(among: taken)
        var readings: [(snapshot: QuotaSnapshot, slot: String, claim: Int)] = taken.compactMap { file in
            file.saved == nil && !claimed.contains(file.name) ? queuedSnapshot(at: file.url).map { ($0, file.slot, file.claim) } : nil
        }
        readings += (queuedFiles(in: directory.appendingPathComponent(pendingFolderName)) ?? []).compactMap { file in
            queuedSnapshot(at: file.url).map { ($0, file.slot, Int.max) }
        }
        return readings.enumerated()
            .sorted { ($0.element.snapshot.fetchedAt, $0.offset) < ($1.element.snapshot.fetchedAt, $1.offset) }
            .map(\.element)
            .filter { reading in
                saved[reading.slot].map { !isBehind($0, time: reading.snapshot.fetchedAt, claim: reading.claim) } ?? true
            }
            .map(\.snapshot)
    }

    @discardableResult
    nonisolated static func queue(_ snapshots: [QuotaSnapshot], in directory: URL?, now: Date = .now) -> HistoryQueueOutcome {
        var outcome = HistoryQueueOutcome()
        guard !snapshots.isEmpty else { return outcome }
        guard let directory else {
            outcome.failures = snapshots.map { .init($0, CocoaError(.fileNoSuchFile)) }
            return outcome
        }
        let folder = directory.appendingPathComponent(pendingFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for snapshot in snapshots {
            let hour = Int(UsageHistory.hourStart(snapshot.fetchedAt).timeIntervalSince1970)
            let url = folder.appendingPathComponent("\(snapshot.provider.rawValue)-\(hour).json")
            if let queued = queuedSnapshot(at: url), queued.fetchedAt > snapshot.fetchedAt { continue }
            do {
                let data = try RelayEnvelope.encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                outcome.queued.append(snapshot)
            } catch {
                outcome.failures.append(.init(snapshot, error))
            }
        }
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        for file in queuedFiles(in: folder) ?? [] where (file.hour ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
        return outcome
    }

    private struct QueuedFile {
        let url: URL
        let slot: String
        let claim: Int
        let saved: Date?

        init(_ url: URL) {
            self.url = url
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 4, parts[parts.count - 1] == "saved", let time = UInt64(parts[parts.count - 2]),
               let claim = Int(parts[parts.count - 3]), claim >= 0 {
                slot = parts.dropLast(3).joined(separator: ".")
                self.claim = claim
                saved = Date(timeIntervalSinceReferenceDate: Double(bitPattern: time))
            } else if let dot = name.lastIndex(of: "."), let claim = Int(name[name.index(after: dot)...]), claim > 0 {
                slot = String(name[..<dot])
                self.claim = claim
                saved = nil
            } else {
                slot = name
                claim = 0
                saved = nil
            }
        }

        func savedName(at time: Date) -> String {
            "\(slot).\(claim).\(time.timeIntervalSinceReferenceDate.bitPattern).saved.\(HistoryStore.heldExtension)"
        }

        var name: String { url.lastPathComponent }

        var isHeld: Bool { url.pathExtension == HistoryStore.heldExtension }

        var heldURL: URL { url.deletingPathExtension().appendingPathExtension(HistoryStore.heldExtension) }

        var hour: Date? {
            guard let dash = slot.lastIndex(of: "-"), let seconds = TimeInterval(slot[slot.index(after: dash)...]) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private nonisolated static func queuedFiles(in folder: URL) -> [QueuedFile]? {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" || $0.pathExtension == heldExtension }.map(QueuedFile.init)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            return nil
        }
    }

    private nonisolated static func latestSaved(among files: [QueuedFile]) -> [String: QueuedFile] {
        var latest: [String: QueuedFile] = [:]
        for file in files {
            guard let time = file.saved else { continue }
            if let other = latest[file.slot], isBehind(other, time: time, claim: file.claim) { continue }
            latest[file.slot] = file
        }
        return latest
    }

    private nonisolated static func isBehind(_ file: QueuedFile, time: Date, claim: Int) -> Bool {
        guard let saved = file.saved else { return false }
        return (time, claim) < (saved, file.claim)
    }

    private nonisolated static func queuedSnapshot(at url: URL) -> QuotaSnapshot? {
        (try? Data(contentsOf: url)).flatMap { try? RelayEnvelope.decoder.decode(QuotaSnapshot.self, from: $0) }
    }

    private enum Queued {
        case reading(QuotaSnapshot)
        case invalid
        case missing
        case unreadable
    }

    private nonisolated static func queued(at url: URL) -> Queued {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        guard let snapshot = try? RelayEnvelope.decoder.decode(QuotaSnapshot.self, from: data) else { return .invalid }
        return .reading(snapshot)
    }

    nonisolated static let claimAttempts = 16

    nonisolated static func claim(_ url: URL, slot: String, in taking: URL, after claim: Int) -> Int? {
        for next in (claim + 1)...(claim + claimAttempts) {
            switch move(url, to: taking.appendingPathComponent("\(slot).\(next).json")) {
            case 0: return next
            case EEXIST: continue
            default: return nil
            }
        }
        return nil
    }

    private nonisolated static func move(_ url: URL, to destination: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
    }

    nonisolated static func loadWithPending(from directory: URL?, now: Date) -> [String: UsageHistory] {
        var claimed = Set<String>()
        var weeks = diskWeeks(from: directory, claimed: &claimed)
        for snapshot in pending(in: directory, excluding: claimed) {
            _ = fold(snapshot, into: &weeks, now: now)
        }
        return weeks
    }

    func takePending(now: Date = .now) {
        guard let directory = fileURL?.deletingLastPathComponent() else { return }
        _ = loadSavedIfUnloaded()
        guard !recoveryUnreadable else { return }
        let taking = directory.appendingPathComponent(Self.takingFolderName, isDirectory: true)
        let queued = Self.queuedFiles(in: directory.appendingPathComponent(Self.pendingFolderName)) ?? []
        if !queued.isEmpty {
            try? FileManager.default.createDirectory(at: taking, withIntermediateDirectories: true)
            if let claimed = Self.queuedFiles(in: taking) {
                lastClaim = max(lastClaim, claimed.map(\.claim).max() ?? 0)
                for file in queued {
                    if let claim = Self.claim(file.url, slot: file.slot, in: taking, after: lastClaim) {
                        lastClaim = claim
                    }
                }
            }
        }
        if let files = Self.queuedFiles(in: taking) {
            recordTaken(files, now: now)
        }
        guard !taken.isEmpty else { return }
        saveIfNeeded()
    }

    private func recordTaken(_ files: [QueuedFile], now: Date) {
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        var readings: [(file: QueuedFile, snapshot: QuotaSnapshot)] = []
        var saved: [QueuedFile] = []
        var waiting: Set<String> = []
        var exposed: Set<String> = []
        let earlierClaims = recoveryOnDisk ? taken : [:]
        let earlierWaiting = recoveryOnDisk ? held : []
        for file in files {
            if (file.hour ?? .distantPast) < cutoff {
                discard(file)
                continue
            }
            if file.saved != nil {
                saved.append(file)
                continue
            }
            switch Self.queued(at: file.url) {
            case .reading(let snapshot):
                if taken[file.name] != nil || Self.accepts(snapshot, now: now) {
                    readings.append((file, snapshot))
                } else {
                    discard(file)
                }
            case .invalid:
                discard(file)
            case .missing:
                taken[file.name] = nil
            case .unreadable:
                waiting.insert(file.slot)
                if !hold(file) { exposed.insert(file.slot) }
            }
        }
        readings.sort { ($0.snapshot.fetchedAt, $0.file.claim) < ($1.snapshot.fetchedAt, $1.file.claim) }
        var latest: [String: String] = [:]
        for reading in readings {
            latest[reading.file.slot] = reading.file.name
        }
        let floors = Self.latestSaved(among: saved)
        for (file, snapshot) in readings {
            let behind = floors[file.slot].map { Self.isBehind($0, time: snapshot.fetchedAt, claim: file.claim) } ?? false
            if behind || latest[file.slot] != file.name {
                if !discard(file) {
                    waiting.insert(file.slot)
                    if !hold(file) { exposed.insert(file.slot) }
                }
            } else if !exposed.contains(file.slot), taken[file.name] == nil, record(snapshot, now: now, alreadyQueued: true) {
                taken[file.name] = snapshot.fetchedAt
            }
        }
        for file in saved where floors[file.slot]?.name != file.name || !waiting.contains(file.slot) {
            discard(file)
        }
        held = waiting
        if recoveryOnDisk, earlierClaims != taken || earlierWaiting != held { recoveryDirty = true }
        hasExposedConflict = files.contains { exposed.contains($0.slot) && taken[$0.name] != nil }
    }

    private func hold(_ file: QueuedFile) -> Bool {
        guard !file.isHeld else { return true }
        let held = file.heldURL
        guard Self.move(file.url, to: held) == 0 else { return false }
        if let time = taken.removeValue(forKey: file.name) {
            taken[held.lastPathComponent] = time
        }
        return true
    }

    @discardableResult
    private func discard(_ file: QueuedFile) -> Bool {
        guard Self.remove(file.url) else { return false }
        taken[file.name] = nil
        return true
    }

    private nonisolated static func remove(_ url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil || !FileManager.default.fileExists(atPath: url.path)
    }

    private func discardTaken() {
        guard !taken.isEmpty, let directory = fileURL?.deletingLastPathComponent() else { return }
        let taking = directory.appendingPathComponent(Self.takingFolderName, isDirectory: true)
        for (name, time) in taken {
            let file = QueuedFile(taking.appendingPathComponent(name))
            if held.contains(file.slot) {
                let moved = Self.move(file.url, to: taking.appendingPathComponent(file.savedName(at: time)))
                if moved == 0 || (moved == EEXIST && Self.remove(file.url)) || !FileManager.default.fileExists(atPath: file.url.path) {
                    taken[name] = nil
                }
            } else if Self.remove(file.url) {
                taken[name] = nil
            }
        }
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        let gone = weeks.compactMap { key, week in week.end <= cutoff ? key : nil }
        guard !gone.isEmpty else { return }
        for key in gone {
            weeks[key] = nil
            recent[key] = nil
        }
        dirty = true
    }

    func samples(provider: Provider, window: String) -> [(date: Date, used: Double)] {
        let key = RelayHistory.key(provider: provider.rawValue, window: window)
        if let recent = recent[key], recent.count >= 3 {
            return recent
        }
        return weeks[key]?.points ?? []
    }

    func weeks(for provider: Provider) -> [String: UsageHistory] {
        let prefix = RelayHistory.key(provider: provider.rawValue, window: "")
        var result: [String: UsageHistory] = [:]
        for (key, week) in weeks where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = week
        }
        return result
    }

    func relayHistory(for providers: [Provider]) -> RelayHistory {
        let ids = Set(providers.map(\.rawValue))
        return RelayHistory(series: weeks.filter { key, week in
            guard let provider = key.split(separator: "/").first else { return false }
            return ids.contains(String(provider)) && !week.isEmpty
        })
    }

    @discardableResult
    func saveIfNeeded() -> Bool {
        guard !hasExposedConflict, loadSavedIfUnloaded() else { return false }
        if dirty {
            guard let fileURL else { return false }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try RelayEnvelope.encoder.encode(weeks).write(to: fileURL, options: .atomic)
            } catch {
                return false
            }
            dirty = false
        }
        discardTaken()
        return true
    }
}
