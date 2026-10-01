import Foundation
import Security

/// A session a vendor issued to Tokenroom on this iPhone, for a documented public client. Never a
/// copy of another tool's login, and never an identity: no email, subject, organization, or id
/// token. A grant parser drops those before `save`.
struct PhoneSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
    /// Documented token endpoint for this public client. No secret is stored beside it.
    var tokenURL: URL
    /// Public client id the vendor issued for third-party apps. Never a CLI id.
    var clientID: String
}

/// Kept beside the session; not a secret. A screen may read this on the main actor. It has no
/// last four characters: part of a bearer token is still a credential.
struct PhoneSessionMetadata: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case ready
        /// Set before a refresh token is sent, so a launch after a crash knows the server may
        /// have rotated it.
        case exchanging
        /// The server refused the refresh token. The token bytes are gone; the row asks to sign in.
        case rejected
    }

    var addedAt: Date
    var state: State
}

/// The Keychain calls the store makes, so tests can watch every query and fail any of them
/// without touching a real Keychain.
struct KeychainOperations: Sendable {
    var copy: @Sendable ([String: Any]) -> (status: OSStatus, item: CFTypeRef?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = KeychainOperations(
        copy: { KeychainGate.copyMatching($0) },
        add: { KeychainGate.add($0) },
        update: { KeychainGate.update($0, $1) },
        delete: { KeychainGate.delete($0) }
    )
}

/// Phone sessions, one Keychain item per provider, in the iPhone app's own access group.
///
/// Nothing writes here yet: `PhoneConnect.productionAllowlist` is empty. Same accessibility and
/// not-synchronizable flags as `APIKeyStore` on the iPhone, so a session stays on this device
/// and needs it unlocked once since starting. The Watch doesn't compile this file, and the
/// widget extension doesn't either (a membership exception in the project), and isn't entitled
/// to the group. Reads can block: call through `BlockingIO`.
struct PhoneSessionStore: Sendable {
    enum SessionError: Error, Equatable {
        case keychain(OSStatus)
        case encoding
    }

    /// The iPhone application identifier (`TEAMID.app.tokenroom.ios`). Required on every query:
    /// a query without one goes to the first group in the entitlements, which is the group the
    /// widgets share for pasted keys. Never nil, never that shared group.
    var accessGroup: String
    /// Tests pass their own prefixes so they never name a real item.
    var servicePrefix = "app.tokenroom.ios.session."
    var recoveryService = "app.tokenroom.ios.session-recovery"
    var keychain: KeychainOperations = .system

    static let account = "default"
    static let probeAccount = "writable-probe"
    /// What the token bytes hold once the server refused the refresh token.
    static let rejectedMarker = Data("rejected".utf8)

    /// The access group to use, or nil when the build didn't fill it in correctly. Nil means no
    /// store is made: the caller doesn't fall back to the shared group or to an omitted one.
    static func accessGroup(plistValue: String?, sharedGroup: String?) -> String? {
        guard let value = plistValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.contains("$("),
              value != sharedGroup
        else { return nil }
        return value
    }

    /// The store for a build's Info.plist value, or nil (and no Keychain call) when the value
    /// can't be trusted.
    static func make(plistValue: String?, sharedGroup: String?, keychain: KeychainOperations = .system) -> PhoneSessionStore? {
        accessGroup(plistValue: plistValue, sharedGroup: sharedGroup).map {
            PhoneSessionStore(accessGroup: $0, keychain: keychain)
        }
    }

    func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    /// The session item's query, as every call passes it.
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
        // Access groups exist only in the data-protection keychain on the Mac.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    // MARK: Reading

    /// Nil unless the item holds a session with a refresh token: a rejected item has none.
    func session(for provider: Provider) -> PhoneSession? {
        decodeSession(readData(query(for: provider)))
    }

    func metadata(for provider: Provider) -> PhoneSessionMetadata? {
        readAttributes(query(for: provider)).flatMap(Self.decodeMetadata)
    }

    func hasSession(for provider: Provider) -> Bool {
        session(for: provider) != nil
    }

    // MARK: Writing

    /// Whether this provider's item will take a write, proven before a refresh token is sent and
    /// without touching the token. An existing item gets its own metadata written back (no
    /// `kSecValueData` in the update). Otherwise a probe, holding only the word `ok`, is added and
    /// deleted; the delete is always tried, and a probe that couldn't be deleted means no.
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

    /// Changes the state in the metadata only; the token bytes stay as they are.
    @discardableResult
    func setState(_ state: PhoneSessionMetadata.State, for provider: Provider) -> Bool {
        let query = query(for: provider)
        guard var metadata = metadata(for: provider) else { return false }
        metadata.state = state
        guard let generic = try? JSONEncoder().encode(metadata) else { return false }
        return keychain.update(query, [kSecAttrGeneric as String: generic]) == errSecSuccess
    }

    /// A new sign-in: the session, ready, dated now.
    func save(_ session: PhoneSession, for provider: Provider, now: Date) throws {
        try write(session, metadata: PhoneSessionMetadata(addedAt: now, state: .ready), to: query(for: provider), provider: provider)
    }

    /// Puts the new grant in the recovery item, before the session item is replaced. False means
    /// the caller retries this write, never the token request.
    func saveRecovery(_ session: PhoneSession, for provider: Provider) -> Bool {
        let metadata = PhoneSessionMetadata(addedAt: metadata(for: provider)?.addedAt ?? .now, state: .exchanging)
        return (try? write(session, metadata: metadata, to: recoveryQuery(for: provider), provider: provider)) != nil
    }

    func takeRecovery(for provider: Provider) -> PhoneSession? {
        decodeSession(readData(recoveryQuery(for: provider)))
    }

    func deleteRecovery(for provider: Provider) {
        _ = keychain.delete(recoveryQuery(for: provider))
    }

    /// Replaces the session from the recovery item, sets it ready, then deletes the recovery
    /// item. False leaves both items as they were, so it can be tried again.
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

    /// The server refused the refresh token: the token bytes become the word `rejected`, and the
    /// item stays with its date, so the row can ask to sign in again. Only this provider's
    /// session item changes; no key and no other session is touched.
    func markRejected(for provider: Provider, now: Date) {
        let query = query(for: provider)
        let addedAt = metadata(for: provider)?.addedAt ?? now
        guard let generic = try? JSONEncoder().encode(PhoneSessionMetadata(addedAt: addedAt, state: .rejected)) else { return }
        let attributes: [String: Any] = [kSecValueData as String: Self.rejectedMarker, kSecAttrGeneric as String: generic]
        if keychain.update(query, attributes) == errSecItemNotFound {
            var item = query
            item.merge(attributes) { $1 }
            _ = keychain.add(item)
        }
    }

    /// What the user's Remove does: the session and any recovery item.
    func remove(for provider: Provider) throws {
        let status = keychain.delete(query(for: provider))
        deleteRecovery(for: provider)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SessionError.keychain(status) }
    }

    // MARK: Private

    /// Updates the item in place when it exists, so a failed write never leaves it deleted.
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
