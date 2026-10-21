import Foundation
import os

/// Reads usage with a phone session. The only type allowed to send a phone session's token, and
/// only for a provider on the allowlist: for every other provider it answers signed out without
/// building a request. That keeps a CLI client (`ClaudeClient`, `OpenAIClient`, `GrokClient`),
/// which reads the Mac's CLI logins, from being pointed at the store by accident.
struct PhoneSessionClient: Sendable {
    /// Sends the request the client built; the provider's parser turns the answer into a reading.
    typealias Send = @Sendable (URLRequest) async -> Result<QuotaSnapshot, ProviderError>
    /// The usage request for a provider and an access token.
    typealias Request = @Sendable (Provider, String) -> URLRequest?

    static let notAllowed = "Couldn't start a session for this provider."
    static let needsSignIn = "Couldn't refresh this session. Sign in again."
    static let cantRead = "Couldn't read this plan's usage with this sign-in."

    var provider: Provider
    var store: PhoneSessionStore
    var allowlist: Set<Provider> = PhoneConnect.productionAllowlist
    var request: Request = { PhoneSignIn.usageRequest(provider: $0, accessToken: $1) }
    var send: Send

    func fetch(now: Date = .now) async -> Result<QuotaSnapshot, ProviderError> {
        guard allowlist.contains(provider) else { return .failure(.signedOut(Self.notAllowed)) }
        // An unsafe endpoint never gets the token, and needs no Keychain read to be refused.
        guard let endpoint = request(provider, "")?.url, TokenroomRedirectPolicy.isSecureEndpoint(endpoint) else {
            return .failure(.unreachable)
        }
        let store = store
        // Grok Bot reads with Cursor's session.
        let owner = PhoneSignIn.sessionOwner(for: provider)
        guard let session = await BlockingIO.run({
            guard store.metadata(for: owner)?.state == .ready else { return nil as PhoneSession? }
            return store.session(for: owner)
        }) else {
            return .failure(.signedOut(Self.needsSignIn))
        }
        // Inside its last minute an access token isn't sent; the refresher renews it first.
        if let expiresAt = session.expiresAt, expiresAt.timeIntervalSince(now) <= PhoneSessionRefresher.usableSlack {
            return .failure(.expired(Self.needsSignIn))
        }
        guard var request = request(provider, session.accessToken), request.url == endpoint else { return .failure(.unreachable) }
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(TokenroomIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return await send(request)
    }

    /// Sends a usage request and parses the answer with the provider's parser. Only a 401 means
    /// the access token ended (and is renewed once); a 403 means this sign-in can't read usage,
    /// which renewing wouldn't change.
    static func live(_ provider: Provider) -> Send {
        { request in
            do {
                let (data, response) = try await TokenroomHTTP.data(for: request)
                if response.statusCode == 403 { return .failure(.notEntitled(cantRead)) }
                try TokenroomHTTP.check(response, provider: provider)
                return .success(try PhoneSignIn.snapshot(provider: provider, from: data, fetchedAt: .now))
            } catch let error as ProviderError {
                return .failure(error)
            } catch {
                return .failure(.parse)
            }
        }
    }
}

/// A phone session's reading: renewed first when it's due, and once more when the provider turns
/// the access token down (at most hourly, `PhoneSessionRefresher.forcedRenewalSpacing`), so a
/// token the vendor ended early doesn't wait for its expiry date. A refresh token that's refused,
/// or a session with none left, asks to sign in again, in the phone's own words rather than the
/// CLI's. A renewal that couldn't reach the token host (offline) is a connection problem, not a
/// reason to sign in again.
struct PhoneSessionReader: Sendable {
    var client: PhoneSessionClient
    var refresher: PhoneSessionRefresher

