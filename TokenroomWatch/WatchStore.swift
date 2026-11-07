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
    static let phoneBudget: TimeInterval = 16

    typealias Problem = WatchProblem

    private(set) var cache: ReadingCache?
    var isRefreshing: Bool { refreshGate.isRefreshing }
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
    private var refreshGate = WatchRefreshGate()
    private var accountGate = WatchAccountGate(signedOutAt: AppGroup.defaults.object(forKey: "watchSignedOutAt") as? Date)
    /// A handover held until this process knows its account (`WatchHandoffAcceptance`), also
    /// saved in the App Group (`WatchPendingHandoff`) so it outlives the process.
    private var pendingPhone: ReadingCache?
    private var accountRevision = 0
    private let cacheURL = ReadingCache.defaultURL
    private let pendingURL = WatchPendingHandoff.defaultURL
    private let link = PhoneLink()
    /// Launched with `-sampleMode YES` (debug builds): the sample readings stay for the launch.
    private var showsSample = false
    /// Launched with `-TokenroomEmpty YES` (debug builds): nothing fills the empty state.
    private var showsEmpty = false

    init() {
        cache = WatchCacheAccess.load(at: cacheURL, defaults: AppGroup.defaults)
        pendingPhone = WatchPendingHandoff.load(at: pendingURL, signedOutAt: accountGate.signedOutAt)
        #if DEBUG
        // Screenshots and simulator checks: `-sampleMode YES` shows sample readings.
        if UserDefaults.standard.bool(forKey: "sampleMode") {
            cache = SampleData.cache()
            showsSample = true
        }
        // `-TokenroomEmpty YES` shows the empty state, whatever is saved, for screenshots.
        if UserDefaults.standard.bool(forKey: "TokenroomEmpty") {
            cache = nil
            showsEmpty = true
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
        guard !showsEmpty else { return }
        // Sample readings aren't replaced by what iCloud says this launch.
        guard WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        _ = synchronizeAccountCutoff()
        adoptValidatedDiskCache()
        let previousRefresh = refreshGate.lastRefresh
        guard refreshGate.begin(force: force, now: now) else { return }
        defer {
            if refreshGate.finish() {
                Task { await refresh(force: true) }
            }
        }
        let revision = accountRevision
        var cutoff = currentCutoff
        // A Watch refresh asks its reachable iPhone to collect too. The cloud read runs beside
        // it and continues to work when the phone is away. Neither source can hold this pass,
        // and iCloud's answer is applied as soon as it comes (`WatchRefreshOrder`).
        let link = self.link
        await WatchRefreshOrder.run(
            cloud: { await TimeLimit.run(Self.readBudget, otherwise: .failed) { await RelayReadings.read(now: now) } },
            phone: { await TimeLimit.run(Self.phoneBudget, otherwise: Optional<ReadingCache>.none) { await link.refreshReadings() } },
            applyCloud: { outcome in
                guard revision == accountRevision, currentCutoff == cutoff else {
                    // Coalesce with the account change's request; scheduling another task here
                    // could start a second follow-up while the first is already running.
                    _ = refreshGate.begin(force: true, now: .now)
                    return false
                }
                applyCloudOutcome(outcome, now: now)
                // A sign-out this read confirmed isn't an account change under the reply: its
                // cutoff is the one the reply is measured against.
                cutoff = currentCutoff
                return true
            },
            applyPhone: { phoneCache in
                guard revision == accountRevision, currentCutoff == cutoff else {
                    _ = refreshGate.begin(force: true, now: .now)
                    return
                }
                SyncHealthLog.record(.phoneReply, phoneCache == nil ? .unavailable : .ok, in: AppGroup.defaults)
                if let phoneCache { receivePhone(phoneCache) }
            }
        )
        if let previousRefresh, cache?.resetDates(after: previousRefresh, through: now).isEmpty == false {
            WidgetCenter.shared.reloadTimelines(ofKind: Self.resetSoonKind)
        }
    }

    private var currentCutoff: Date? {
        AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date
    }

    /// iCloud's answer, applied before the iPhone's reply. A failed read leaves the iPhone's
    /// handovers since the last sign-out free to apply (`WatchHandoffAcceptance`).
    private func applyCloudOutcome(_ outcome: RelayReadings.Outcome, now: Date) {
        switch outcome {
        case .readings(let fresh):
            SyncHealthLog.record(.cloudRead, .ok, in: AppGroup.defaults)
            WatchCacheAccess.noteAccountAvailable(in: AppGroup.defaults)
            adoptValidatedDiskCache()
            accountGate.confirmAvailable()
            problem = nil
            apply(fresh)
            applyPendingPhone()
        case .noAccount:
            SyncHealthLog.record(.cloudRead, .noAccount, in: AppGroup.defaults)
            // Confirmed sign-out closes the cache gate now, before the iPhone's reply. The first
            // no-account this Watch records closes just before a handover it holds instead, as on
            // a cold launch (`WatchHandoffAcceptance.signOutCutoff`).
            confirmNoAccount(at: WatchHandoffAcceptance.signOutCutoff(now: now, recordedCutoff: currentCutoff, held: pendingPhone))
            applyPendingPhone()
        case .failed:
            SyncHealthLog.record(.cloudRead, .failed, in: AppGroup.defaults)
            adoptValidatedDiskCache()
            accountGate.note(.readFailed)
            problem = .unreachable
            applyPendingPhone()
        case .unavailable:
            SyncHealthLog.record(.cloudRead, .unavailable, in: AppGroup.defaults)
            // A build without iCloud (no team): sample readings, clearly marked.
            if cache == nil {
                cache = SampleData.cache(now: now)
            }
            problem = nil
        }
    }

    /// Signed out of iCloud. When this Watch has been signed out since the last sign-out it
    /// recorded, nothing changes: the iPhone's handovers since then stay. Otherwise the gate
    /// closes now.
    private func confirmNoAccount(at date: Date) {
        if WatchCacheAccess.isStillSignedOut(in: AppGroup.defaults), currentCutoff == accountGate.signedOutAt {
            accountGate.note(.noAccount)
            problem = .noAccount
            return
        }
        clearSignedOutAccount(at: date)
    }

    private func clearSignedOutAccount(at date: Date) {
        accountGate.signOut(at: date)
        WatchCacheAccess.confirmNoAccount(in: AppGroup.defaults, at: date)
        accountGate.note(.noAccount)
        // A held handover saved after the cutoff (the first sign-out a Watch records closes just
        // before it, `WatchHandoffAcceptance.signOutCutoff`) is kept for `applyPendingPhone`.
        if pendingPhone.map({ $0.savedAt <= date }) != false { clearPendingPhone() }
        problem = .noAccount
        cache = ReadingCache(savedAt: date, isSample: false, items: [])
        if let cacheURL, let cache { try? cache.save(to: cacheURL) }
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.invalidateRelevance(ofKind: Self.resetSoonKind)
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
    /// changes show on their next timeline, which reads the saved readings. Both caches are
    /// measured as drawn now, so a reading that faded since and is live again with the same
    /// numbers is a change.
    func apply(_ fresh: ReadingCache, reloadWhenShown: Bool = false) {
        let now = Date.now
        let fresh = cache?.mergingUpdate(fresh, now: now) ?? fresh
        let change = fresh.changes(since: cache, at: now)
        cache = fresh
        try? WatchCacheAccess.saveValidated(fresh, at: cacheURL, defaults: AppGroup.defaults,
                                           cutoff: accountGate.signedOutAt)
        guard change.shown else { return }
        if change.worthReload || reloadWhenShown || WKApplication.shared().applicationState == .active {
            WidgetCenter.shared.reloadAllTimelines()
        }
        // The Smart Stack widget picks its moments from the readings; let it look again.
        WidgetCenter.shared.invalidateRelevance(ofKind: WatchStore.resetSoonKind)
    }

    private func receivePhone(_ fresh: ReadingCache) {
        guard !fresh.isSample, fresh.v <= ReadingCache.version, WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        if synchronizeAccountCutoff() { Task { await refresh(force: true) } }
        switch accountGate.decision(for: fresh) {
        case .apply:
            SyncHealthLog.record(.handoffReceive, .ok, in: AppGroup.defaults)
            apply(fresh)
            problem = problem?.afterPhoneData()
            // Anything held from before is older than this, and merged in by `apply` if not.
            if let held = pendingPhone, accountGate.accepts(held) { apply(held) }
            clearPendingPhone()
        case .hold:
            SyncHealthLog.record(.handoffReceive, .held, in: AppGroup.defaults)
            let held = pendingPhone?.mergingUpdate(fresh) ?? fresh
            pendingPhone = held
            WatchPendingHandoff.save(held, at: pendingURL)
        case .drop:
            SyncHealthLog.record(.handoffReceive, .dropped, in: AppGroup.defaults)
        }
    }

    /// A held handover, once this process knows enough to take it. Complications reload for
    /// whatever it changes they'd draw: it may have waited out a process.
    private func applyPendingPhone() {
        guard let held = pendingPhone else { return }
        switch accountGate.decision(for: held) {
        case .apply:
            SyncHealthLog.record(.handoffReceive, .ok, in: AppGroup.defaults)
            apply(held, reloadWhenShown: true)
            problem = problem?.afterPhoneData()
            clearPendingPhone()
        case .drop:
            SyncHealthLog.record(.handoffReceive, .dropped, in: AppGroup.defaults)
            clearPendingPhone()
        case .hold:
            break
        }
    }

    private func clearPendingPhone() {
        pendingPhone = nil
        WatchPendingHandoff.clear(at: pendingURL)
    }

    /// A complication can confirm sign-out while the app is suspended. Observe its durable fence
    /// before accepting phone data, as well as before reading iCloud.
    @discardableResult
    private func synchronizeAccountCutoff() -> Bool {
        guard let cutoff = AppGroup.defaults.object(forKey: WatchCacheAccess.cutoffKey) as? Date,
              cutoff != accountGate.signedOutAt else { return false }
        accountGate.signOut(at: cutoff)
        cache = nil
        clearPendingPhone()
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
        clearPendingPhone()
        refreshGate.accountChanged()
        Task { await refresh(force: true) }
    }

    /// Finish the WatchConnectivity background delivery after its latest whole context has
    /// reached the store, then keep normal cloud refreshes scheduled.
    func receiveBackgroundHandoff() async {
        await link.receiveApplicationContext()
        await settlePendingPhone()
        scheduleBackgroundRefresh()
    }

    /// A cold launch to take a handover doesn't read iCloud. It asks only for the account,
    /// within `WatchHandoffAcceptance.accountCheckBudget`, so a held handover can be applied,
    /// saved for complications, and shown there now rather than at the next launch.
    private func settlePendingPhone() async {
        guard pendingPhone != nil, !accountGate.validated, accountGate.account == .unknown,
              WatchCacheAccess.mayReplace(cache, showsSample: showsSample) else { return }
        let revision = accountRevision
        let cutoff = currentCutoff
        let check = await TimeLimit.run(WatchHandoffAcceptance.accountCheckBudget, otherwise: RelayAccountCheck.failed) {
            await RelayReadings.accountCheck()
        }
        guard revision == accountRevision, currentCutoff == cutoff else { return }
        switch check {
        case .noAccount:
            confirmNoAccount(at: WatchHandoffAcceptance.signOutCutoff(now: .now, recordedCutoff: cutoff, held: pendingPhone))
        case .available, .failed, .unavailable:
            WatchCacheAccess.note(check, in: AppGroup.defaults)
            accountGate.note(WatchAccountKnowledge(check))
        }
        applyPendingPhone()
    }

    /// Asks the iPhone to open its connect screen. Only a request: the Watch never collects a
    /// password, a key, or a session.
    func openConnectOnPhone() {
        guard canOpenConnectOnPhone else { return }
        link.requestOpenConnect()
    }

    /// Recorded after the refresh ran, so a run the system cut short isn't one that went well.
    func noteBackgroundRefresh(cutShort: Bool) {
        SyncHealthLog.record(.backgroundRefresh, cutShort ? .timedOut : .ok, in: AppGroup.defaults)
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

/// Readings the iPhone hands over while it's near, and requests the Watch sends back.
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

    func refreshReadings() async -> ReadingCache? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }
        return await withCheckedContinuation { continuation in
            session.sendMessage(WatchHandoff.refreshReadingsMessage, replyHandler: { context in
                continuation.resume(returning: WatchHandoff.payload(in: context)?.cache)
            }, errorHandler: { _ in
                continuation.resume(returning: nil)
            })
        }
    }

    func receiveApplicationContext() async {
        guard let payload = WatchHandoff.payload(in: WCSession.default.receivedApplicationContext) else { return }
        await MainActor.run {
            onConnectAvailable?(payload.connectAvailable)
            onCache?(payload.cache)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    private func deliver(_ context: [String: Any]) {
        guard let payload = WatchHandoff.payload(in: context) else { return }
        // Absent from an iPhone with the connect screen off: false.
        Task { @MainActor in
            onConnectAvailable?(payload.connectAvailable)
            onCache?(payload.cache)
        }
    }

    private static let logger = Logger(subsystem: "app.tokenroom.watch", category: "phone-link")

    static let readingsKey = WatchHandoff.readingsKey
}
