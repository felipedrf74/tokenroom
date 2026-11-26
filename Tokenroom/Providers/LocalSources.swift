import Foundation
import SQLite3

enum LocalSources {
    static func vscodeState(_ key: String, database: URL, copy: (URL) -> URL? = copyDatabase) -> String? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        switch sqliteRead(key, path: database.path) {
        case .value(let value):
            return value
        case .missing:
            return nil
        case .unreadable:
            guard let copied = copy(database) else { return nil }
            defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
            return sqliteValue(key, path: copied.path)
        }
    }

    enum SQLiteRead: Equatable {
        case value(String)
        case missing
        case unreadable
    }

    static func sqliteValue(_ key: String, path: String) -> String? {
        guard case .value(let value) = sqliteRead(key, path: path) else { return nil }
        return value
    }

    static func sqliteRead(_ key: String, path: String) -> SQLiteRead {
        var database: OpaquePointer?
        let encoded = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?"))) ?? path
        if sqlite3_open_v2("file://\(encoded)?mode=ro", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            if let database { sqlite3_close(database) }
            database = nil
            if sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                if let database { sqlite3_close(database) }
                return .unreadable
            }
        }
        guard let database else { return .unreadable }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_500)
        _ = sqlite3_exec(database, "PRAGMA query_only = ON", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return .unreadable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_text(statement, 0) else { return .missing }
            let value = String(cString: bytes)
            return value.isEmpty ? .missing : .value(value)
        case SQLITE_DONE:
            return .missing
        default:
            return .unreadable
        }
    }

    private static func copyDatabase(_ source: URL) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomState-\(UUID().uuidString)", isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            for suffix in ["-wal", "-shm"] {
                let extra = URL(fileURLWithPath: source.path + suffix)
                if FileManager.default.fileExists(atPath: extra.path) {
                    try FileManager.default.copyItem(at: extra, to: URL(fileURLWithPath: destination.path + suffix))
                }
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    static func fileStamp(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate
        else { return nil }
        let size = values.fileSize ?? 0
        return "\(Int(modified.timeIntervalSince1970))-\(size)"
    }

    static func claudeSettingsKey(forHosts hosts: [String], claudeDirectory: URL = defaultClaudeDirectory) -> String? {
        let url = claudeDirectory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONFlex.object(from: data),
              let env = JSONFlex.dictionary(root["env"]),
              let base = JSONFlex.string(env["ANTHROPIC_BASE_URL"]),
              let host = URL(string: base)?.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return nil }
        let key = JSONFlex.string(env["ANTHROPIC_AUTH_TOKEN"]) ?? JSONFlex.string(env["ANTHROPIC_API_KEY"])
        return key?.isEmpty == false ? key : nil
    }

    static var defaultClaudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }

    static func jsonString(at path: [String], in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), var current = try? JSONSerialization.jsonObject(with: data) else { return nil }
        for component in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[component] else { return nil }
            current = next
        }
        guard let value = current as? String, !value.isEmpty else { return nil }
        return value
    }

    static func semanticVersion(in text: String) -> [Int]? {
        var rest = text[...]
        while let range = rest.range(of: #"(?<![\d.])\d+(\.\d+)+(?!\.?\d)"#, options: .regularExpression) {
            let parts = rest[range].split(separator: ".").compactMap { Int($0) }
            if let major = parts.first, major < 1000 {
                return parts
            }
            rest = rest[range.upperBound...]
        }
        return nil
    }

    static func version(_ version: [Int], isAtLeast minimum: [Int]) -> Bool {
        for index in 0..<max(version.count, minimum.count) {
            let left = index < version.count ? version[index] : 0
            let right = index < minimum.count ? minimum[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    static func runJSONCommand(_ executable: URL, arguments: [String], timeout: TimeInterval = 20, maxOutput: Int = 1 << 20) -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TokenroomCLI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Tooling.searchPATH
        environment["NO_COLOR"] = "1"
        let output = BlockingIO.runProcess(executable, arguments: arguments, timeout: timeout, currentDirectory: folder, environment: environment, maxOutput: maxOutput)
        guard output.succeeded, !output.stdout.isEmpty else { return nil }
        return output.stdout
    }
}
