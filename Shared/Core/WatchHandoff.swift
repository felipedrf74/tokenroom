import Foundation

/// What the iPhone and the Watch say to each other over WatchConnectivity. Readings only, plus
/// two non-secret signals: whether the iPhone can show its connect screen, and the Watch asking
/// it to. Never a token, a key, or an identity.
enum WatchHandoff {
    /// The `ReadingCache`, encoded.
    static let readingsKey = "readings"
    /// `true` while the iPhone's connect screen is on; absent otherwise.
    static let connectAvailableKey = "connectAvailable"
    static let openKey = "open"
    static let openConnect = "connect"

    /// The whole application context: `updateApplicationContext` replaces it in one go, so the
    /// readings and the flag travel together, or a flag-only update would drop the readings.
    static func context(readings: Data, connectAvailable: Bool) -> [String: Any] {
        var context: [String: Any] = [readingsKey: readings]
        if connectAvailable {
            context[connectAvailableKey] = true
        }
        return context
    }

    /// False when the key is missing, as it is from an iPhone with the connect screen off.
    static func connectAvailable(in context: [String: Any]) -> Bool {
        context[connectAvailableKey] as? Bool ?? false
    }

    /// The Watch's one request: open the connect screen. No provider, nothing else.
    static var openConnectMessage: [String: Any] {
        [openKey: openConnect]
    }

    static func asksToOpenConnect(_ message: [String: Any]) -> Bool {
        message.count == 1 && message[openKey] as? String == openConnect
    }
}
