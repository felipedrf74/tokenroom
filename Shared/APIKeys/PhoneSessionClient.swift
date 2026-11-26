import Foundation
import os

struct PhoneSessionClient: Sendable {
    typealias Send = @Sendable (URLRequest) async -> Result<QuotaSnapshot, ProviderError>
    typealias Request = @Sendable (Provider, String) -> URLRequest?

    static let notAllowed = "Couldn't start a session for this provider."
    static let needsSignIn = "Couldn't refresh this session. Sign in again."
    static let clientRefused = "Couldn't refresh this session: the provider turned down this sign-in. Sign in again, or read this plan on a Mac."
    static let cantRead = "Couldn't read this plan's usage with this sign-in."

    var provider: Provider
    var store: PhoneSessionStore
    var allowlist: Set<Provider> = PhoneConnect.productionAllowlist
    var request: Request = { PhoneSignIn.usageRequest(provider: $0, accessToken: $1) }
    var send: Send

    func fetch(now: Date = .now) async -> Result<QuotaSnapshot, ProviderError> {
        guard allowlist.contains(provider) else { return .failure(.signedOut(Self.notAllowed)) }
        guard let endpoint = request(provider, "")?.url, TokenroomRedirectPolicy.isSecureEndpoint(endpoint) else {
            return .failure(.unreachable)
        }
        let store = store
        let owner = PhoneSignIn.sessionOwner(for: provider)
        guard let session = await BlockingIO.run({
            guard store.metadata(for: owner)?.state == .ready else { return nil as PhoneSession? }
            return store.session(for: owner)
        }) else {
            return .failure(.signedOut(Self.needsSignIn))
        }
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

struct PhoneSessionReader: Sendable {
    var client: PhoneSessionClient
    var refresher: PhoneSessionRefresher

    func read(now: Date = .now) async -> Result<QuotaSnapshot, ProviderError> {
        let provider = PhoneSignIn.sessionOwner(for: client.provider)
        var renewal = await refresher.renewIfNeeded(provider, now: now)
        switch renewal {
        case .rejected, .noSession:
            return .failure(.signedOut(PhoneSessionClient.needsSignIn))
        case .clientRefused:
            return .failure(.signedOut(PhoneSessionClient.clientRefused))
        case .pendingWrite, .unreadable:
            return .failure(.unreachable)
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
            case .clientRefused:
                return .failure(.signedOut(PhoneSessionClient.clientRefused))
            default:
                break
            }
            if forced != .notDue { renewal = forced }
        }
        if case .failure(.expired) = result {
            if [.unavailable, .preflightFailed, .pendingWrite, .unreadable].contains(renewal) { return .failure(.unreachable) }
            return .failure(.expired(PhoneSessionClient.needsSignIn))
        }
        return result
    }
}

actor PhoneSessionRefresher {
    enum Grant: Sendable, Equatable {
        case granted(PhoneSession)
        case rejected
        case clientRefused
        case notDispatched
        case unavailable
    }

    enum Outcome: String, Sendable, Equatable {
        case notAllowed
        case noSession
        case notDue
        case preflightFailed = "preflight-failed"
        case refreshed
        case rejected
        case clientRefused = "client-refused"
        case unavailable
        case unreadable
        case pendingWrite
        case recovered
    }

    static let lead: TimeInterval = 180
    static let usableSlack: TimeInterval = 60
    static let writeAttempts = 3

    typealias Post = @Sendable (Provider, PhoneSession) async -> Grant

    private let store: PhoneSessionStore
    private let allowlist: Set<Provider>
    private let post: Post
    private var pending: [Provider: PhoneSession] = [:]
    private var flights: [Provider: Task<Outcome, Never>] = [:]
    private var replacing: Set<Provider> = []
    private var forcedAt: [Provider: Date] = [:]
    static let forcedRenewalSpacing: TimeInterval = 3600
    static let retrySpacing: TimeInterval = 60
    private var notDispatchedAt: [Provider: Date] = [:]
    private let logger = Logger(subsystem: "app.tokenroom.ios", category: "session")

    init(store: PhoneSessionStore, allowlist: Set<Provider> = PhoneConnect.productionAllowlist, post: @escaping Post) {
        self.store = store
        self.allowlist = allowlist
        self.post = post
    }

    func renewIfNeeded(_ provider: Provider, now: Date = .now, force: Bool = false) async -> Outcome {
        guard allowlist.contains(provider) else { return .notAllowed }
        guard !replacing.contains(provider) else { return .notDue }
        if let flight = flights[provider] {
            return await flight.value
        }
        if force {
            if let last = forcedAt[provider], (0..<Self.forcedRenewalSpacing).contains(now.timeIntervalSince(last)) { return .notDue }
            if isWaitingToRetry(provider, now: now) { return .unavailable }
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

    private func isWaitingToRetry(_ provider: Provider, now: Date) -> Bool {
        notDispatchedAt[provider].map { (0..<Self.retrySpacing).contains(now.timeIntervalSince($0)) } ?? false
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
        if isWaitingToRetry(provider, now: now) {
            return .unavailable
        }
        let ready = await BlockingIO.run { store.canReplace(provider) && store.setState(.exchanging, for: provider) }
        guard ready else { return .preflightFailed }
        switch await post(provider, session) {
        case .rejected:
            await BlockingIO.run { store.markRejected(for: provider, now: now) }
            return .rejected
        case .clientRefused:
            await BlockingIO.run { store.markRejected(for: provider, now: now, clientRefused: true) }
            return .clientRefused
        case .notDispatched:
            await BlockingIO.run { _ = store.setState(.ready, for: provider) }
            notDispatchedAt[provider] = now
            return .unavailable
        case .unavailable:
            return .unavailable
        case .granted(var grant):
            if grant.refreshToken.isEmpty {
                grant.refreshToken = session.refreshToken
            }
            pending[provider] = grant
            return await storeGrant(grant, for: provider)
        }
    }

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

    func replace(_ provider: Provider, with session: PhoneSession?, now: Date = .now) async throws {
        replacing.insert(provider)
        defer { replacing.remove(provider) }
        if let flight = flights[provider] {
            _ = await flight.value
        }
        pending[provider] = nil
        forcedAt[provider] = nil
        notDispatchedAt[provider] = nil
        let store = store
        if let session {
            try await BlockingIO.run {
                try store.clearRecovery(for: provider)
                try store.save(session, for: provider, now: now)
            }
        } else {
            try await BlockingIO.run { try store.remove(for: provider) }
        }
    }

    func recover(_ provider: Provider, now: Date = .now) async -> Outcome {
        let store = store
        if pending[provider] != nil { return .pendingWrite }
        guard await BlockingIO.run({ store.metadata(for: provider)?.state == .exchanging }) else { return .noSession }
        switch await BlockingIO.run({ store.recoveryLookup(for: provider) }) {
        case .found:
            break
        case .none:
            await BlockingIO.run { store.markRejected(for: provider, now: now) }
            return .rejected
        case .unreadable:
            return .unreadable
        }
        return await BlockingIO.run({ store.finishFromRecovery(for: provider) }) ? .recovered : .pendingWrite
    }
}
