import Foundation

struct ClaudeStatusLineBridge: Sendable {
    enum BridgeError: Error, Equatable, LocalizedError {
        case invalidSettings
        case duplicateStatusLine
        case unsupportedFormat
        case brokenLink
        case linked(target: String, command: String)
        case linkedToRemove(target: String)
        case notWritable

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                "Couldn't change ~/.claude/settings.json: it isn't valid JSON. Fix it, then try again."
            case .duplicateStatusLine:
                "Couldn't change ~/.claude/settings.json: it sets statusLine more than once. Keep one, then try again."
            case .unsupportedFormat:
                "Couldn't change ~/.claude/settings.json without rewriting it. Save it as UTF-8 with no comma after its last setting, then try again."
            case .brokenLink:
                "Couldn't change ~/.claude/settings.json: it links to a file that isn't there."
            case .linked(let target, let command):
                "Couldn't change ~/.claude/settings.json: it links to \(target), which other Macs may share, so Tokenroom leaves it alone. To use the bridge here, set its statusLine command to \(command) yourself."
            case .linkedToRemove(let target):
                "Couldn't change ~/.claude/settings.json: it links to \(target), which other Macs may share, so Tokenroom leaves it alone. Remove the statusLine that runs Tokenroom's script from it yourself."
            case .notWritable:
                "Couldn't change ~/.claude/settings.json: it's read-only. Check its permissions, then try again."
            }
        }
    }

    let claudeDirectory: URL
    let bridgeDirectory: URL

    static let standard = ClaudeStatusLineBridge(
        claudeDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true),
        bridgeDirectory: SnapshotCache.defaultDirectory.appendingPathComponent("bridge", isDirectory: true)
    )

    var settingsURL: URL { claudeDirectory.appendingPathComponent("settings.json") }
    var scriptURL: URL { bridgeDirectory.appendingPathComponent("claude-statusline.sh") }
    var readingURL: URL { bridgeDirectory.appendingPathComponent("claude-rate-limits.json") }
    var previousCommandURL: URL { bridgeDirectory.appendingPathComponent("previous-command") }
    var previousStatusLineURL: URL { bridgeDirectory.appendingPathComponent("previous-statusline.json") }

    var command: String {
        "'\(scriptURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    var isInstalled: Bool {
        guard let file = try? loadSettings(), isOurs(file.settings["statusLine"]) else { return false }
        let count = file.original.flatMap { Self.utf8Text($0) }.flatMap { JSONTextEdit.count(of: "statusLine", in: $0.text) }
        return (count ?? 1) == 1
    }

    func install() throws {
        let fileManager = FileManager.default
        try refuseLinks(turningOff: false)
        try refuseUnwritable()
        try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
        removeFullBackups()
        var file = try loadSettings()
        let current = file.settings["statusLine"] as? [String: Any]
        var statusLine = current ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        file.settings["statusLine"] = statusLine
        let data = try Self.encoded(file)

        do {
            if !isOurs(current) {
                if let current {
                    try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]).write(to: previousStatusLineURL, options: .atomic)
                    try Data(((current["command"] as? String) ?? "").utf8).write(to: previousCommandURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: previousStatusLineURL)
                    try? fileManager.removeItem(at: previousCommandURL)
                }
            }
            try Data(Self.script.utf8).write(to: scriptURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            try fileManager.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.write(data, to: file.url)
        } catch {
            if !isOurs(current) {
                for url in [scriptURL, previousCommandURL, previousStatusLineURL] {
                    try? fileManager.removeItem(at: url)
                }
            }
            throw error
        }
    }

    func uninstall() throws {
        removeFullBackups()
        var file = try loadSettings()
        if isOurs(file.settings["statusLine"]) {
            try refuseLinks(turningOff: true)
            try refuseUnwritable()
            if let data = try? Data(contentsOf: previousStatusLineURL),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                file.settings["statusLine"] = previous
            } else {
                file.settings.removeValue(forKey: "statusLine")
            }
            try Self.write(try Self.encoded(file), to: file.url)
        }
        for url in [scriptURL, readingURL, previousCommandURL, previousStatusLineURL] + backupURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func refuseLinks(turningOff: Bool) throws {
        let fileManager = FileManager.default
        let target: URL
        if (try? fileManager.destinationOfSymbolicLink(atPath: settingsURL.path)) != nil {
            target = settingsURL.resolvingSymlinksInPath()
            if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil || !fileManager.fileExists(atPath: target.path) {
                throw BridgeError.brokenLink
            }
        } else if (try? fileManager.destinationOfSymbolicLink(atPath: claudeDirectory.path)) != nil {
            let folder = claudeDirectory.resolvingSymlinksInPath()
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                throw BridgeError.brokenLink
            }
            target = folder.appendingPathComponent(settingsURL.lastPathComponent)
        } else {
            return
        }
        let shown = (target.path as NSString).abbreviatingWithTildeInPath
        throw turningOff ? BridgeError.linkedToRemove(target: shown) : BridgeError.linked(target: shown, command: command)
    }

    private func refuseUnwritable() throws {
        let fileManager = FileManager.default
        for path in [settingsURL.path, claudeDirectory.path] where fileManager.fileExists(atPath: path) {
            guard fileManager.isWritableFile(atPath: path) else { throw BridgeError.notWritable }
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch let error as CocoaError where [.fileWriteNoPermission, .fileWriteVolumeReadOnly].contains(error.code) {
            throw BridgeError.notWritable
        } catch let error as CocoaError {
            if let posix = error.underlying as? POSIXError, [.EACCES, .EPERM, .EROFS].contains(posix.code) {
                throw BridgeError.notWritable
            }
            throw error
        }
    }

    func upgrade() {
        removeFullBackups()
        let script = Data(Self.script.utf8)
        guard let installed = try? Data(contentsOf: scriptURL), installed != script else { return }
        try? script.write(to: scriptURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func removeFullBackups() {
        let fileManager = FileManager.default
        for url in backupURLs() where (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil {
            try? fileManager.removeItem(at: url)
        }
    }

    func replacedLink() -> String? {
        let fileManager = FileManager.default
        guard (try? fileManager.destinationOfSymbolicLink(atPath: settingsURL.path)) == nil,
              let destination = backupURLs().lazy.compactMap({ try? fileManager.destinationOfSymbolicLink(atPath: $0.path) }).first
        else { return nil }
        let path = destination.hasPrefix("/") ? destination : claudeDirectory.appendingPathComponent(destination).standardizedFileURL.path
        return (path as NSString).abbreviatingWithTildeInPath
    }

    func forgetReplacedLink() {
        let fileManager = FileManager.default
        for url in backupURLs() where (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try? fileManager.removeItem(at: url)
        }
    }

    private func backupURLs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bridgeDirectory.path)) ?? []
        return names
            .filter { $0 == "settings.original.json" || ($0.hasPrefix("settings.backup-") && $0.hasSuffix(".json")) }
            .sorted()
            .map { bridgeDirectory.appendingPathComponent($0) }
    }

    func reading() -> ClaudeBridgeReading? {
        guard let data = try? Data(contentsOf: readingURL),
              let root = try? JSONFlex.object(from: data),
              let modified = (try? readingURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        let weekly = JSONFlex.dictionary(root["seven_day"])
        let session = JSONFlex.dictionary(root["five_hour"])
        let reading = ClaudeBridgeReading(
            weeklyUsed: JSONFlex.number(weekly?["used_percentage"]),
            weeklyResetsAt: JSONFlex.date(weekly?["resets_at"]),
            sessionUsed: JSONFlex.number(session?["used_percentage"]),
            sessionResetsAt: JSONFlex.date(session?["resets_at"]),
            at: modified
        )
        return reading.weeklyUsed == nil && reading.sessionUsed == nil ? nil : reading
    }

    private func isOurs(_ statusLine: Any?) -> Bool {
        guard let command = (statusLine as? [String: Any])?["command"] as? String else { return false }
        return command.contains(scriptURL.path)
    }

    private struct SettingsFile {
        var url: URL
        var original: Data?
        var settings: [String: Any]
    }

    private func loadSettings() throws -> SettingsFile {
        let url = settingsURL.resolvingSymlinksInPath()
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw BridgeError.brokenLink
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return SettingsFile(url: url, original: nil, settings: [:]) }
        guard let data = try? Data(contentsOf: url) else { throw BridgeError.invalidSettings }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return SettingsFile(url: url, original: nil, settings: [:])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeError.invalidSettings
        }
        return SettingsFile(url: url, original: data, settings: object)
    }

    private static func encoded(_ file: SettingsFile) throws -> Data {
        guard let original = file.original else {
            return try JSONSerialization.data(withJSONObject: file.settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        guard let decoded = utf8Text(original), let count = JSONTextEdit.count(of: "statusLine", in: decoded.text) else {
            throw BridgeError.unsupportedFormat
        }
        guard count <= 1 else { throw BridgeError.duplicateStatusLine }
        let edited: String?
        if let statusLine = file.settings["statusLine"] {
            edited = JSONTextEdit.setting("statusLine", to: statusLine, in: decoded.text)
        } else {
            edited = JSONTextEdit.removing("statusLine", in: decoded.text)
        }
        guard let edited else { throw BridgeError.unsupportedFormat }
        let data = Data((decoded.hasBOM ? utf8BOM : []) + Array(edited.utf8))
        guard let check = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NSDictionary(dictionary: check).isEqual(to: file.settings)
        else { throw BridgeError.unsupportedFormat }
        return data
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static func utf8Text(_ data: Data) -> (text: String, hasBOM: Bool)? {
        let hasBOM = data.starts(with: utf8BOM)
        let body = data.dropFirst(hasBOM ? utf8BOM.count : 0)
        let text = String(decoding: body, as: UTF8.self)
        guard !body.contains(0), text.utf8.elementsEqual(body) else { return nil }
        return (text, hasBOM)
    }

    func projectOverrides(limit: Int = 300) -> [URL] {
        let configURL = claudeDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any]
        else { return [] }
        var found: [URL] = []
        for path in projects.keys.sorted().prefix(limit) {
            let project = URL(fileURLWithPath: path, isDirectory: true)
            let folder = project.appendingPathComponent(".claude", isDirectory: true)
            let names = Self.isSameFolder(folder, claudeDirectory) ? ["settings.local.json"] : ["settings.json", "settings.local.json"]
            for name in names {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["statusLine"] != nil
                else { continue }
                found.append(project)
                break
            }
        }
        return found
    }

    private static func isSameFolder(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhs = lhs.resolvingSymlinksInPath()
        let rhs = rhs.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier
        else { return lhs.standardizedFileURL == rhs.standardizedFileURL }
        return left.isEqual(right)
    }

    static let script = """
    #!/bin/sh
    # Written by Tokenroom. Saves only the rate limits Claude Code passes to its status line,
    # then runs the status line you had before. Turn it off in Tokenroom Settings.
    dir="$(dirname "$0")"
    input="$(cat)"
    tmp="$dir/.rate-limits.$$"
    if printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o "$tmp" - >/dev/null 2>&1 &&
      { /usr/bin/plutil -extract seven_day.used_percentage raw -o - "$tmp" >/dev/null 2>&1 ||
        /usr/bin/plutil -extract five_hour.used_percentage raw -o - "$tmp" >/dev/null 2>&1; }; then
      mv -f "$tmp" "$dir/claude-rate-limits.json"
    else
      rm -f "$tmp"
    fi
    if [ -s "$dir/previous-command" ]; then
      printf '%s' "$input" | /bin/sh -c "$(cat "$dir/previous-command")"
    fi

    """
}

struct ClaudeBridgeReading: Equatable, Sendable {
    var weeklyUsed: Double?
    var weeklyResetsAt: Date?
    var sessionUsed: Double?
    var sessionResetsAt: Date?
    var at: Date

    func windows(now: Date = .now) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        if let weeklyUsed, (weeklyResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: JSONFlex.clampPercent(weeklyUsed), resetsAt: weeklyResetsAt, windowSeconds: 7 * 86_400))
        }
        if let sessionUsed, (sessionResetsAt ?? .distantFuture) > now {
            windows.append(QuotaWindow(id: "session", kind: .session, title: "Session", usedPercent: JSONFlex.clampPercent(sessionUsed), resetsAt: sessionResetsAt, windowSeconds: 5 * 3_600))
        }
        return windows
    }

    func weeklyHasReset(now: Date = .now) -> Bool {
        guard weeklyUsed != nil, let weeklyResetsAt else { return false }
        return weeklyResetsAt <= now
    }

    func snapshot(now: Date = .now) -> QuotaSnapshot? {
        guard !weeklyHasReset(now: now) else { return nil }
        let current = windows(now: now)
        guard let primary = current.first else { return nil }
        return QuotaSnapshot(
            provider: .claude,
            usedPercent: primary.usedPercent,
            resetsAt: primary.resetsAt,
            fetchedAt: at,
            primaryTitle: primary.title,
            windows: current,
            source: "bridge"
        )
    }
}
