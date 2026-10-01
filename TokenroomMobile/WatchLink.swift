import Foundation
import WatchConnectivity

/// Hands the latest readings to the Watch app while it's near, sooner than iCloud. The Watch
/// reads iCloud itself too, so nothing depends on this. While the connect screen is on, the same
/// dictionary says so (`connectAvailable`), and the Watch may ask this iPhone to open it.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    static let readingsKey = WatchHandoff.readingsKey
    /// Posted on the main queue when the Watch asks to open the connect screen; `RootView`
    /// opens `tokenroom://connect`.
    static let openConnectRequest = Notification.Name("app.tokenroom.watch.openConnect")

    private let lock = NSLock()
    /// The newest readings, kept until the session can take them: activation finishes after
    /// the first refresh, and the Watch app may be installed later.
    private var latest: Data?
    private var connectFlag = false

    /// Whether the connect screen is on (`MobileStore.connectOnIPhone`). Set before activation.
    var connectAvailable: Bool {
        get { lock.withLock { connectFlag } }
        set { lock.withLock { connectFlag = newValue } }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Replaces what the Watch last got; only the newest readings matter.
    func send(_ cache: ReadingCache) {
        guard WCSession.isSupported(), let data = try? RelayEnvelope.encoder.encode(cache) else { return }
        lock.withLock { latest = data }
        flush()
    }

    private func flush() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let data = lock.withLock({ latest }) ?? Self.savedReadings()
        else { return }
        // One dictionary: the context is replaced whole, so the flag never goes without readings.
        try? session.updateApplicationContext(WatchHandoff.context(readings: data, connectAvailable: connectAvailable))
    }

    /// The Watch's only request: open the connect screen. Honoured only while it's on. Nothing
    /// here reads the Keychain, and the reply is empty.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler([:])
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    private func handle(_ message: [String: Any]) {
        guard connectAvailable, WatchHandoff.asksToOpenConnect(message) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.openConnectRequest, object: nil)
        }
    }

    /// The readings saved for widgets, for when this launch hasn't sent any: it only sends when
    /// they change, and a Watch app installed since would otherwise get nothing until then.
    /// Sample readings stay on the iPhone.
    private static func savedReadings() -> Data? {
        guard let url = ReadingCache.defaultURL, let cache = ReadingCache.load(from: url), !cache.isSample else { return nil }
        return try? RelayEnvelope.encoder.encode(cache)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        flush()
    }

    /// Pairing changed, or the Watch app was installed or removed.
    func sessionWatchStateDidChange(_ session: WCSession) {
        flush()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // After switching watches, talk to the new one.
        session.activate()
    }
}
