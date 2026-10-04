import Foundation
import Synchronization

enum TokenroomHTTP {
    static let timeout: TimeInterval = 12
    static let fetchBudget: TimeInterval = 20
    /// Wait used when a 429 carries no usable Retry-After.
    static let defaultRetryAfter: TimeInterval = 15 * 60

    /// The session requests go through. Tests swap in one with a stub protocol.
    static var session: URLSession {
        sessionOverride.withLock { $0 } ?? defaultSession
    }

    private static let sessionOverride = Mutex<URLSession?>(nil)

    static func overrideSession(_ session: URLSession?) {
        sessionOverride.withLock { $0 = session }
    }

    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 5
        configuration.httpAdditionalHeaders = ["User-Agent": TokenroomIdentity.userAgent]
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }()

    private static let redirectDelegate = TokenroomRedirectDelegate()

    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        // Secrets may be in a custom header or the body, not only Authorization. Never start
        // a provider or token request over cleartext, or accept credentials embedded in a URL.
        guard TokenroomRedirectPolicy.isSecureEndpoint(request.url) else { throw ProviderError.unreachable }
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            // A task delegate also protects calls through a test/injected session. The default
            // session's delegate applies the same rules to streamed, unauthenticated news feeds.
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.unreachable
            }
            return (data, http)
        } catch is URLError {
            throw ProviderError.unreachable
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreachable
        }
    }

    static func mapStatus(_ status: Int, retryAfter: String? = nil, provider: Provider, now: Date = .now) -> ProviderError? {
        switch status {
        case 200..<300:
            nil
        case 401, 403:
            .expired(provider.expiredHint)
        case 429:
            .rateLimited(until: retryDate(retryAfter, now: now))
        default:
            .unreachable
        }
    }

    /// Retry-After as delta-seconds or an HTTP date.
    static func retryDate(_ value: String?, now: Date = .now) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    /// A JSON request. `token` is sent as `Authorization: Bearer`; pass nil for APIs that take
    /// the key in another header (Anthropic's `x-api-key`) or in the body.
    static func request(_ url: URL, method: String = "GET", token: String?, headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func get(_ url: URL, token: String?, headers: [String: String] = [:], provider: Provider) async throws -> Data {
        try await send(request(url, token: token, headers: headers), provider: provider)
    }

    static func post(_ url: URL, token: String?, headers: [String: String] = [:], body: Data = Data("{}".utf8), provider: Provider) async throws -> Data {
        try await send(request(url, method: "POST", token: token, headers: headers, body: body), provider: provider)
    }

    /// Throws the mapped error for a non-2xx status.
    static func check(_ response: HTTPURLResponse, provider: Provider) throws {
        if let error = mapStatus(
            response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
            provider: provider
        ) {
            throw error
        }
    }

    private static func send(_ request: URLRequest, provider: Provider) async throws -> Data {
        let (data, response) = try await data(for: request)
        try check(response, provider: provider)
        return data
    }
}

/// A redirect can't choose where a credential is sent. Check the original request too: URLSession
/// can remove Authorization or turn a POST into GET before handing the delegate the next request.
enum TokenroomRedirectPolicy {
    static func isSecureEndpoint(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil
        else { return false }
        return true
    }

    static func allows(original: URLRequest?, current: URLRequest?, redirected: URLRequest) -> Bool {
        guard let original, isSecureEndpoint(original.url), isSecureEndpoint(redirected.url) else { return false }
        if sameOrigin(original.url, redirected.url) { return true }
        // Public feeds may move to another HTTPS host. Provider calls carrying a bearer, an
        // API key, cookies, or any POST/body stay on their original origin, including 307/308.
        return [original, current, redirected].compactMap { $0 }.allSatisfy { !mayCarryCredentials($0) }
    }

    private static func sameOrigin(_ first: URL?, _ second: URL?) -> Bool {
        guard let first, let second else { return false }
        return first.host?.lowercased() == second.host?.lowercased()
            && (first.port ?? 443) == (second.port ?? 443)
    }

