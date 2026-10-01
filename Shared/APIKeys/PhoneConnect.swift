import Foundation

/// What the iPhone may connect on its own. Only the allowlist for now; the decision for each
/// provider comes with the connect screen.
enum PhoneConnect: Sendable {
    /// The only allowlist. Empty until a vendor documents a public client with a usage read that
    /// needs no secret and no identity. Tests pass their own set; production never does.
    static let productionAllowlist: Set<Provider> = []
}
