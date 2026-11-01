import CommonCrypto
import Foundation
import os

/// Grok Bot's desktop login is independent of Cursor's. Read only the active account;
/// never renew, copy to disk, or fall through to another account when it can't be read.
enum GrokBotCredentials {
    struct Session: Sendable {
        var token: String
        var isNative: Bool
    }

    static let storageService = "Grok Bot Safe Storage"
    static let accessHint = "Couldn't read Grok Bot's login. Choose Sign In, then Always Allow in the Keychain dialog."
    private static let refused = OSAllocatedUnfairLock<Int?>(initialState: nil)

    static func read(
        file: URL = CredentialReaders.grokBotSecretsURL,
        password: () -> String? = { CredentialReaders.grokBotStoragePassword() },
        cursor: () throws -> String = { try CredentialReaders.cursorAccessToken() },
        allowLegacyCursor: Bool = true,
        now: Date = .now
    ) throws -> Session {
        guard FileManager.default.fileExists(atPath: file.path) else {
            guard allowLegacyCursor else { throw ProviderError.signedOut(Provider.grokBot.signInHint) }
            do { return Session(token: try cursor(), isNative: false) }
            catch ProviderError.signedOut { throw ProviderError.signedOut(Provider.grokBot.signInHint) }
            catch ProviderError.expired { throw ProviderError.expired(Provider.grokBot.expiredHint) }
        }
        let encrypted = try encryptedToken(from: Data(contentsOf: file))
        guard let password = password(), !password.isEmpty else {
            throw ProviderError.expired(accessHint)
        }
        guard let token = decrypt(encrypted, password: password), !token.isEmpty else {
            throw ProviderError.parse
        }
        guard !CredentialReaders.tokenHasExpired(token, now: now) else {
            throw ProviderError.expired(Provider.grokBot.expiredHint)
        }
        return Session(token: token, isNative: true)
    }

    static func encryptedToken(from data: Data) throws -> String {
        let root = try JSONFlex.object(from: data)
        guard root["version"] == nil || JSONFlex.number(root["version"]) == 1 else {
            throw ProviderError.parse
        }
        let stored: String
        var active: String?
        if let raw = root["cursor-accounts"] {
            guard let text = raw as? String, let bytes = text.data(using: .utf8),
                  let accounts = try? JSONFlex.object(from: bytes)
            else { throw ProviderError.parse }
            guard let selected = accounts["active"] as? String, !selected.isEmpty,
                  let entries = accounts["accounts"] as? [String: [String: Any]],
                  let value = entries[selected]?["cursor-access-token"] as? String, !value.isEmpty
            else { throw ProviderError.signedOut(Provider.grokBot.signInHint) }
            active = selected
            stored = value
        } else if let value = root["cursor-access-token"] as? String, !value.isEmpty {
            stored = value
        } else {
            throw ProviderError.signedOut(Provider.grokBot.signInHint)
        }
        if stored.hasPrefix("scoped:v1:") {
            let parts = stored.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[2].count == 64, parts[2].allSatisfy(\.isHexDigit),
                  active == nil || active == String(parts[2]), !parts[3].isEmpty
            else { throw ProviderError.parse }
            return String(parts[3])
        }
        return stored
    }

    /// Electron/Chromium's macOS v10 format. Unknown formats fail closed.
    /// https://chromium.googlesource.com/chromium/src/+/140.0.7339.0/components/os_crypt/sync/os_crypt_mac.mm
    static func decrypt(_ encoded: String, password: String) -> String? {
        guard let data = Data(base64Encoded: encoded), data.starts(with: Data("v10".utf8)),
              data.count > 3, (data.count - 3).isMultiple(of: kCCBlockSizeAES128)
        else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let salt = Array("saltysalt".utf8)
        let derived = password.withCString {
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0, password.utf8.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                1003, &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        let ciphertext = Array(data.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        defer { _ = plaintext.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, ciphertext, ciphertext.count, &plaintext, plaintext.count, &count)
        guard status == kCCSuccess else { return nil }
        return String(bytes: plaintext.prefix(count), encoding: .utf8)
    }

    static func noteRefused(_ token: String) { refused.withLock { $0 = token.hashValue } }
    static func wasRefused(_ token: String) -> Bool { refused.withLock { $0 == token.hashValue } }

    /// Only the user's Sign In action may ask macOS for access. Nil means there is no
    /// readable native login to authorize, so the coordinator opens the owning app instead.
    static func authorize() -> Bool? {
        guard let data = try? Data(contentsOf: CredentialReaders.grokBotSecretsURL),
              (try? encryptedToken(from: data)) != nil else { return nil }
        do {
            let session = try read(password: { CredentialReaders.grokBotStoragePassword(promptAllowed: true) })
            return wasRefused(session.token) ? nil : true
        } catch ProviderError.expired(let hint) where hint != accessHint {
            return nil
        } catch { return false }
    }
}
