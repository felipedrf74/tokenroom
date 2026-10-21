import Foundation

/// Sends `PhoneSignIn`'s requests: starts a sign-in, waits for it, and renews a session. Returns
/// sessions; saving them is the caller's (`PhoneSessionStore`). Tests pass `send` and `sleep`.
struct PhoneSignInClient: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    var send: Send = { try await TokenroomHTTP.data(for: $0) }
    var sleep: Sleep = { try await Task.sleep(for: .seconds($0)) }

    enum Failure: Error, Equatable, Sendable {
        case unreachable
        /// The vendor isn't offering a code sign-in (Codex answers 404).
        case notOffered
        case denied
        case expired
        case emptyCode
        case otherSignIn
        /// The vendor refused the code or the exchange.
        case refused
        /// The answer had no refresh token, so the session couldn't be renewed.
        case noRenewal

        func message(for provider: Provider) -> String {
            let name = provider.displayName
            return switch self {
            case .unreachable: "Couldn't reach \(name). Check the connection, then try again."
            case .notOffered: "Couldn't start a code sign-in: \(name) isn't offering one right now."
            case .denied: "Couldn't sign in: the request was turned down on \(name)'s page."
            case .expired: "Couldn't sign in before the code expired. Start again."
            case .emptyCode: "Couldn't find a code there. Copy the whole code \(name) shows, then paste it."
            case .otherSignIn: "Couldn't use that code: it's from another sign-in. Start again, then paste the new one."
            case .refused: "Couldn't finish \(name) sign-in. Start again."
            case .noRenewal: "Couldn't keep this sign-in: \(name) didn't send a way to renew it."
            }
        }
    }

    // MARK: Device code

    func startDeviceCode(for provider: Provider, now: Date = .now) async throws -> PhoneSignIn.DeviceCode {
        // Cursor's sign-in is made here; there's nothing to ask for first.
        if PhoneSignIn.sessionOwner(for: provider) == .cursor { return PhoneSignIn.cursorLogin(now: now) }
        guard let request = PhoneSignIn.deviceCodeRequest(for: provider) else { throw Failure.notOffered }
        let (data, response) = try await answer(request)
        if response.statusCode == 404 { throw Failure.notOffered }
        guard (200..<300).contains(response.statusCode),
              let code = PhoneSignIn.deviceCode(from: data, provider: provider, now: now)
        else { throw Failure.refused }
        return code
    }

    /// Asks until the code is approved, turned down, or expired, then exchanges it for a session.
    /// Cancelling the task stops it.
    func waitForApproval(_ code: PhoneSignIn.DeviceCode, clock: @Sendable () -> Date = { .now }) async throws -> PhoneSession {
        var interval = max(code.interval, 2)
        while true {
            try await sleep(interval)
            try Task.checkCancellation()
            guard clock() < code.expiresAt else { throw Failure.expired }
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await answer(PhoneSignIn.pollRequest(code))
            } catch Failure.unreachable {
                // A dropped connection while waiting (the person is in Safari): ask again.
                continue
            }
            switch PhoneSignIn.pollAnswer(provider: code.provider, status: response.statusCode, data: data) {
            case .pending:
                continue
            case .slowDown:
                interval += 5
            case .authorized(let authorization, let verifier):
                // The approval is spent once polled: a dropped connection right after it (coming
                // back from Safari) is tried again rather than asking for a new code.
                let exchange = PhoneSignIn.codexExchangeRequest(code: authorization, verifier: verifier)
                for attempt in 1...Self.exchangeAttempts {
                    do {
                        return try await self.exchange(exchange, provider: code.provider, now: clock())
                    } catch Failure.unreachable where attempt < Self.exchangeAttempts {
                        try await sleep(2)
                    }
                }
                throw Failure.unreachable
            case .granted(let tokens):
                return try session(from: tokens, provider: code.provider, now: clock())
            case .denied:
                throw Failure.denied
            case .expired:
                throw Failure.expired
            case .failed:
                throw Failure.refused
            }
        }
    }

    static let exchangeAttempts = 3

    // MARK: Claude

    /// The session for what was pasted after Claude's sign-in.
    func finishClaude(pasted: String, pkce: PhoneSignIn.PKCE, now: Date = .now) async throws -> PhoneSession {
        switch PhoneSignIn.claudeCode(fromPasted: pasted, state: pkce.state) {
        case .empty: throw Failure.emptyCode
        case .otherSignIn: throw Failure.otherSignIn
        case .code(let code):
            return try await exchange(PhoneSignIn.claudeExchangeRequest(code: code, pkce: pkce), provider: .claude, now: now)
        }
    }

    // MARK: Renewal

    /// `PhoneSessionRefresher`'s token request: each of the provider's token hosts in turn, until
    /// one grants or refuses the refresh token.
    func renew(_ provider: Provider, _ session: PhoneSession, now: Date = .now) async -> PhoneSessionRefresher.Grant {
        for request in PhoneSignIn.refreshRequests(for: session, provider: provider) {
            guard let answered = try? await answer(request) else { continue }
            let (data, response) = answered
            switch PhoneSignIn.refreshAnswer(provider: provider, status: response.statusCode, data: data, previous: session, now: now) {
            case .unavailable: continue
            case let grant: return grant
            }
        }
        return .unavailable
    }

    // MARK: Private

    private func exchange(_ request: URLRequest, provider: Provider, now: Date) async throws -> PhoneSession {
        let (data, response) = try await answer(request)
        guard (200..<300).contains(response.statusCode) else { throw Failure.refused }
        return try session(from: data, provider: provider, now: now)
    }

    private func session(from data: Data, provider: Provider, now: Date) throws -> PhoneSession {
        guard let object = try? JSONFlex.object(from: data),
              (JSONFlex.string(object["access_token"]) ?? JSONFlex.string(object["accessToken"]))?.isEmpty == false
        else { throw Failure.refused }
        guard let session = PhoneSignIn.session(fromGrant: data, provider: provider, now: now) else { throw Failure.noRenewal }
        return session
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
    }
}
