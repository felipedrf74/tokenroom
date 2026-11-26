import Foundation

struct PhoneSignInClient: Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    var send: Send = { request in
        var request = request
        request.timeoutInterval = TokenroomHTTP.timeout
        guard TokenroomRedirectPolicy.isSecureEndpoint(request.url) else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
        let (data, response) = try await TokenroomHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
    var sleep: Sleep = { try await Task.sleep(for: .seconds($0)) }

    enum Failure: Error, Equatable, Sendable {
        case unreachable
        case notOffered
        case denied
        case blockedByPolicy
        case expired
        case refused
        case noRenewal

        func message(for provider: Provider) -> String {
            let vendor = PhoneSignIn.vendorName(for: provider)
            return switch self {
            case .unreachable: "Couldn't reach \(vendor). Check the connection, then try again."
            case .notOffered: "Couldn't start a code sign-in: \(vendor) isn't offering one right now."
            case .denied: "Couldn't sign in: the request was turned down on \(vendor)'s page."
            case .blockedByPolicy: "Couldn't sign in: your organization doesn't allow signing in to \(vendor) here."
            case .expired: PhoneSignIn.sessionOwner(for: provider) == .cursor
                ? "Couldn't sign in before the sign-in page expired. Start again."
                : "Couldn't sign in before the code expired. Start again."
            case .refused: "Couldn't finish signing in to \(PhoneSignIn.planName(for: provider)). Start again."
            case .noRenewal: "Couldn't keep this sign-in: \(vendor) didn't send a way to renew it."
            }
        }
    }

    func startDeviceCode(for provider: Provider, now: Date = .now) async throws -> PhoneSignIn.DeviceCode {
        if PhoneSignIn.sessionOwner(for: provider) == .cursor { return PhoneSignIn.cursorLogin(now: now) }
        guard let request = PhoneSignIn.deviceCodeRequest(for: provider) else { throw Failure.notOffered }
        let (data, response) = try await answer(request)
        if response.statusCode == 404 { throw Failure.notOffered }
        guard (200..<300).contains(response.statusCode),
              let code = PhoneSignIn.deviceCode(from: data, provider: provider, now: now)
        else { throw Failure.refused }
        return code
    }

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
                continue
            }
            switch PhoneSignIn.pollAnswer(provider: code.provider, status: response.statusCode, data: data) {
            case .pending:
                continue
            case .slowDown:
                interval = min(interval + 5, 30)
            case .authorized(let authorization, let verifier):
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
            case .blockedByPolicy:
                throw Failure.blockedByPolicy
            case .expired:
                throw Failure.expired
            case .failed:
                throw Failure.refused
            }
        }
    }

    static let exchangeAttempts = 3

    func renew(_ provider: Provider, _ session: PhoneSession, now: Date = .now) async -> PhoneSessionRefresher.Grant {
        for request in PhoneSignIn.refreshRequests(for: session, provider: provider) {
            let answered: (Data, HTTPURLResponse)
            do {
                answered = try await send(request)
            } catch {
                if Self.neverSent(error) { continue }
                return .unavailable
            }
            return PhoneSignIn.refreshAnswer(provider: provider, status: answered.1.statusCode, data: answered.0, previous: session, now: now)
        }
        return .notDispatched
    }

    static func neverSent(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive,
             .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

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
