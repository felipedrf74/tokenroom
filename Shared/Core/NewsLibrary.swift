import Foundation
import Observation

struct SavedSkillMetadata: Codable, Equatable, Sendable {
    var owner: String
    var slug: String
    var version: String?
    var requirements: [String]
    var ranking: String?
    var checkedAt: Date?
}

/// The UI retains its last reversible removal until another persistence operation succeeds.
@MainActor struct NewsRemovalUndo {
    private(set) var items: [NewsBookmark] = []
    var item: NewsBookmark? { items.first }
    @discardableResult mutating func remove(id: String, aliases: Set<String> = [], from library: NewsLibrary) -> Bool {
        guard let removed = library.remove(id: id, aliases: aliases) else { return false }
        items = removed
        return true
    }
    @discardableResult mutating func save(_ bookmark: NewsBookmark, in library: NewsLibrary) -> Bool {
        guard library.save(bookmark) else { return false }
        items = []
        return true
    }
    @discardableResult mutating func restore(in library: NewsLibrary) -> Bool {
        guard !items.isEmpty, library.restore(items) else { return false }
        items = []
        return true
    }
}

struct NewsBookmark: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case story, model, skill }
    var id: String
    var aliases: Set<String>
    var kind: Kind
    var title: String
    var publisher: String
    var url: URL?
    var summary: String?
    var publishedAt: Date?
    var updatedAt: Date?
    var savedAt: Date
    var skill: SavedSkillMetadata? = nil
}

