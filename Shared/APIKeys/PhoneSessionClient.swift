import Foundation
import os

/// Reads usage with a phone session. The only type allowed to send a phone session's token, and
/// only for a provider on the allowlist, which is empty in production: for every other provider
/// it answers signed out without building a request. That keeps a CLI client (`ClaudeClient`,
/// `OpenAIClient`, `GrokClient`) from being pointed at the store by accident.
struct PhoneSessionClient: Sendable {
    /// Sends the request the client built; the provider's parser turns the answer into a reading.
    typealias Send = @Sendable (URLRequest) async -> Result<QuotaSnapshot, ProviderError>

    static let notAllowed = "Couldn't start a session for this provider."
    static let needsSignIn = "Couldn't refresh this session. Sign in again."

    var provider: Provider
    /// The vendor's documented usage endpoint for this public client.
    var usageURL: URL
    var store: PhoneSessionStore
    var allowlist: Set<Provider> = PhoneConnect.productionAllowlist
    var send: Send

    func fetch(now: Date = .now) async -> Result<QuotaSnapshot, ProviderError> {
        guard allowlist.contains(provider) else { return .failure(.signedOut(Self.notAllowed)) }
        guard TokenroomRedirectPolicy.isSecureEndpoint(usageURL) else { return .failure(.unreachable) }
        let store = store
        let provider = provider
        guard let session = await BlockingIO.run({
            guard store.metadata(for: provider)?.state == .ready else { return nil as PhoneSession? }
            return store.session(for: provider)
        }) else {
            return .failure(.signedOut(Self.needsSignIn))
        }
        // Inside its last minute an access token isn't sent; the refresher renews it first.
        if let expiresAt = session.expiresAt, expiresAt.timeIntervalSince(now) <= PhoneSessionRefresher.usableSlack {
            return .failure(.expired(Self.needsSignIn))
        }
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(TokenroomIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await send(request)
    }
}

/// Renews a phone session before it expires, without ever losing a rotated refresh token.
///
/// Before the token request: the Keychain must take a write (`canReplace`, which leaves the token
/// bytes alone), and the item is marked `exchanging`. After a grant, the new tokens go to the
/// recovery item and then replace the session; a failed write is retried as a write, never as
/// another request, and the grant is kept in memory until it lands. A launch that finds
/// `exchanging` finishes from the recovery item, or, without one, marks the session rejected
/// rather than sending the old refresh token the server may already have rotated.
actor PhoneSessionRefresher {
    /// What the token endpoint answered.
    enum Grant: Sendable, Equatable {
        case granted(PhoneSession)
        /// `invalid_grant`: the refresh token is no good.
        case rejected
        /// The sender can prove that no request was dispatched. Safe to retry the old token.
        case notDispatched
        /// An unreachable/invalid answer after a request may have rotated the token. Never
        /// implies the old refresh token is safe to send again.
        case unavailable
    }

    enum Outcome: String, Sendable, Equatable {
        case notAllowed
        case noSession
        case notDue
        case preflightFailed = "preflight-failed"
        case refreshed
        case rejected
        case unavailable
        /// The grant came back but isn't stored yet; it stays in memory and the next call
        /// retries the write.
        case pendingWrite
        /// A launch found `exchanging` and finished from the recovery item.
        case recovered
    }

    /// `OAuthRefresh.lead` on the Mac: renew three minutes before expiry.
    static let lead: TimeInterval = 180
    /// `OAuthRefresh.usableSlack`: an access token in its last minute isn't sent.
    static let usableSlack: TimeInterval = 60
    /// Write attempts per call before the grant waits in memory for the next one.
    static let writeAttempts = 3

    typealias Post = @Sendable (Provider, PhoneSession) async -> Grant

    private let store: PhoneSessionStore
    private let allowlist: Set<Provider>
    private let post: Post
    private var pending: [Provider: PhoneSession] = [:]
    private var flights: [Provider: Task<Outcome, Never>] = [:]
    private let logger = Logger(subsystem: "app.tokenroom.ios", category: "session")

    init(store: PhoneSessionStore, allowlist: Set<Provider> = PhoneConnect.productionAllowlist, post: @escaping Post) {
        self.store = store
        self.allowlist = allowlist
        self.post = post
    }

    /// One renewal per provider at a time: a second caller waits for the first, so two can't
    /// rotate the same refresh token.
    func renewIfNeeded(_ provider: Provider, now: Date = .now) async -> Outcome {
        guard allowlist.contains(provider) else { return .notAllowed }
        if let flight = flights[provider] {
            return await flight.value
        }
        let flight = Task { await self.renew(provider, now: now) }
        flights[provider] = flight
        let outcome = await flight.value
        flights[provider] = nil
        if outcome != .notDue && outcome != .noSession {
            logger.notice("\(provider.rawValue, privacy: .public) \(outcome.rawValue, privacy: .public)")
        }
        return outcome
    }

    private func renew(_ provider: Provider, now: Date) async -> Outcome {
        let store = store
        if let grant = pending[provider] {
            return await storeGrant(grant, for: provider)
        }
        let metadata = await BlockingIO.run { store.metadata(for: provider) }
        if metadata?.state == .exchanging {
            return await recover(provider, now: now)
        }
        guard let session = await BlockingIO.run({ store.session(for: provider) }) else { return .noSession }
        guard let expiresAt = session.expiresAt, expiresAt.timeIntervalSince(now) <= Self.lead else { return .notDue }
        let ready = await BlockingIO.run { store.canReplace(provider) && store.setState(.exchanging, for: provider) }
        guard ready else { return .preflightFailed }
        switch await post(provider, session) {
        case .rejected:
            await BlockingIO.run { store.markRejected(for: provider, now: now) }
            return .rejected
        case .notDispatched:
            await BlockingIO.run { _ = store.setState(.ready, for: provider) }
            return .unavailable
        case .unavailable:
            // Preserve exchanging: a later call recovers a durable grant, or rejects this
            // session without replaying the old refresh token after an ambiguous response.
            return .unavailable
        case .granted(let grant):
            pending[provider] = grant
            return await storeGrant(grant, for: provider)
        }
    }

    /// The recovery item, then the session item. Only Keychain writes: no token request.
    private func storeGrant(_ grant: PhoneSession, for provider: Provider) async -> Outcome {
        let store = store
        for _ in 0..<Self.writeAttempts {
            let stored = await BlockingIO.run { store.saveRecovery(grant, for: provider) && store.finishFromRecovery(for: provider) }
            if stored {
                pending[provider] = nil
                return .refreshed
            }
        }
        return .pendingWrite
    }

    /// A launch that finds `exchanging`: the process died during a renewal. Never sends the old
    /// refresh token.
    func recover(_ provider: Provider, now: Date = .now) async -> Outcome {
        let store = store
        if pending[provider] != nil { return .pendingWrite }
        guard await BlockingIO.run({ store.metadata(for: provider)?.state == .exchanging }) else { return .noSession }
        guard await BlockingIO.run({ store.takeRecovery(for: provider) != nil }) else {
            // The server may have rotated the refresh token, and the new one never landed.
            await BlockingIO.run { store.markRejected(for: provider, now: now) }
            return .rejected
        }
        // The new grant is safe in the recovery item; a failed replace is tried again later.
        return await BlockingIO.run({ store.finishFromRecovery(for: provider) }) ? .recovered : .pendingWrite
    }
}
