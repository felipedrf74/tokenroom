import Foundation

enum PhoneConnect: Sendable {
    enum Action: Equatable, Sendable {
        case fromMac
        case addKey
        case signIn
        case needsMac(reason: String)
    }

    struct CoveringSource: Sendable {
        var kind: CollectorKind
        var envelope: RelayEnvelope
    }

    static let productionAllowlist: Set<Provider> = [.openai, .grok, .cursor, .grokBot]

    static func action(
        for provider: Provider,
        sources: [CoveringSource],
        now: Date = .now,
        allowlist: Set<Provider> = productionAllowlist
    ) -> Action {
        if provider.readsWithKey {
            return .addKey
        }
        if isCoveredByMac(provider, sources: sources, now: now) {
            return .fromMac
        }
        if allowlist.contains(provider) {
            return .signIn
        }
        return .needsMac(reason: reason(for: provider))
    }

    static func isCoveredByMac(_ provider: Provider, sources: [CoveringSource], now: Date = .now) -> Bool {
        sources.contains { source in
            guard source.kind == .mac, now.timeIntervalSince(source.envelope.checkedAt) <= RelayMerge.maxSourceAge else { return false }
            return source.envelope.providers.contains { saved in
                guard saved.id == provider.rawValue,
                      let shown = ReadingFreshness.present(saved, fallback: source.envelope.checkedAt, now: now)
                else { return false }
                return shown.state == "live"
            }
        }
    }

    static func macReadingAge(_ provider: Provider, sources: [CoveringSource], now: Date = .now) -> TimeInterval? {
        sources.compactMap { source -> TimeInterval? in
            guard source.kind == .mac, now.timeIntervalSince(source.envelope.checkedAt) <= RelayMerge.maxSourceAge else { return nil }
            return source.envelope.providers.compactMap { saved -> TimeInterval? in
                guard saved.id == provider.rawValue,
                      let shown = ReadingFreshness.present(saved, fallback: source.envelope.checkedAt, now: now),
                      shown.state == "live"
                else { return nil }
                let checked = saved.checkedAt ?? saved.fetchedAt ?? source.envelope.checkedAt
                return now.timeIntervalSince(ReadingFreshness.ordering(checked, now: now))
            }.min()
        }.min()
    }

    static func reason(for provider: Provider) -> String {
        switch provider {
        case .grok: "Needs Tokenroom on a Mac. Grok Build doesn't offer a usage API for other apps."
        case .grokBot: "Needs Tokenroom on a Mac. Grok Bot keeps its login in the Mac app."
        case .claude: "Needs Tokenroom on a Mac. Anthropic doesn't allow Claude logins in other apps."
        case .openai: "Needs Tokenroom on a Mac. ChatGPT plan limits aren't available to other apps."
        case .cursor: "Needs Tokenroom on a Mac. Cursor doesn't offer a usage API for other apps."
        case .antigravity: "Needs Tokenroom on a Mac. Antigravity usage is read through the agy tool."
        case .devin: "Needs Tokenroom on a Mac. Devin keeps its login in the Mac app."
        default: "Needs Tokenroom on a Mac."
        }
    }

    static func connectList(sources: [CoveringSource], now: Date = .now, allowlist: Set<Provider> = productionAllowlist) -> [(provider: Provider, action: Action)] {
        Provider.allCases.compactMap { provider in
            let action = action(for: provider, sources: sources, now: now, allowlist: allowlist)
            switch action {
            case .fromMac, .needsMac, .signIn: return (provider, action)
            case .addKey: return nil
            }
        }
    }

    static func disconnectedFooter(_ actions: [Action]) -> String {
        let signIn = actions.contains(.signIn)
        let keys = actions.contains(.addKey)
        let needsMac = actions.contains { $0 != .signIn && $0 != .addKey }
        switch (signIn, keys, needsMac) {
        case (false, false, _): return "These need Tokenroom on a Mac."
        case (false, true, false): return "Check these keys in Settings › API Keys."
        case (false, true, true): return "These need Tokenroom on a Mac, or a key in Settings › API Keys."
        case (true, false, false): return "Sign in to these in Settings › Plans."
        case (true, false, true): return "Sign in to these in Settings › Plans, or use Tokenroom on a Mac."
        case (true, true, false): return "Sign in to these in Settings › Plans, or check their keys in Settings › API Keys."
        case (true, true, true): return "Sign in to these in Settings › Plans, check their keys in Settings › API Keys, or use Tokenroom on a Mac."
        }
    }

    static let flagKey = "connectOnIPhone"
    static let defaultValue = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[flagKey] {
            return (argument as? String).map { ["YES", "1", "true"].contains($0) } ?? (argument as? Bool ?? defaultValue)
        }
        return defaults.object(forKey: flagKey) as? Bool ?? defaultValue
    }
}

enum MacCoveragePause {
    static let pauseWithin: TimeInterval = 15 * 60
    static let resumeAfter: TimeInterval = 25 * 60
    static let defaultsKey = "sessionsPausedByMac"

    static func isPaused(macAge: TimeInterval?, wasPaused: Bool, manual: Bool) -> Bool {
        guard !manual else { return false }
        return remembered(macAge: macAge, wasPaused: wasPaused)
    }

    static func remembered(macAge: TimeInterval?, wasPaused: Bool) -> Bool {
        guard let macAge else { return false }
        if macAge <= pauseWithin { return true }
        if macAge > resumeAfter { return false }
        return wasPaused
    }

    static func detail(planName: String) -> String {
        "Paused: your Mac reads \(planName)"
    }
}

extension Array where Element == RelayMerge.Source {
    var covering: [PhoneConnect.CoveringSource] {
        compactMap { source in
            guard let kind = source.kind else { return nil }
            return PhoneConnect.CoveringSource(kind: kind, envelope: source.envelope)
        }
    }
}
