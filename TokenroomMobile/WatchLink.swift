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
    private var latest: ReadingCache?
    private var connectFlag = false
    private var refreshHandler: (@MainActor @Sendable () async -> ReadingCache?)?
    /// Registered by the app's owner of MobileStore. A reachable Watch can ask its iPhone to
    /// collect readings, with the same provider spacing and cooldowns as an app refresh.
    var refreshReadings: (@MainActor @Sendable () async -> ReadingCache?)? {
        get { lock.withLock { refreshHandler } }
        set { lock.withLock { refreshHandler = newValue } }
    }
    static let refreshBudget: TimeInterval = 15

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
        guard WCSession.isSupported(), !cache.isSample, cache.v <= ReadingCache.version,
              PhoneCacheAccess.accepts(cache, defaults: AppGroup.defaults) else { return }
        lock.withLock { latest = cache }
        flush()
    }

    private func flush() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let context = currentContext()
        else { return }
        // One dictionary: the context is replaced whole, so the flag never goes without readings.
        try? session.updateApplicationContext(context)
    }

    private func currentContext(checked: ReadingCache? = nil) -> [String: Any]? {
        let defaults = AppGroup.defaults
        let retained = lock.withLock { () -> ReadingCache? in
            if let latest, !PhoneCacheAccess.accepts(latest, defaults: defaults) { self.latest = nil }
            return latest
        }
        let cache = WatchHandoff.cacheToSend(retained: checked ?? retained, saved: Self.savedReadings(),
                                             accountGeneration: PhoneCacheAccess.generation(in: defaults))
        guard let cache, let data = try? RelayEnvelope.encoder.encode(cache),
              PhoneCacheAccess.accepts(cache, defaults: defaults) else { return nil }
        return WatchHandoff.context(readings: data, connectAvailable: connectAvailable)
    }

    /// Refresh requests use the app's normal collector. Replies contain only the same readings
    /// as the context, and stay bounded when a provider or iCloud doesn't answer.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if WatchHandoff.asksToRefreshReadings(message) {
            let reply = HandoffReply(replyHandler)
            let refresh = refreshReadings
            Task { [weak self] in
                let checked = await WatchHandoff.collectForReply(budget: Self.refreshBudget) {
                    await refresh?()
                }
                reply.send(self?.currentContext(checked: checked) ?? [:])
            }
            return
        }
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
    private static func savedReadings() -> ReadingCache? {
        guard let cache = PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults), !cache.isSample else { return nil }
        return cache
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

/// WatchConnectivity supplies a reply on its delegate queue; keep that callback together when
/// the readings are collected asynchronously. Each message gets exactly one reply.
private final class HandoffReply: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ context: [String: Any]) { callback(context) }
}
