import Foundation
import Security

struct PhoneSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
    var tokenURL: URL
    var clientID: String
}

struct PhoneSessionMetadata: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        case exchanging
        case rejected
    }

    var addedAt: Date
    var state: State
    var clientRefused: Bool? = nil
}

struct PhoneSessionStore: Sendable {
    enum SessionError: Error, Equatable {
        case keychain(OSStatus)
        case encoding
    }

    var accessGroup: String
    var servicePrefix = "app.tokenroom.ios.session."
    var recoveryService = "app.tokenroom.ios.session-recovery"
    var keychain: KeychainOperations = .system

    static let account = "default"
    static let probeAccount = "writable-probe"
    static let rejectedMarker = Data("rejected".utf8)

    static func accessGroup(plistValue: String?, sharedGroup: String?) -> String? {
        guard let value = plistValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("),
              value != sharedGroup
        else { return nil }
        return value
    }

    static func make(plistValue: String?, sharedGroup: String?, keychain: KeychainOperations = .system) -> PhoneSessionStore? {
        accessGroup(plistValue: plistValue, sharedGroup: sharedGroup).map {
            PhoneSessionStore(accessGroup: $0, keychain: keychain)
        }
    }

    func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    func query(for provider: Provider) -> [String: Any] {
        base(service: service(for: provider), account: Self.account)
    }

    func recoveryQuery(for provider: Provider) -> [String: Any] {
        base(service: recoveryService, account: provider.rawValue)
    }

    private func base(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    func session(for provider: Provider) -> PhoneSession? {
        decodeSession(readData(query(for: provider)))
    }

    func metadata(for provider: Provider) -> PhoneSessionMetadata? {
        readAttributes(query(for: provider)).flatMap(Self.decodeMetadata)
    }

    enum Lookup: Equatable, Sendable {
        case found(PhoneSessionMetadata)
        case none
        case unreadable
    }

    func lookup(for provider: Provider) -> Lookup {
        var query = query(for: provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        switch status {
        case errSecSuccess:
            guard let attributes = item as? [String: Any], let metadata = Self.decodeMetadata(attributes) else { return .unreadable }
            return .found(metadata)
        case errSecItemNotFound:
            return .none
        default:
            return .unreadable
        }
    }

    func hasSession(for provider: Provider) -> Bool {
        session(for: provider) != nil
    }

    func canReplace(_ provider: Provider) -> Bool {
        let query = query(for: provider)
        if let attributes = readAttributes(query) {
            guard let generic = attributes[kSecAttrGeneric as String] as? Data else { return false }
            return keychain.update(query, [kSecAttrGeneric as String: generic]) == errSecSuccess
        }
        var probe = base(service: service(for: provider), account: Self.probeAccount)
        let probeQuery = probe
        probe[kSecValueData as String] = Data("ok".utf8)
        let added = keychain.add(probe)
        let deleted = keychain.delete(probeQuery)
        guard added == errSecSuccess else { return false }
        return deleted == errSecSuccess || deleted == errSecItemNotFound
    }

    @discardableResult
    func setState(_ state: PhoneSessionMetadata.State, for provider: Provider) -> Bool {
        let query = query(for: provider)
        guard var metadata = metadata(for: provider) else { return false }
        metadata.state = state
        guard let generic = try? JSONEncoder().encode(metadata) else { return false }
        return keychain.update(query, [kSecAttrGeneric as String: generic]) == errSecSuccess
    }

    func save(_ session: PhoneSession, for provider: Provider, now: Date) throws {
        try write(session, metadata: PhoneSessionMetadata(addedAt: now, state: .ready), to: query(for: provider), provider: provider)
    }

    func saveRecovery(_ session: PhoneSession, for provider: Provider) -> Bool {
        let metadata = PhoneSessionMetadata(addedAt: metadata(for: provider)?.addedAt ?? .now, state: .exchanging)
        return (try? write(session, metadata: metadata, to: recoveryQuery(for: provider), provider: provider)) != nil
    }

    func takeRecovery(for provider: Provider) -> PhoneSession? {
        decodeSession(readData(recoveryQuery(for: provider)))
    }

    enum RecoveryLookup: Equatable, Sendable {
        case found(PhoneSession)
        case none
        case unreadable
    }

    func recoveryLookup(for provider: Provider) -> RecoveryLookup {
        var query = recoveryQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        switch status {
        case errSecSuccess:
            return decodeSession(item as? Data).map(RecoveryLookup.found) ?? .none
        case errSecInteractionNotAllowed:
            return .unreadable
        default:
            return .none
        }
    }

    func deleteRecovery(for provider: Provider) {
        _ = keychain.delete(recoveryQuery(for: provider))
    }

    func clearRecovery(for provider: Provider) throws {
        let status = keychain.delete(recoveryQuery(for: provider))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionError.keychain(status) }
    }

    func finishFromRecovery(for provider: Provider) -> Bool {
        guard let recovered = takeRecovery(for: provider) else { return false }
        let addedAt = metadata(for: provider)?.addedAt ?? .now
        do {
            try write(recovered, metadata: PhoneSessionMetadata(addedAt: addedAt, state: .ready), to: query(for: provider), provider: provider)
        } catch {
            return false
        }
        deleteRecovery(for: provider)
        return true
    }

    func markRejected(for provider: Provider, now: Date, clientRefused: Bool = false) {
        let query = query(for: provider)
        let addedAt = metadata(for: provider)?.addedAt ?? now
        let metadata = PhoneSessionMetadata(addedAt: addedAt, state: .rejected, clientRefused: clientRefused ? true : nil)
        guard let generic = try? JSONEncoder().encode(metadata) else { return }
        let attributes: [String: Any] = [kSecValueData as String: Self.rejectedMarker, kSecAttrGeneric as String: generic]
        if keychain.update(query, attributes) == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            _ = keychain.add(item)
        }
    }

    func remove(for provider: Provider) throws {
        let status = keychain.delete(query(for: provider))
        deleteRecovery(for: provider)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionError.keychain(status) }
    }

