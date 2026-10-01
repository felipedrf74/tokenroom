import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

/// The Watch's readings: straight from iCloud, so it keeps working with the iPhone away, and
/// sooner from the iPhone over WatchConnectivity when it's near. No keys, no logins.
@Observable
@MainActor
final class WatchStore {
    static let backgroundTaskID = "app.tokenroom.watch.refresh"
    /// The Smart Stack widget's kind, in TokenroomWatchWidgets.
    static let resetSoonKind = "watch.resetSoon"
    /// How often to ask watchOS for a background refresh; it decides when.
    static let backgroundInterval: TimeInterval = 15 * 60
    /// How long a refresh waits for iCloud before it counts as unreachable, so one that never
    /// answers can't hold off every later refresh.
    static let readBudget: TimeInterval = 10

    enum Problem: Equatable {
        case noAccount
        case unreachable
    }

    private(set) var cache: ReadingCache?
    private(set) var isRefreshing = false
    /// Why there's nothing to show, when there isn't.
    private(set) var problem: Problem?
    /// Opened from a complication or the Smart Stack: the provider to show.
    var openedProvider: String?
    /// The iPhone said its connect screen is on, in its last handover.
    private(set) var phoneOffersConnect = false
    /// The iPhone app is running and can take a message now.
    private(set) var phoneReachable = false

    /// "Set up on iPhone" shows only when the iPhone offers its connect screen and can be asked.
    var canOpenConnectOnPhone: Bool {
        phoneOffersConnect && phoneReachable
    }
    private var lastRefresh: Date?
    private var accountGate = WatchAccountGate(signedOutAt: AppGroup.defaults.object(forKey: "watchSignedOutAt") as? Date)
    private var pendingPhone: ReadingCache?
    private var accountRevision = 0
    private let cacheURL = ReadingCache.defaultURL
    private let link = PhoneLink()
    /// Launched with `-sampleMode YES` (debug builds): the sample readings stay for the launch.
    private var showsSample = false

    init() {
        cache = WatchCacheAccess.load(at: cacheURL, defaults: AppGroup.defaults)
        #if DEBUG
        // Screenshots and simulator checks: `-sampleMode YES` shows sample readings.
        if UserDefaults.standard.bool(forKey: "sampleMode") {
            cache = SampleData.cache()
            showsSample = true
        }
        // `-TokenroomOpen tokenroom://provider/claude` opens a provider, for screenshots.
        if let link = UserDefaults.standard.string(forKey: "TokenroomOpen").flatMap(URL.init(string:)),
           case .provider(let id) = DeepLink(link) {
            openedProvider = id
        }
        #endif
        link.onCache = { [weak self] cache in
            self?.receivePhone(cache)
        }
        link.onConnectAvailable = { [weak self] available in
            self?.phoneOffersConnect = available
        }
        link.onReachability = { [weak self] reachable in
            self?.phoneReachable = reachable
        }
        link.activate()
    }

    var items: [ReadingCache.Item] {
        items(at: .now)
    }

    func items(at date: Date) -> [ReadingCache.Item] {
        guard cache?.isSample == true || (AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date) == accountGate.signedOutAt else { return [] }
        return cache?.presented(at: date).items ?? []
    }

