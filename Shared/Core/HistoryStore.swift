import Foundation

/// A week of hourly usage per window, kept in `history.json` next to the readings cache (the Mac's
/// Application Support folder, the iPhone's App Group), plus the last six hours of raw readings in
/// memory for pace. Percentages only.
@MainActor
final class HistoryStore {
    /// Raw readings kept for pace: six hours at a five-minute refresh.
    static let recentCapacity = 72

    private(set) var weeks: [String: UsageHistory] = [:]
    private var recent: [String: [(date: Date, used: Double)]] = [:]
    private var dirty = false
    /// Files in `history-taking/` this store has recorded and not yet deleted, by name.
    private var taken: Set<String> = []
    private var lastClaim = 0
    private let fileURL: URL?

    init(directory: URL?) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        let saved = Self.loadSaved(from: directory)
        weeks = Self.migrated(saved)
        // Written back under the new keys with the next save.
        dirty = weeks != saved
    }

    nonisolated static let fileName = "history.json"

    /// The saved weeks, keyed `provider/window`, for readers that don't record (widgets).
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

    /// Copilot's month read with a token was `ai_credits` in 2.0.0; its week carries on under the
    /// ID the login and the token both use now.
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

    /// - Parameter now: this device's clock. A reading dated more than an hour after it (a
    ///   file's time, or the clock set back since) is left out: it would move the week past
    ///   every later reading.
    func record(_ snapshot: QuotaSnapshot, now: Date) {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return }
        if Self.fold(snapshot, into: &weeks, now: now) {
            dirty = true
        }
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var samples = recent[key] ?? []
            if samples.last?.date == snapshot.fetchedAt {
                samples[samples.count - 1].used = window.usedPercent
            } else {
                samples.append((snapshot.fetchedAt, window.usedPercent))
                if samples.count > Self.recentCapacity {
                    samples.removeFirst(samples.count - Self.recentCapacity)
                }
            }
            recent[key] = samples
        }
        prune(now: now)
    }

    /// One reading into the weeks it belongs to; whether anything changed. The store records
    /// through it, and widgets use it to show readings the app hasn't taken in yet.
    nonisolated static func fold(_ snapshot: QuotaSnapshot, into weeks: inout [String: UsageHistory], now: Date) -> Bool {
        guard snapshot.fetchedAt <= now.addingTimeInterval(UsageHistory.step) else { return false }
        var anyChanged = false
        for window in snapshot.windows {
            let key = RelayHistory.key(provider: snapshot.provider.rawValue, window: window.id)
            var week = weeks[key] ?? UsageHistory(endingAt: snapshot.fetchedAt)
            // A week that ran ahead of the clock takes every new reading for one older than
            // itself, so it starts over.
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

    // MARK: Readings widgets took

    /// Readings widgets took with this iPhone's keys, waiting for the app to record them: a file
    /// per provider and hour, holding the hour's latest reading. The app is the one writer of
    /// `history.json`, so a widget never races it for that file, and widgets write files of their
    /// own rather than rewriting a shared list.
    nonisolated static let pendingFolderName = "history-pending"
    /// Where the app moves queued readings while it records them: one a widget queues meanwhile
    /// waits for the next refresh, and ones a refresh cut short are recorded by the next. Each
    /// gets a name of its own there (`QueuedFile`), which only the app writes: a widget can't
    /// replace a file the app is reading or about to delete.
    nonisolated static let takingFolderName = "history-taking"

    /// The readings waiting, oldest first; of two with one time, the one queued later last.
    nonisolated static func pending(in directory: URL?) -> [QuotaSnapshot] {
        guard let directory else { return [] }
        let files = queuedFiles(in: directory.appendingPathComponent(takingFolderName)).sorted { $0.claim < $1.claim }
            + queuedFiles(in: directory.appendingPathComponent(pendingFolderName))
        return files.compactMap { queuedSnapshot(at: $0.url) }.enumerated()
            .sorted { ($0.element.fetchedAt, $0.offset) < ($1.element.fetchedAt, $1.offset) }
            .map(\.element)
    }

    /// Adds readings a widget took, for the app to record the next time it refreshes. A later
    /// reading of a provider in the same hour takes an earlier one's place, and readings older
    /// than the week history holds are dropped.
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
        for file in queuedFiles(in: folder) where (file.hour ?? .distantPast) < cutoff {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    /// A queued reading's file. A widget names it `<provider>-<hour>.json`; the app moves it to
    /// `<provider>-<hour>.<claim>.json`, the claim counting up, so each one it takes keeps a file
    /// of its own and the order it was taken in. One moved by 2.6.4 or earlier kept the widget's
    /// name and comes first.
    private struct QueuedFile {
        let url: URL
        let slot: String
        let claim: Int

        init(_ url: URL) {
            self.url = url
            let name = url.deletingPathExtension().lastPathComponent
            if let dot = name.lastIndex(of: "."), let claim = Int(name[name.index(after: dot)...]), claim > 0 {
                slot = String(name[..<dot])
                self.claim = claim
            } else {
                slot = name
                claim = 0
            }
        }

        var name: String { url.lastPathComponent }

        var hour: Date? {
            guard let dash = slot.lastIndex(of: "-"), let seconds = TimeInterval(slot[slot.index(after: dash)...]) else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    private nonisolated static func queuedFiles(in folder: URL) -> [QueuedFile] {
        let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return (files ?? []).filter { $0.pathExtension == "json" }.map(QueuedFile.init)
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

    /// One `rename` to a name nothing else has, before the file is read: whatever a widget
    /// queues from then on is another file.
    private nonisolated static func claim(_ url: URL, as destination: URL) {
        url.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return }
                _ = rename(from, to)
            }
        }
    }

    /// The saved weeks with the readings widgets took since, for a widget to show.
    nonisolated static func loadWithPending(from directory: URL?, now: Date) -> [String: UsageHistory] {
        var weeks = load(from: directory)
        for snapshot in pending(in: directory) {
            _ = fold(snapshot, into: &weeks, now: now)
        }
        return weeks
    }

    /// Records the readings widgets took, oldest first. Called before this refresh's own, which
    /// are newer. They're moved aside first, so one a widget queues meanwhile stays queued, and
    /// deleted only once the week is saved, so a refresh cut short loses none.
    func takePending(now: Date = .now) {
        guard let directory = fileURL?.deletingLastPathComponent() else { return }
        let taking = directory.appendingPathComponent(Self.takingFolderName, isDirectory: true)
        let queued = Self.queuedFiles(in: directory.appendingPathComponent(Self.pendingFolderName))
        if !queued.isEmpty {
            try? FileManager.default.createDirectory(at: taking, withIntermediateDirectories: true)
            lastClaim = max(lastClaim, Self.queuedFiles(in: taking).map(\.claim).max() ?? 0)
            for file in queued {
                lastClaim += 1
                Self.claim(file.url, as: taking.appendingPathComponent("\(file.slot).\(lastClaim).json"))
            }
        }
        let cutoff = now.addingTimeInterval(-Double(UsageHistory.capacity) * UsageHistory.step)
        var readings: [(file: QueuedFile, snapshot: QuotaSnapshot)] = []
        for file in Self.queuedFiles(in: taking) {
            if (file.hour ?? .distantPast) < cutoff {
                discard(file)
                continue
            }
            switch Self.queued(at: file.url) {
            case .reading(let snapshot):
                readings.append((file, snapshot))
            case .invalid:
                discard(file)
            case .missing:
                taken.remove(file.name)
            case .unreadable:
                break
            }
        }
        readings.sort { ($0.snapshot.fetchedAt, $0.file.claim) < ($1.snapshot.fetchedAt, $1.file.claim) }
        var latest: [String: String] = [:]
        for reading in readings {
            latest[reading.file.slot] = reading.file.name
        }
        for (file, snapshot) in readings {
            if latest[file.slot] != file.name {
                // An hour keeps its latest reading, as it does in the widgets' queue.
                discard(file)
            } else if !taken.contains(file.name) {
                record(snapshot, now: now)
                taken.insert(file.name)
            }
        }
        guard !taken.isEmpty else { return }
        saveIfNeeded()
    }

    private func discard(_ file: QueuedFile) {
        if (try? FileManager.default.removeItem(at: file.url)) != nil { taken.remove(file.name) }
    }

    private func discardTaken() {
        guard !taken.isEmpty, let directory = fileURL?.deletingLastPathComponent() else { return }
        let taking = directory.appendingPathComponent(Self.takingFolderName, isDirectory: true)
        for name in taken {
            let url = taking.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil || !FileManager.default.fileExists(atPath: url.path) {
                taken.remove(name)
            }
        }
    }

    /// Forgets windows with no reading in the last week: ones a provider stopped reporting,
    /// or providers turned off. They'd otherwise be saved and relayed forever.
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

    /// Readings for pace: raw recent ones, else the hourly week.
    func samples(provider: Provider, window: String) -> [(date: Date, used: Double)] {
        let key = RelayHistory.key(provider: provider.rawValue, window: window)
        if let recent = recent[key], recent.count >= 3 {
            return recent
        }
        return weeks[key]?.points ?? []
    }

    /// One provider's weeks, keyed by window ID.
    func weeks(for provider: Provider) -> [String: UsageHistory] {
        let prefix = RelayHistory.key(provider: provider.rawValue, window: "")
        var result: [String: UsageHistory] = [:]
        for (key, week) in weeks where key.hasPrefix(prefix) {
            result[String(key.dropFirst(prefix.count))] = week
        }
        return result
    }

    /// History to relay, limited to the given providers.
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
