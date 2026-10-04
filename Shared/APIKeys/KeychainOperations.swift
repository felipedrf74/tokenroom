import Foundation
import Security

/// Injectable Keychain calls. Credential-store regression tests never need a real item.
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
