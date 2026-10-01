import Foundation

/// Where a phone session may be kept on this iPhone: its own application identifier, read from
/// `TokenroomApplicationIdentifier` in Info.plist (`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`),
/// the way `RelayAvailability` reads the iCloud container. Nil when the build left it missing,
/// empty, or unfilled, or when it is the group widgets share for pasted keys: then no
/// `PhoneSessionStore` is made. Never logged.
enum PhoneSessionAvailability {
    static let infoKey = "TokenroomApplicationIdentifier"

    static var accessGroup: String? {
        PhoneSessionStore.accessGroup(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }

    /// The store, or nil when the access group can't be trusted. Nothing calls this while
    /// `PhoneConnect.productionAllowlist` is empty.
    static func store() -> PhoneSessionStore? {
        PhoneSessionStore.make(
            plistValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
            sharedGroup: AppGroup.keychainGroup
        )
    }
}