    func read(now: Date = .now) async -> Result<QuotaSnapshot, ProviderError> {
        // Renewals go to the session's owner: Grok Bot's renews Cursor's.
        let provider = PhoneSignIn.sessionOwner(for: client.provider)
        var renewal = await refresher.renewIfNeeded(provider, now: now)
        switch renewal {
        case .rejected, .noSession:
            return .failure(.signedOut(PhoneSessionClient.needsSignIn))
        default:
            break
        }
        var result = await client.fetch(now: now)
        if case .failure(.expired) = result {
            let forced = await refresher.renewIfNeeded(provider, now: now, force: true)
            switch forced {
            case .refreshed, .recovered:
                result = await client.fetch(now: now)
            case .rejected, .noSession:
                return .failure(.signedOut(PhoneSessionClient.needsSignIn))
            default:
                break
            }
            // An early renewal held back by its hourly spacing says nothing new: the first
            // renewal's outcome (offline, say) still explains the expired token.
            if forced != .notDue { renewal = forced }
        }
        if case .failure(.expired) = result {
            // The token host couldn't be reached, or the write is still pending: try later.
            if [.unavailable, .preflightFailed, .pendingWrite].contains(renewal) { return .failure(.unreachable) }
            return .failure(.expired(PhoneSessionClient.needsSignIn))
        }
        return result
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
        /// No token was issued: the sender can prove no request was dispatched, or the host
        /// answered with an OAuth error other than `invalid_grant` (RFC 6749 §5.2). Safe to
        /// retry the old token.
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
    /// Providers being signed in again or out (`replace`): no renewal starts meanwhile.
    private var replacing: Set<Provider> = []
    /// When each provider was last renewed early because its usage endpoint turned the token
    /// down. An endpoint that keeps doing so gets one early renewal an hour, not one a read.
    private var forcedAt: [Provider: Date] = [:]
    static let forcedRenewalSpacing: TimeInterval = 3600
    private let logger = Logger(subsystem: "app.tokenroom.ios", category: "session")

    init(store: PhoneSessionStore, allowlist: Set<Provider> = PhoneConnect.productionAllowlist, post: @escaping Post) {
        self.store = store
        self.allowlist = allowlist
        self.post = post
    }

    /// One renewal per provider at a time: a second caller waits for the first, so two can't
    /// rotate the same refresh token.
    /// - Parameter force: renew even before the lead time, because the provider turned the access
    ///   token down.
    func renewIfNeeded(_ provider: Provider, now: Date = .now, force: Bool = false) async -> Outcome {
        guard allowlist.contains(provider) else { return .notAllowed }
        guard !replacing.contains(provider) else { return .notDue }
        if let flight = flights[provider] {
            return await flight.value
        }
        if force {
            if let last = forcedAt[provider], (0..<Self.forcedRenewalSpacing).contains(now.timeIntervalSince(last)) { return .notDue }
            forcedAt[provider] = now
        }
        let flight = Task { await self.renew(provider, now: now, force: force) }
        flights[provider] = flight
        let outcome = await flight.value
        flights[provider] = nil
        if outcome != .notDue && outcome != .noSession {
            logger.notice("\(provider.rawValue, privacy: .public) \(outcome.rawValue, privacy: .public)")
        }
        return outcome
    }

    private func renew(_ provider: Provider, now: Date, force: Bool) async -> Outcome {
        let store = store
        if let grant = pending[provider] {
            return await storeGrant(grant, for: provider)
        }
        let metadata = await BlockingIO.run { store.metadata(for: provider) }
        if metadata?.state == .exchanging {
            return await recover(provider, now: now)
        }
        guard let session = await BlockingIO.run({ store.session(for: provider) }) else { return .noSession }
        if !force {
            guard let expiresAt = session.expiresAt, expiresAt.timeIntervalSince(now) <= Self.lead else { return .notDue }
        }
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
        case .granted(var grant):
            // A host that doesn't rotate the refresh token may leave it out of the answer.
            if grant.refreshToken.isEmpty {
                grant.refreshToken = session.refreshToken
            }
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

    /// A new sign-in (`session`) or signing out (nil). A renewal already under way finishes first,
    /// so its write lands before this one and can't bring a removed session back or replace a
    /// newer one; a grant still waiting to be written is dropped; no renewal starts meanwhile.
    func replace(_ provider: Provider, with session: PhoneSession?, now: Date = .now) async throws {
        replacing.insert(provider)
        defer { replacing.remove(provider) }
        if let flight = flights[provider] {
            _ = await flight.value
        }
        pending[provider] = nil
        forcedAt[provider] = nil
        let store = store
        if let session {
            // An old renewal's grant must never be recovered over the new sign-in: if it can't be
            // deleted, the sign-in isn't saved.
            try await BlockingIO.run {
                try store.clearRecovery(for: provider)
                try store.save(session, for: provider, now: now)
            }
        } else {
            try await BlockingIO.run { try store.remove(for: provider) }
        }
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