    static let retiredProviders: [Provider] = [.claude]

    @discardableResult
    func purgeRetired(_ providers: [Provider] = Self.retiredProviders) -> Bool {
        let inUse = Set(PhoneConnect.productionAllowlist.map(PhoneSignIn.sessionOwner)).union(PhoneConnect.productionAllowlist)
        var cleared = true
        for provider in providers where !inUse.contains(provider) {
            let items = [
                query(for: provider),
                recoveryQuery(for: provider),
                base(service: service(for: provider), account: Self.probeAccount),
            ]
            for item in items {
                let status = keychain.delete(item)
                if status != errSecSuccess && status != errSecItemNotFound { cleared = false }
            }
        }
        return cleared
    }

    private func write(_ session: PhoneSession, metadata: PhoneSessionMetadata, to query: [String: Any], provider: Provider) throws {
        guard !session.refreshToken.isEmpty,
              let data = try? JSONEncoder().encode(session),
              let generic = try? JSONEncoder().encode(metadata)
        else { throw SessionError.encoding }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrGeneric as String: generic]
        var status = keychain.update(query, attributes)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            item[kSecAttrLabel as String] = "Tokenroom · \(provider.displayName) session"
            status = keychain.add(item)
        }
        guard status == errSecSuccess else { throw SessionError.keychain(status) }
    }

    private func readData(_ base: [String: Any]) -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func readAttributes(_ base: [String: Any]) -> [String: Any]? {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        guard status == errSecSuccess else { return nil }
        return item as? [String: Any]
    }

    private func decodeSession(_ data: Data?) -> PhoneSession? {
        guard let data, data != Self.rejectedMarker,
              let session = try? JSONDecoder().decode(PhoneSession.self, from: data),
              !session.refreshToken.isEmpty
        else { return nil }
        return session
    }

    private static func decodeMetadata(_ attributes: [String: Any]) -> PhoneSessionMetadata? {
        guard let data = attributes[kSecAttrGeneric as String] as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneSessionMetadata.self, from: data)
    }
}
