import CloudKit
import Foundation

struct RelayZoneArchive: Sendable {
    typealias Saved = RelayZoneReader<CKRecord.ID, CKRecord, CKServerChangeToken>.Saved

    static let version = 1
    let url: URL

    static func defaultURL(containerIdentifier: String, bundle: Bundle = .main) -> URL? {
        guard bundle.bundleURL.pathExtension != "appex",
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let name = containerIdentifier.replacingOccurrences(of: "/", with: "-")
        return support.appendingPathComponent("Tokenroom", isDirectory: true)
            .appendingPathComponent("relay-zone-\(name).archive")
    }

    func load(account: String) -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let saved = Self.decode(data, account: account) else {
            remove()
            return nil
        }
        return saved
    }

    func save(_ saved: Saved?, account: String) {
        guard let saved else {
            remove()
            return
        }
        guard let data = Self.encode(saved, account: account) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(macOS)
        try? data.write(to: url, options: .atomic)
        #else
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #endif
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func encode(_ saved: Saved, account: String) -> Data? {
        var root: [String: Any] = [
            "v": version,
            "account": account,
            "records": Array(saved.records.values),
            "quarantined": Array(saved.quarantined),
        ]
        if let pass = saved.pass { root["pass"] = Array(pass) }
        if let token = saved.token { root["token"] = token }
        return try? NSKeyedArchiver.archivedData(withRootObject: root as NSDictionary, requiringSecureCoding: true)
    }

    static func decode(_ data: Data, account: String) -> Saved? {
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSNull.self,
                                   CKRecord.self, CKRecord.ID.self, CKServerChangeToken.self]
        guard let root = (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)) as? [String: Any],
              root["v"] as? Int == version, root["account"] as? String == account,
              let records = root["records"] as? [CKRecord],
              let quarantined = root["quarantined"] as? [CKRecord.ID]
        else { return nil }
        let token = root["token"] as? CKServerChangeToken
        let pass = (root["pass"] as? [CKRecord.ID]).map(Set.init)
        guard records.allSatisfy({ $0.recordID.zoneID == CloudRelay.zoneID }) else { return nil }
        return Saved(records: Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { _, last in last }),
                     quarantined: Set(quarantined), token: token, pass: pass)
    }
}
