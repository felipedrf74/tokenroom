import Foundation

@MainActor
final class HistoryStore {
    static let recentCapacity = 72

    private(set) var weeks: [String: UsageHistory] = [:]
    private var recent: [String: [(date: Date, used: Double)]] = [:]
    private var dirty = false
    private var taken: [String: Date] = [:]
    private var held: Set<String> = []
    private var lastClaim = 0
    private let fileURL: URL?

    init(directory: URL?) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        let saved = Self.loadSaved(from: directory)
        weeks = Self.migrated(saved)
        dirty = weeks != saved
    }

    nonisolated static let fileName = "history.json"

    nonisolated static func load(from directory: URL?) -> [String: UsageHistory] {
        migrated(loadSaved(from: directory))
    }

    private nonisolated static func loadSaved(from directory: URL?) -> [String: UsageHistory] {
        guard let url = directory?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url),
              let saved = try? RelayEnvelope.decoder.decode([String: UsageHistory].self, from: data)
        else { return [:] }
        return saved
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

    func record(_ snapshot: QuotaSnapshot, now: Date) {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return }
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
    }

    nonisolated static func fold(_ snapshot: QuotaSnapshot, into weeks: inout [String: UsageHistory], now: Date) -> Bool {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return false }
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

    nonisolated static func pending(in directory: URL?) -> [QuotaSnapshot] {
        guard let directory else { return [] }
        let taken = (queuedFiles(in: directory.appendingPathComponent(takingFolderName)) ?? []).sorted { $0.claim < $1.claim }
        let saved = latestSaved(among: taken)
        var readings: [(snapshot: QuotaSnapshot, slot: String, claim: Int)] = taken.compactMap { file in
            file.saved == nil ? queuedSnapshot(at: file.url).map { ($0, file.slot, file.claim) } : nil
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

    nonisolated static func queue(_ snapshots: [QuotaSnapshot], in directory: URL?, now: Date = .now) {
        guard !snapshots.isEmpty, let directory else { return }
        let folder = directory.appendingPathComponent(pendingFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for snapshot in snapshots {
            let hour = Int(UsageHistory.hourStart(snapshot.fetchedAt).timeIntervalSince1970)
            let url = folder.appendingPathComponent("\(snapshot.provider.rawValue)-\(hour).json")
            if let queued = queuedSnapshot(at: url), queued.fetchedAt > snapshot.fetchedAt { continue }
            guard let data = try? RelayEnvelope.encoder.encode(snapshot) else { continue }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        for file in queuedFiles(in: folder) ?? [] where (file.hour ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
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
            "\(slot).\(claim).\(time.timeIntervalSinceReferenceDate.bitPattern).saved.json"
        }

        var name: String { url.lastPathComponent }

        var hour: Date? {
            guard let dash = slot.lastIndex(of: "-"), let seconds = TimeInterval(slot[slot.index(after: dash)...]) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private nonisolated static func queuedFiles(in folder: URL) -> [QueuedFile]? {
        do {
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.map(QueuedFile.init)
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
        var weeks = load(from: directory)
        for snapshot in pending(in: directory) {
            _ = fold(snapshot, into: &weeks, now: now)
        }
        return weeks
    }

    func takePending(now: Date = .now) {
        guard let directory = fileURL?.deletingLastPathComponent() else { return }
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
                readings.append((file, snapshot))
            case .invalid:
                discard(file)
            case .missing:
                taken[file.name] = nil
            case .unreadable:
                waiting.insert(file.slot)
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
                if !discard(file) { waiting.insert(file.slot) }
            } else if taken[file.name] == nil {
                record(snapshot, now: now)
                taken[file.name] = snapshot.fetchedAt
            }
        }
        for file in saved where floors[file.slot]?.name != file.name || !waiting.contains(file.slot) {
            discard(file)
        }
        held = waiting
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
