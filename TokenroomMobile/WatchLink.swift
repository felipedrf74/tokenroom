import Foundation
import OSLog
import WatchConnectivity

final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()
    static let readingsKey = WatchHandoff.readingsKey
    static let openConnectRequest = Notification.Name("app.tokenroom.watch.openConnect")

    private let lock = NSLock()
    private var latest: ReadingCache?
    private var connectFlag = false
    private var refreshHandler: (@MainActor @Sendable () async -> ReadingCache?)?
    var refreshReadings: (@MainActor @Sendable () async -> ReadingCache?)? {
        get { lock.withLock { refreshHandler } }
        set { lock.withLock { refreshHandler = newValue } }
    }
    static let refreshBudget: TimeInterval = 15

    var connectAvailable: Bool {
        get { lock.withLock { connectFlag } }
        set { lock.withLock { connectFlag = newValue } }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ cache: ReadingCache) {
        guard WCSession.isSupported(), !cache.isSample, cache.v <= ReadingCache.version,
              PhoneCacheAccess.accepts(cache, defaults: AppGroup.defaults) else { return }
        lock.withLock { latest = cache }
        flush()
    }

    private func flush() {
        let session = WCSession.default
        let defaults = AppGroup.defaults
        guard session.activationState == .activated else {
            SyncHealthLog.record(.handoffSend, .inactive, in: defaults)
            return
        }
        guard session.isPaired else {
            SyncHealthLog.record(.handoffSend, .notPaired, in: defaults)
            return
        }
        guard session.isWatchAppInstalled else {
            SyncHealthLog.record(.handoffSend, .notInstalled, in: defaults)
            return
        }
        guard let (context, size) = currentContext() else { return }
        do {
            try session.updateApplicationContext(context)
            SyncHealthLog.record(.handoffSend, size, in: defaults)
        } catch {
            let code = (error as NSError).code
            Self.logger.error("handover not sent: WCError \(code, privacy: .public)")
            SyncHealthLog.record(.handoffSend, code == WCError.payloadTooLarge.rawValue ? .tooLarge : .failed, in: defaults)
        }
    }

    private func currentContext(checked: ReadingCache? = nil) -> (context: [String: Any], size: SyncHealth.Code)? {
        let defaults = AppGroup.defaults
        let retained = lock.withLock { () -> ReadingCache? in
            if let latest, !PhoneCacheAccess.accepts(latest, defaults: defaults) { self.latest = nil }
            return latest
        }
        let cache = WatchHandoff.cacheToSend(retained: checked ?? retained, saved: Self.savedReadings(),
                                             accountGeneration: PhoneCacheAccess.generation(in: defaults))
        guard let cache, PhoneCacheAccess.accepts(cache, defaults: defaults),
              let encoded = WatchHandoff.encodedReadings(cache) else { return nil }
        let size: SyncHealth.Code = encoded.isOverLimit ? .tooLarge : encoded.historyHours == nil ? .ok : .trimmed
        if size != .ok {
            Self.logger.notice("handover \(encoded.data.count, privacy: .public) bytes, history \(encoded.historyHours ?? -1, privacy: .public) h")
        } else {
            Self.logger.debug("handover \(encoded.data.count, privacy: .public) bytes")
        }
        return (WatchHandoff.context(readings: encoded.data, connectAvailable: connectAvailable), size)
    }

    private static let logger = Logger(subsystem: "app.tokenroom.ios", category: "watch-link")

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if WatchHandoff.asksToRefreshReadings(message) {
            let reply = HandoffReply(replyHandler)
            let refresh = refreshReadings
            Task { [weak self] in
                let checked = await WatchHandoff.collectForReply(budget: Self.refreshBudget) {
                    await refresh?()
                }
                reply.send(self?.currentContext(checked: checked)?.context ?? [:])
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

    private static func savedReadings() -> ReadingCache? {
        guard let cache = PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults), !cache.isSample else { return nil }
        return cache
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        flush()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        flush()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

private final class HandoffReply: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ context: [String: Any]) { callback(context) }
}
