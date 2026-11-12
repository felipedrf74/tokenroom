import Foundation

/// Saving the App Group file does not replace a WidgetKit timeline. Keep the last reload
/// request separately, across app launches, so unchanged checks and deferred changes reach it.
enum WidgetReloadSchedule {
    static let defaultsKey = "widgetReloadBaseline"
    static let checkStep: TimeInterval = 45 * 60

    struct Baseline: Codable {
        var requestedAt: Date
        var isSample: Bool
        var accountGeneration: String?
        var providers: [RelayProvider]

        init(cache: ReadingCache, at now: Date) {
            requestedAt = now
            isSample = cache.isSample
            accountGeneration = cache.accountGeneration
            providers = cache.items.map(\.provider)
        }

        var cache: ReadingCache {
            ReadingCache(savedAt: requestedAt, isSample: isSample,
                         items: providers.map { .init(provider: $0, source: "") },
                         accountGeneration: accountGeneration)
        }
    }

    static func load(from defaults: UserDefaults) -> Baseline? {
        defaults.data(forKey: defaultsKey).flatMap { try? RelayEnvelope.decoder.decode(Baseline.self, from: $0) }
    }

    static func record(_ cache: ReadingCache, at now: Date, in defaults: UserDefaults) {
        guard let data = try? RelayEnvelope.encoder.encode(Baseline(cache: cache, at: now)) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func needsReload(_ cache: ReadingCache, since baseline: Baseline?, at now: Date,
                            background: Bool, reloads: Int) -> Bool {
        guard let baseline, baseline.accountGeneration == cache.accountGeneration else { return true }
        let previous = baseline.cache
        if background {
            if cache.reloadSignature != previous.reloadSignature,
               cache.reloadSignature(at: now) != previous.reloadSignature(at: now) { return true }
        } else if cache.materialHash(at: now) != previous.materialHash(at: now) {
            return true
        }
        // A future collector date counts as now. Store the effective date when requesting a
        // reload too, so a fast collector cannot delay renewal on subsequent heartbeats.
        let previousChecks = WatchHandoffSchedule.checks(in: previous)
        let step = background ? checkStep : 0
        let advanced = cache.presented(at: now).items.contains { item in
            guard item.provider.isLive, let checked = item.provider.checkedAt ?? item.provider.fetchedAt,
                  let old = previousChecks[item.id] else { return false }
            let oldCheck = min(old, baseline.requestedAt)
            let moved = min(checked, now).timeIntervalSince(oldCheck)
            return moved > 0 && moved >= step
        }
        return advanced && (!background || reloads < WidgetSchedule.busyAllowance)
    }
}

/// A failed due read gets another opportunity soon, rather than an hour of stale presentation.
/// Sixteen short retries leave room for hourly recovery for the rest of a day (under forty
/// builds even when continuously offline). A server wait always wins.
struct WidgetRefreshResult: Sendable {
    static let retryAllowance = 16
    var cache: ReadingCache?
    var retryAt: Date? = nil

    func nextReload(after now: Date, reloads: Int) -> Date {
        if let retryAt {
            let interval = reloads < Self.retryAllowance ? 5 * 60.0 : WidgetSchedule.calmInterval
            return max(now.addingTimeInterval(interval), retryAt)
        }
        return cache?.nextReload(after: now, reloads: reloads)
            ?? WidgetSchedule.nextReload(after: now, items: [], reloads: reloads)
    }
}