    func item(id: String, at date: Date = .now) -> ReadingCache.Item? {
        items(at: date).first { $0.id == id }
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        // Sample readings aren't replaced by what iCloud says this launch.
        guard WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        _ = synchronizeAccountCutoff()
        adoptValidatedDiskCache()
        guard !isRefreshing else { return }
        if !force, let lastRefresh, now.timeIntervalSince(lastRefresh) < 60 { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let previousRefresh = lastRefresh
        lastRefresh = now
        let revision = accountRevision
        let cutoff = AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date
        let outcome = await TimeLimit.run(Self.readBudget, otherwise: .failed) { await RelayReadings.read(now: now) }
        guard revision == accountRevision,
              (AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date) == cutoff else {
            Task { await refresh(force: true) }
            return
        }
        switch outcome {
        case .readings(let fresh):
            adoptValidatedDiskCache()
            accountGate.confirmAvailable()
            problem = nil
            apply(fresh)
            if let pendingPhone, accountGate.accepts(pendingPhone) { apply(pendingPhone) }
            pendingPhone = nil
        case .noAccount:
            accountGate.signOut(at: now)
            WatchCacheAccess.invalidate(in: AppGroup.defaults, at: now)
            pendingPhone = nil
            problem = .noAccount
            cache = ReadingCache(savedAt: now, isSample: false, items: [])
            if let cacheURL, let cache { try? cache.save(to: cacheURL) }
            WidgetCenter.shared.reloadAllTimelines()
            WidgetCenter.shared.invalidateRelevance(ofKind: Self.resetSoonKind)
        case .failed:
            adoptValidatedDiskCache()
            problem = .unreachable
        case .unavailable:
            // A build without iCloud (no team): sample readings, clearly marked.
            if cache == nil {
                cache = SampleData.cache(now: now)
            }
            problem = nil
        }
        if let previousRefresh, cache?.resetDates(after: previousRefresh, through: now).isEmpty == false {
            WidgetCenter.shared.reloadTimelines(ofKind: Self.resetSoonKind)
        }
    }

    private func adoptValidatedDiskCache() {
        guard WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        let recovered = WatchCacheRecovery.recover(cache, at: cacheURL, defaults: AppGroup.defaults)
        guard recovered != cache else { return }
        cache = recovered
        // The complication has revalidated the account. Leave phone handovers gated until this
        // process independently completes an iCloud read.
        if problem == .noAccount { problem = nil }
    }

    /// Incoming membership with each provider's newest measurement, saved for complications.
    /// A delayed whole cache cannot undo removals; a mixed-age update still advances fresh providers.
    /// Complications reload for what they'd draw differently; from the background, only for
    /// what matters (`ReadingCache.reloadSignature`), as their reloads are budgeted. Smaller
    /// changes show on their next timeline, which reads the saved readings.
    func apply(_ fresh: ReadingCache) {
        let fresh = cache?.mergingUpdate(fresh) ?? fresh
        let changed = fresh.materialHash != cache?.materialHash
        let matters = fresh.reloadSignature != cache?.reloadSignature
        cache = fresh
        try? WatchCacheAccess.saveValidated(fresh, at: cacheURL, defaults: AppGroup.defaults,
                                           cutoff: accountGate.signedOutAt)
        guard changed else { return }
        if matters || WKApplication.shared().applicationState == .active {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // The Smart Stack widget picks its moments from the readings; let it look again.
        WidgetCenter.shared.invalidateRelevance(ofKind: WatchStore.resetSoonKind)
    }

    private func receivePhone(_ fresh: ReadingCache) {
        guard fresh.v <= ReadingCache.version, WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        if synchronizeAccountCutoff() { Task { await refresh(force: true) } }
        if accountGate.accepts(fresh) { apply(fresh) }
        else if accountGate.signedOutAt.map({ fresh.savedAt > $0 }) != false {
            pendingPhone = pendingPhone?.mergingUpdate(fresh) ?? fresh
        }
    }

    /// A complication can confirm sign-out while the app is suspended. Observe its durable fence
    /// before accepting phone data, as well as before reading iCloud.
    @discardableResult
    private func synchronizeAccountCutoff() -> Bool {
        guard let cutoff = AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date,
              cutoff != accountGate.signedOutAt else { return false }
        accountGate.signOut(at: cutoff)
        cache = nil
        pendingPhone = nil
        return true
    }

    func accountChanged(now: Date = .now) {
        guard WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        accountRevision += 1
        accountGate.signOut(at: now)
        WatchCacheAccess.invalidate(in: AppGroup.defaults, at: now)
        cache = nil
        problem = nil
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.invalidateRelevance(ofKind: Self.resetSoonKind)
        pendingPhone = nil
        lastRefresh = nil
        Task { await refresh(force: true) }
    }

    /// Asks the iPhone to open its connect screen. Only a request: the Watch never collects a
    /// password, a key, or a session.
    func openConnectOnPhone() {
        guard canOpenConnectOnPhone else { return }
        link.requestOpenConnect()
    }

    func scheduleBackgroundRefresh(now: Date = .now) {
        let usual = now.addingTimeInterval(Self.backgroundInterval)
        let preferred = cache?.resetDates(after: now, through: usual).first.map { $0.addingTimeInterval(1) } ?? usual
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferred,
            userInfo: Self.backgroundTaskID as NSString
        ) { _ in }
    }
}

/// Readings the iPhone hands over while it's near, and the one request the Watch sends back.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let openKey = WatchHandoff.openKey
    static let openConnect = WatchHandoff.openConnect

    /// Set once, before activation.
    var onCache: (@MainActor (ReadingCache) -> Void)?
    var onConnectAvailable: (@MainActor (Bool) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // What the iPhone sent while this app wasn't running.
        deliver(session.receivedApplicationContext)
        report(reachable: session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        report(reachable: session.isReachable)
    }

    private func report(reachable: Bool) {
        guard let handler = onReachability else { return }
        Task { @MainActor in handler(reachable) }
    }

    /// `[open: connect]`, nothing else. Sent only while the iPhone app is reachable.
    func requestOpenConnect() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(WatchHandoff.openConnectMessage, replyHandler: { _ in }, errorHandler: { error in
            Self.logger.error("open on iPhone failed: \(String(describing: error), privacy: .public)")
        })
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    private func deliver(_ context: [String: Any]) {
        guard let data = context[PhoneLink.readingsKey] as? Data else { return }
        let cache: ReadingCache
        do {
            cache = try RelayEnvelope.decoder.decode(ReadingCache.self, from: data)
        } catch {
            Self.logger.error("readings from iPhone unreadable: \(String(describing: error), privacy: .public)")
            return
        }
        // Absent from an iPhone with the connect screen off: false.
        let offersConnect = WatchHandoff.connectAvailable(in: context)
        if let connectHandler = onConnectAvailable {
            Task { @MainActor in connectHandler(offersConnect) }
        }
        guard let handler = onCache else { return }
        Task { @MainActor in handler(cache) }
    }

    private static let logger = Logger(subsystem: "app.tokenroom.watch", category: "phone-link")

    static let readingsKey = WatchHandoff.readingsKey
}