/// Device-local reading metadata. It has no relay or network dependency.
@Observable @MainActor final class NewsLibrary {
    static let fileName = "news-library.json"
    static let sizeLimit = 4 * 1024 * 1024
    private struct ReadEntry: Codable { var ids: Set<String>; var date: Date }
    private struct Document: Codable { var version = 1; var saved: [NewsBookmark] = []; var read: [ReadEntry] = [] }
    private var document = Document()
    private var blocksWrites = false
    private let directory: URL?
    @ObservationIgnored private let writer: (Data, URL) throws -> Void
    private(set) var problem: String?
    /// A damaged library is a shared problem; failed actions belong to their controls.
    var loadProblem: String? { blocksWrites ? problem : nil }
    var saved: [NewsBookmark] { document.saved.sorted { $0.savedAt > $1.savedAt } }

    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Tokenroom/News"),
         writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory
        self.writer = writer
        guard let file = directory?.appendingPathComponent(Self.fileName), FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard size <= Self.sizeLimit else { throw CocoaError(.fileReadCorruptFile) }
            let value = try RelayEnvelope.decoder.decode(Document.self, from: Data(contentsOf: file))
            guard Self.valid(value) else { throw CocoaError(.fileReadCorruptFile) }
            document = value
        } catch {
            blocksWrites = true
            problem = "Saved library couldn't be read. The original file has been kept."
        }
    }

    private static func valid(_ item: NewsBookmark) -> Bool {
        !item.id.isEmpty && !item.title.isEmpty && item.title.count <= 10_000 && item.aliases.count <= 100 &&
        (item.summary?.count ?? 0) <= 2000 &&
        (item.url == nil || FeedParser.webLink(item.url!.absoluteString, feed: URL(string: "https://example.com")!) != nil)
    }
    private static func valid(_ value: Document) -> Bool {
        value.version == 1 && value.saved.count <= 500 && value.read.count <= 5000 &&
        Set(value.saved.map(\.id)).count == value.saved.count && value.saved.allSatisfy(Self.valid)
    }
    private func persist(_ candidate: Document) -> Bool {
        guard !blocksWrites else { return false }
        do {
            guard Self.valid(candidate) else {
                problem = "This change exceeds the library's metadata limits. Previous items are still available."
                return false
            }
            let data = try RelayEnvelope.encoder.encode(candidate)
            guard data.count <= Self.sizeLimit else {
                problem = "Your saved library is full. Remove an item before saving more metadata."
                return false
            }
            if let directory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try writer(data, directory.appendingPathComponent(Self.fileName))
            }
            document = candidate
            problem = nil
            return true
        } catch {
            problem = "Couldn't save the library. Your previous saved items are still available."
            return false
        }
    }
    func isSaved(id: String, aliases: Set<String> = []) -> Bool {
        let ids = aliases.union([id])
        return document.saved.contains { !ids.isDisjoint(with: $0.aliases.union([$0.id])) }
    }
    @discardableResult func save(_ raw: NewsBookmark) -> Bool {
        guard !blocksWrites else { return false }
        var raw = raw
        raw.summary = raw.summary.map { String($0.prefix(2000)) }
        guard Self.valid(raw) else { problem = "This item has invalid saved metadata."; return false }
        var candidate = document
        let group = connected(to: raw.aliases.union([raw.id]))
        if let first = group.indices.first {
            // Keep the original snapshot/date; fold every record connected through aliases
            // in a single transaction. Validation rejects overflow without truncating IDs.
            let retainedID = candidate.saved[first].id
            candidate.saved[first].aliases.formUnion(group.ids.subtracting([retainedID]))
            for index in group.indices.dropFirst().reversed() { candidate.saved.remove(at: index) }
            return persist(candidate)
        }
        guard candidate.saved.count < 500 else { problem = "You have 500 saved items. Remove an item before saving another."; return false }
        candidate.saved.append(raw)
        return persist(candidate)
    }
    private func connected(to seed: Set<String>) -> (ids: Set<String>, indices: [Int]) {
        var ids = seed, indices: Set<Int> = []
        var changed = true
        while changed {
            changed = false
            for (index, item) in document.saved.enumerated() where !indices.contains(index) {
                let identity = item.aliases.union([item.id])
                if !ids.isDisjoint(with: identity) {
                    indices.insert(index); ids.formUnion(identity); changed = true
                }
            }
        }
        return (ids, indices.sorted())
    }
    /// A displayed folded story can bridge previously independent saved copies.
    @discardableResult func remove(id: String, aliases: Set<String>) -> [NewsBookmark]? {
        let group = connected(to: aliases.union([id]))
        guard !group.indices.isEmpty else { return nil }
        let removed = group.indices.map { document.saved[$0] }
        var candidate = document
        for index in group.indices.reversed() { candidate.saved.remove(at: index) }
        return persist(candidate) ? removed : nil
    }
    /// Restore exact snapshots together, preserving savedAt and any newer unrelated saves.
    /// An exact-ID conflict or capacity/write failure leaves both the library and Undo intact.
    @discardableResult func restore(_ items: [NewsBookmark]) -> Bool {
        guard !items.isEmpty else { return false }
        var candidate = document
        for item in items {
            if let existing = candidate.saved.first(where: { $0.id == item.id }) {
                guard existing == item else { problem = "A saved item changed since removal. Your current library has been kept."; return false }
            } else { candidate.saved.append(item) }
        }
        return persist(candidate)
    }
    @discardableResult func remove(id: String) -> NewsBookmark? {
        var candidate = document
        guard let index = candidate.saved.firstIndex(where: { $0.id == id || $0.aliases.contains(id) }) else { return nil }
        let item = candidate.saved.remove(at: index)
        return persist(candidate) ? item : nil
    }
    @discardableResult func restore(_ item: NewsBookmark) -> Bool { save(item) }
    func isRead(id: String, aliases: Set<String> = []) -> Bool {
        document.read.contains { !$0.ids.isDisjoint(with: aliases.union([id])) }
    }
    func markRead(id: String, aliases: Set<String> = []) {
        markReadEntries([(id, aliases)])
    }
    func markAllRead(_ items: [FeedItem]) { markReadEntries(items.map { ($0.stableID, $0.aliasIDs) }) }
    private func markReadEntries(_ entries: [(String, Set<String>)]) {
        var candidate = document
        for (id, aliases) in entries {
            var ids = aliases.union([id])
            let matching = candidate.read.filter { !$0.ids.isDisjoint(with: ids) }
            matching.forEach { ids.formUnion($0.ids) }
            candidate.read.removeAll { !$0.ids.isDisjoint(with: ids) }
            candidate.read.append(ReadEntry(ids: ids, date: .now))
        }
        candidate.read = Array(candidate.read.sorted { $0.date > $1.date }.prefix(5000))
        _ = persist(candidate)
    }
}
