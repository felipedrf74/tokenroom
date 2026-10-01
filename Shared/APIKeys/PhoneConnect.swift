import Foundation

/// What the iPhone offers for each provider, and who covers it. Pure: no Keychain, no login.
///
/// The decision, in order:
/// 1. A provider read with a key (`readsWithKey`, Copilot's fine-grained token included) is
///    `.addKey`, whatever a Mac shows: a pasted key for that provider stays available.
/// 2. A Mac reading for it that is still live is `.fromMac`. That blocks a second phone login
///    only. Another iPhone isn't a Mac; a stale, expired, or signed-out Mac card doesn't count.
/// 3. A provider on the allowlist is `.signIn`. The allowlist is empty in production.
/// 4. Everything else is `.needsMac`, with the reason as the row's copy and no button.
///
/// It never reads `isUnofficial`: that ignores Copilot's documented token and calls the pasted
/// coding-plan keys official.
enum PhoneConnect: Sendable {
    enum Action: Equatable, Sendable {
        /// A Mac reading is still live. Blocks a phone login, not a pasted key.
        case fromMac
        /// A pasted key, or Copilot's fine-grained token. On the key card and in API Keys, not
        /// on the connect screen.
        case addKey
        /// Reserved. The production allowlist is empty, so the default call never returns this.
        case signIn
        /// No button. `reason` is the row's copy.
        case needsMac(reason: String)
    }

    /// A collector's envelope and what kind of device it is.
    struct CoveringSource: Sendable {
        var kind: CollectorKind
        var envelope: RelayEnvelope
    }

    /// The only allowlist. Empty until a vendor documents a public client with a usage read that
    /// needs no secret and no identity. Tests pass their own set; production never does.
    static let productionAllowlist: Set<Provider> = []

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

    /// Whether a Mac is publishing a reading for this provider that's live now. Uses the merge's
    /// age limit and the freshness rules readers use, not a copy of their numbers.
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

    /// Why a provider can't be connected on the iPhone. Each line names the Mac, and none
    /// promises a sign-in.
    static func reason(for provider: Provider) -> String {
        switch provider {
        case .grok: "Needs Tokenroom on a Mac. Grok Build doesn't offer a usage API for other apps."
        case .grokBot: "Needs Tokenroom on a Mac. Grok Bot keeps its login in the Mac app."
        case .claude: "Needs Tokenroom on a Mac. Claude's plan login isn't available to other apps."
        case .openai: "Needs Tokenroom on a Mac. ChatGPT plan limits aren't available to other apps."
        case .cursor: "Needs Tokenroom on a Mac. Cursor doesn't offer a usage API for other apps."
        case .antigravity: "Needs Tokenroom on a Mac. Antigravity usage is read through the agy tool."
        case .devin: "Needs Tokenroom on a Mac. Devin keeps its login in the Mac app."
        default: "Needs Tokenroom on a Mac."
        }
    }

    /// The providers the connect screen lists: those that need a Mac, or that a Mac covers now.
    /// Key providers stay on the key card and in API Keys.
    static func connectList(sources: [CoveringSource], now: Date = .now, allowlist: Set<Provider> = productionAllowlist) -> [(provider: Provider, action: Action)] {
        Provider.allCases.compactMap { provider in
            let action = action(for: provider, sources: sources, now: now, allowlist: allowlist)
            switch action {
            case .fromMac, .needsMac: return (provider, action)
            case .addKey, .signIn: return nil
            }
        }
    }

    /// The footer under Usage's Not connected, with the connect screen on. Promises no sign-in.
    static func disconnectedFooter(_ actions: [Action]) -> String {
        let needsMac = actions.contains { $0 != .addKey }
        let keys = actions.contains { $0 == .addKey }
        switch (needsMac, keys) {
        case (true, true): return "These need Tokenroom on a Mac, or a key in Settings › API Keys."
        case (false, true): return "Check these keys in Settings › API Keys."
        default: return "These need Tokenroom on a Mac."
        }
    }

    // MARK: Flag

    /// Shows the connect screen and its copy. Off by default; off leaves every string as it was.
    /// Rolling back is shipping it off again. In `UserDefaults.standard`, not the App Group: the
    /// widgets don't read it, and the Watch learns it only as `connectAvailable`.
    static let flagKey = "connectOnIPhone"

    /// `-connectOnIPhone YES` on launch turns it on in any build, Release included, because
    /// launch arguments sit in the defaults' argument domain. TestFlight doesn't pass them.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if let argument = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[flagKey] {
            return (argument as? String).map { ["YES", "1", "true"].contains($0) } ?? (argument as? Bool ?? false)
        }
        return defaults.bool(forKey: flagKey)
    }
}

extension Array where Element == RelayMerge.Source {
    /// Merge sources as connect coverage, each with the kind of device behind it.
    var covering: [PhoneConnect.CoveringSource] {
        compactMap { source in
            guard let kind = source.kind else { return nil }
            return PhoneConnect.CoveringSource(kind: kind, envelope: source.envelope)
        }
    }
}
