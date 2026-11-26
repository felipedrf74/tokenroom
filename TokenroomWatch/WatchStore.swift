import Foundation
import Observation
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

@Observable
@MainActor
final class WatchStore {
    static let backgroundTaskID = "app.tokenroom.watch.refresh"
    static let resetSoonKind = "watch.resetSoon"
    static let backgroundInterval: TimeInterval = 15 * 60
    static let readBudget: TimeInterval = 10
    static let phoneBudget: TimeInterval = 16

    typealias Problem = WatchProblem

    private(set) var cache: ReadingCache?
    var isRefreshing: Bool { refreshGate.isRefreshing }
    private(set) var problem: Problem?
    var openedProvider: String?
    private(set) var phoneOffersConnect = false
    private(set) var phoneReachable = false

    var canOpenConnectOnPhone: Bool {
        phoneOffersConnect && phoneReachable
    }
    private var refreshGate = WatchRefreshGate()
    private var accountGate = WatchAccountGate(signedOutAt: AppGroup.defaults.object(forKey: "watchSignedOutAt") as? Date)
    private var pendingPhone: ReadingCache?
    private var accountRevision = 0
    private let cacheURL = ReadingCache.defaultURL
    private let pendingURL = WatchPendingHandoff.defaultURL
    private let link = PhoneLink()
    private var showsSample = false
    private var showsEmpty = false

    init() {
        cache = WatchCacheAccess.load(at: cacheURL, defaults: AppGroup.defaults)
        pendingPhone = WatchPendingHandoff.load(at: pendingURL, signedOutAt: accountGate.signedOutAt)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "sampleMode") {
            cache = SampleData.cache()
            showsSample = true
        }
        if UserDefaults.standard.bool(forKey: "TokenroomEmpty") {
            cache = nil
            showsEmpty = true
        }
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
        let link = self.link
        let known = cache
        await WatchRefreshOrder.run(
            cloud: { await TimeLimit.run(Self.readBudget, otherwise: .failed) { await RelayReadings.read(now: now, known: known) } },
            phone: { await TimeLimit.run(Self.phoneBudget, otherwise: Optional<ReadingCache>.none) { await link.refreshReadings() } },
            applyCloud: { outcome in
                guard revision == accountRevision, currentCutoff == cutoff else {
                    _ = refreshGate.begin(force: true, now: .now)
                    return false
                }
                applyCloudOutcome(outcome, now: now)
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
            if cache == nil {
                cache = SampleData.cache(now: now)
            }
            problem = nil
        }
    }

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
        if problem == .noAccount { problem = nil }
    }

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

    func receiveBackgroundHandoff() async {
        await link.receiveApplicationContext()
        await settlePendingPhone()
        scheduleBackgroundRefresh()
    }

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

    func openConnectOnPhone() {
        guard canOpenConnectOnPhone else { return }
        link.requestOpenConnect()
    }

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

final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let openKey = WatchHandoff.openKey
    static let openConnect = WatchHandoff.openConnect

    var onCache: (@MainActor (ReadingCache) -> Void)?
    var onConnectAvailable: (@MainActor (Bool) -> Void)?
    var onReachability: (@MainActor (Bool) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
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
        Task { @MainActor in
            onConnectAvailable?(payload.connectAvailable)
            onCache?(payload.cache)
        }
    }

    private static let logger = Logger(subsystem: "app.tokenroom.watch", category: "phone-link")

    static let readingsKey = WatchHandoff.readingsKey
}