    private static func mayCarryCredentials(_ request: URLRequest) -> Bool {
        let method = (request.httpMethod ?? "GET").uppercased()
        if method != "GET" && method != "HEAD" { return true }
        if request.httpBody != nil || request.httpBodyStream != nil { return true }
        let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "x-api-key", "api-key", "cookie"]
        return (request.allHTTPHeaderFields ?? [:]).contains { secretHeaders.contains($0.key.lowercased()) && !$0.value.isEmpty }
    }
}

private final class TokenroomRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(TokenroomRedirectPolicy.allows(original: task.originalRequest, current: task.currentRequest, redirected: request) ? request : nil)
    }
}

protocol ProviderClient: Sendable {
    var provider: Provider { get }
    /// How long a check may take before it counts as unreachable.
    var fetchBudget: TimeInterval { get }
    func fetch() async -> Result<QuotaSnapshot, ProviderError>
    /// A cheap local reading while the provider's own endpoint is resting between checks, or nil.
    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot?
    /// A sign-in finished or a key changed: forget anything kept from the old credentials.
    func credentialsChanged()
}

extension ProviderClient {
    var fetchBudget: TimeInterval { TokenroomHTTP.fetchBudget }

    /// This check, given up on after its `fetchBudget` (or `budget`, when less time is left), so
    /// one slow provider never holds up the rest. The Mac's refresh, the iPhone's key providers,
    /// and widgets all read through it. A check cut short, by the time or by the caller, is
    /// unreachable.
    func fetchWithinBudget(_ budget: TimeInterval? = nil) async -> Result<QuotaSnapshot, ProviderError> {
        let limit = min(budget ?? fetchBudget, fetchBudget)
        return await TimeLimit.run(limit, otherwise: .failure(.unreachable)) { await self.fetch() }
    }

    func fetchBetweenCalls(previous: QuotaSnapshot?) async -> QuotaSnapshot? {
        nil
    }

    func credentialsChanged() {}
}

/// Work that has to give way at a set time: a provider check, or a widget's few seconds.
enum TimeLimit {
    /// `work`'s answer, or `fallback` once `seconds` pass or the caller is cancelled. `work` is
    /// then cancelled but not waited for: a task group would wait, and some calls (iCloud's
    /// account status) carry on regardless.
    ///
    /// The deadline is queued on the main thread. A stuck legacy keychain call blocks the
    /// dispatch workers Swift's `Task.sleep` uses, so a timer on that pool would never fire
    /// and the menu would stay on "Updating…". The main thread keeps running.
    static func run<T: Sendable>(_ seconds: TimeInterval, otherwise fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        let answer = FirstAnswer<T>()
        let worker = Task.detached(priority: .userInitiated) { answer.give(await work()) }
        // A late fire is ignored. Cancelling the block would capture a non-Sendable work item.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) {
            answer.give(fallback)
        }
        let result = await withTaskCancellationHandler {
            await answer.wait()
        } onCancel: {
            answer.give(fallback)
        }
        worker.cancel()
        return result
    }
}

/// The first answer given, for the one caller waiting on it; later ones are dropped.
private final class FirstAnswer<T: Sendable>: Sendable {
    private struct State {
        var answer: T?
        var waiting: CheckedContinuation<T, Never>?
        var isGiven = false
    }

    private let state = Mutex(State())

    func give(_ answer: T) {
        let waiting: CheckedContinuation<T, Never>? = state.withLock { state in
            guard !state.isGiven else { return nil }
            state.isGiven = true
            guard let waiting = state.waiting else {
                // Given before anyone waits (a caller cancelled on arrival): kept for `wait`.
                state.answer = answer
                return nil
            }
            state.waiting = nil
            return waiting
        }
        waiting?.resume(returning: answer)
    }

    func wait() async -> T {
        await withCheckedContinuation { continuation in
            let ready: T? = state.withLock { state in
                if let answer = state.answer { return answer }
                state.waiting = continuation
                return nil
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
}
