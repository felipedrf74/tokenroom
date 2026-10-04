import CloudKit
import Foundation
import Synchronization

/// Readings for widgets: the app's cache, refreshed here when it's old, within a few seconds.
/// Reads the relay and this iPhone's keys like the app does, but never writes to iCloud.
enum WidgetRefresher {
    /// A cache older than this is refreshed before a timeline is built.
    static let maxAge: TimeInterval = 15 * 60
    /// The most time a widget spends fetching.
    static let budget: TimeInterval = 6
    /// iCloud and each key provider get a second under the widget's own limit, so a slow one
    /// doesn't cost the rest and there's time to put what came back together.
    static let readBudget = budget - 1
    static let localLabel = "This iPhone"

    private static let accountObserver = RelayAccountObserver(name: .CKAccountChanged) {
        PhoneCacheAccess.invalidate(in: AppGroup.defaults)
    }

    static func cache(force: Bool = false, now: Date = .now) async -> ReadingCache? {
        _ = accountObserver
        if AppGroup.defaults.bool(forKey: "sampleMode") {
            return SampleData.cache(now: now)
        }
        let cached = PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults)
        if !force, let cached, (0..<maxAge).contains(now.timeIntervalSince(cached.savedAt)) {
            return cached
        }
        // Widgets whose timelines are due together share one refresh, rather than each reading
        // iCloud and calling every key provider.
        let task = running.withLock { running -> Task<ReadingCache?, Never> in
            if let running {
                return running
            }
            let task = Task { await TimeLimit.run(budget, otherwise: nil) { await refresh(previous: cached, now: now) } }
            running = task
            return task
        }
        let refreshed = await task.value
        running.withLock { running in
            if running == task {
                running = nil
            }
        }
        return refreshed.flatMap { PhoneCacheAccess.accepts($0, defaults: AppGroup.defaults) ? $0 : nil }
            ?? PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults)
    }

    /// The refresh under way in this process.
    private static let running = Mutex<Task<ReadingCache?, Never>?>(nil)

    /// Saves what it read for the app and the other widgets.
    static func refresh(previous: ReadingCache?, now: Date) async -> ReadingCache? {
        let defaults = AppGroup.defaults
        var generation = PhoneCacheAccess.generation(in: defaults)
        // A refresh can start after the account changed but hold a cache captured before it.
        // Never stamp that previous account's data with the new generation.
        let previous = previous.flatMap {
            !$0.isSample && PhoneCacheAccess.accepts($0, defaults: defaults) ? $0 : nil
        }
        let ownID = defaults.string(forKey: "relaySourceID")
        async let relayRead = readRelay()
        async let keyRead = readKeys(defaults: defaults, now: now)
        let (relayResult, (fresh, readings, failures)) = await (relayRead, keyRead)
        guard generation == PhoneCacheAccess.generation(in: defaults) else { return nil }
        let contents = relayResult.contents
        let signedOut = relayResult.signedOut
        if signedOut {
            PhoneCacheAccess.invalidate(in: defaults)
            generation = PhoneCacheAccess.generation(in: defaults)
        }
        guard contents != nil || !fresh.isEmpty || signedOut || (previous != nil && !failures.isEmpty) else { return nil }
        // For the week's history: the app records these the next time it refreshes.
        HistoryStore.queue(readings, in: AppGroup.containerURL)

        // This iPhone's providers: what was just read, else the newer of its last relayed and
        // cached readings.
        let ownRecord = contents?.sources.first { $0.id == ownID }?.envelope
        let previousOwn = previous?.localSource?.envelope.providers
            ?? previous?.items.filter { $0.source == localLabel }.map(\.provider) ?? []
        // As in the app: only providers that still have a key, and readings up to a week old.
        let keyed = (defaults.array(forKey: "keyedProviders") as? [String]).map(Set.init)
        var own = fresh
        for provider in (ownRecord?.providers ?? []) + previousOwn where !fresh.contains(where: { $0.id == provider.id }) {
            guard keyed?.contains(provider.id) ?? true,
                  let time = Self.readingTime(provider), now.timeIntervalSince(time) < RelayMerge.maxSourceAge
            else { continue }
            if let index = own.firstIndex(where: { $0.id == provider.id }) {
                if Self.readingTime(provider) ?? .distantPast > Self.readingTime(own[index]) ?? .distantPast {
                    own[index] = provider
                }
            } else {
                own.append(provider)
            }
        }

        own = own.map { provider in
            guard let id = Provider(rawValue: provider.id), let error = failures[id] else { return provider }
            return provider.retainingAfterFailure(error, at: now)
        }

        var sources = (contents?.sources ?? []).compactMap { source -> RelayMerge.Source? in
            guard source.id != ownID, let envelope = source.envelope else { return nil }
            return RelayMerge.Source(id: source.id, label: source.label, envelope: envelope, kind: CollectorKind(recordKind: source.kind))
        }
        var histories = contents?.histories ?? [:]
        if contents == nil, !signedOut, let previous {
            // iCloud didn't answer in time: the other devices' readings from last time stay,
            // rather than leaving only this iPhone's.
            for carried in previous.carriedSources(excluding: localLabel) {
                sources.append(carried.source)
                histories[carried.source.id] = carried.history
            }
        }
        let localSource = ownID.map { id in
            RelayMerge.Source(id: id, label: localLabel,
                envelope: RelayEnvelope(producer: "iphone", appVersion: TokenroomIdentity.version, checkedAt: now, providers: own),
                kind: .thisPhone)
        }
        if let localSource, !own.isEmpty {
            sources.append(localSource)
            let ownID = localSource.id
            histories[ownID] = RelayHistory(series: HistoryStore.loadWithPending(from: AppGroup.containerURL, now: now))
        }
        let output = ReadingAssembler.assemble(sources: sources, histories: histories, now: now)
        var cache = ReadingCache(savedAt: now, isSample: false, items: output.connected)
        cache.localSource = localSource.map(ReadingCache.SourceSnapshot.init)
        do {
            guard try PhoneCacheAccess.save(cache, at: ReadingCache.defaultURL, defaults: defaults, generation: generation) else { return nil }
        } catch { return nil }
        return PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: defaults)
    }

    private static func readingTime(_ provider: RelayProvider) -> Date? {
        provider.checkedAt ?? provider.fetchedAt
    }

    /// Nil without iCloud, or when it doesn't answer within its share of the widget's seconds;
    /// `refresh` then keeps the other devices' last readings beside this iPhone's fresh ones.
    private struct RelayResult: Sendable {
        var contents: CloudRelay.Contents?
        var signedOut = false
    }

    private static func readRelay() async -> RelayResult {
        guard let container = RelayAvailability.containerIdentifier else { return RelayResult() }
        return await TimeLimit.run(readBudget, otherwise: RelayResult()) {
            let relay = CloudRelay.shared(containerIdentifier: container)
            let status = try? await relay.accountStatus()
            if status == .noAccount { return RelayResult(signedOut: true) }
            guard status == .available else { return RelayResult() }
            do { return RelayResult(contents: try await relay.contents()) }
            catch let error as CKError where error.code == .notAuthenticated { return RelayResult(signedOut: true) }
            catch { return RelayResult() }
        }
    }

    /// Providers read with this iPhone's keys, and the readings themselves (with budgets) for
    /// history. Failed attempts downgrade their retained reading; providers resting between
    /// calls (spacing, a 429) retain their previous measurement and state.
    private static func readKeys(defaults: UserDefaults, now: Date) async -> (providers: [RelayProvider], readings: [QuotaSnapshot], failures: [Provider: ProviderError]) {
        let keys = APIKeyStore(accessGroup: AppGroup.keychainGroup)
        let gate = KeyFetchGate(defaults: defaults)
        let providers = await BlockingIO.run {
            Provider.allCases.filter { $0.readsWithKey && keys.hasKey(for: $0) }
        }.filter { !gate.isResting($0, now: now) }
        guard !providers.isEmpty else { return ([], [], [:]) }
        let budgets = defaults.dictionary(forKey: "budgets") as? [String: Double] ?? [:]
        for provider in providers {
            gate.recordAttempt(provider, at: now)
        }
        let (snapshots, failures) = await withTaskGroup(of: (Provider, Result<QuotaSnapshot, ProviderError>).self) { group in
            for provider in providers {
                group.addTask {
                    await (provider, APIKeyClient(provider: provider, keys: keys).fetchWithinBudget(readBudget))
                }
            }
            var snapshots: [QuotaSnapshot] = []
            var failures: [Provider: ProviderError] = [:]
            for await (provider, result) in group {
                switch result {
                case .success(let snapshot):
                    gate.block(provider, until: nil)
                    snapshots.append(snapshot)
                case .failure(.rateLimited(let until)):
                    failures[provider] = .rateLimited(until: until)
                    gate.block(provider, until: ProviderStatus.clampedRetry(until, now: now))
                case .failure(let error):
                    failures[provider] = error
                }
            }
            return (snapshots, failures)
        }
        let readings = providers.compactMap { provider in
            snapshots.first { $0.provider == provider }.map { $0.applyingBudget(budgets[provider.rawValue]) }
        }
        return (readings.map { RelayProvider(provider: $0.provider, status: .live($0), checkedAt: $0.fetchedAt) }, readings, failures)
    }
}
