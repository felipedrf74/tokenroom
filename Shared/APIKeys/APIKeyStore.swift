import Foundation
import Security

struct APIKeyStore: Sendable {
    enum KeyError: Error, Equatable {
        case empty
        case keychain(OSStatus)
    }

    struct Metadata: Codable, Equatable, Sendable {
        var last4: String
        var addedAt: Date
        var region: String?
        var warning: String? = nil
    }

    var accessGroup: String? = nil
    var servicePrefix = "app.tokenroom.key."
    var keychain: KeychainOperations = .system
    #if os(macOS)
    var usesDataProtection = KeychainAvailability.dataProtection
    #endif

    func service(for provider: Provider) -> String {
        servicePrefix + provider.rawValue
    }

    func key(for provider: Provider) -> String? {
        if let key = readKey(baseQuery(provider)) {
            return key
        }
        #if os(macOS)
        if usesDataProtection, let legacy = readItem(legacyQuery(provider)) {
            migrate(provider, key: legacy.key, saved: legacy.metadata)
            return legacy.key
        }
        #endif
        return nil
    }

    func metadata(for provider: Provider) -> Metadata? {
        if let metadata = readMetadata(baseQuery(provider)) {
            return metadata
        }
        #if os(macOS)
        if usesDataProtection {
            return readMetadata(legacyQuery(provider))
        }
        #endif
        return nil
    }

    enum Lookup: Equatable, Sendable {
        case found(Metadata)
        case none
        case unreadable
    }

    func lookup(for provider: Provider) -> Lookup {
        let result = readMetadataLookup(baseQuery(provider))
        #if os(macOS)
        if case .none = result, usesDataProtection {
            return readMetadataLookup(legacyQuery(provider))
        }
        #endif
        return result
    }

    private func readKey(_ base: [String: Any]) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    private func readMetadata(_ base: [String: Any]) -> Metadata? {
        guard case .found(let metadata) = readMetadataLookup(base) else { return nil }
        return metadata
    }

    private func readMetadataLookup(_ base: [String: Any]) -> Lookup {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        if status == errSecItemNotFound { return .none }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecAttrGeneric as String] as? Data,
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return .unreadable }
        return .found(metadata)
    }

    #if os(macOS)
    private func legacyQuery(_ provider: Provider) -> [String: Any] {
        var query = baseQuery(provider)
        query.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return query
    }

    private func readItem(_ base: [String: Any]) -> (key: String, metadata: Metadata?)? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = keychain.copy(query)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        let metadata = (attributes[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        return (key, metadata)
    }

    private func migrate(_ provider: Provider, key: String, saved: Metadata?) {
        let metadata = Metadata(last4: String(key.suffix(4)), addedAt: saved?.addedAt ?? .now, region: saved?.region, warning: saved?.warning)
        _ = try? add(key, metadata: metadata, to: baseQuery(provider), for: provider)
    }
    #endif

    func hasKey(for provider: Provider) -> Bool {
        metadata(for: provider) != nil
    }

    func save(_ key: String, for provider: Provider, region: String? = nil, warning: String? = nil, now: Date = .now) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeyError.empty }
        let metadata = Metadata(last4: String(trimmed.suffix(4)), addedAt: now, region: region, warning: warning)
        let query = baseQuery(provider)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrGeneric as String: try JSONEncoder().encode(metadata),
            kSecAttrLabel as String: "Tokenroom · \(provider.displayName) key",
        ]
        var status = keychain.update(query, attributes)
        if status == errSecItemNotFound {
            status = try add(trimmed, metadata: metadata, to: query, for: provider)
            if status == errSecDuplicateItem { status = keychain.update(query, attributes) }
        }
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }

    private func add(_ key: String, metadata: Metadata, to query: [String: Any], for provider: Provider) throws -> OSStatus {
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(metadata)
        attributes[kSecAttrLabel as String] = "Tokenroom · \(provider.displayName) key"
        #if !os(macOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        return keychain.add(attributes)
    }

    func remove(for provider: Provider) throws {
        var statuses = [keychain.delete(baseQuery(provider))]
        #if os(macOS)
        if usesDataProtection {
            statuses.append(keychain.delete(legacyQuery(provider)))
        }
        #endif
        if let failed = statuses.first(where: { $0 != errSecSuccess && $0 != errSecItemNotFound }) {
            throw KeyError.keychain(failed)
        }
    }

    private func baseQuery(_ provider: Provider) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: provider),
            kSecAttrAccount as String: "default",
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        if usesDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }
}

extension KeySpec {
    func initialChoice(saved: APIKeyStore.Metadata?) -> String {
        if let region = saved?.region, regions.contains(region) {
            return region
        }
        return regions.first ?? ""
    }
}

#if os(macOS)
enum KeychainAvailability {
    static let dataProtection: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.application-identifier" as CFString, nil)
        else { return false }
        return (value as? String)?.isEmpty == false
    }()
}
#endif
