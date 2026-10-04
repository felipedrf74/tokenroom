import XCTest
@testable import Tokenroom

/// Placeholder credentials and .invalid URLs only. No provider or Keychain is contacted.
final class HTTPPrivacyTests: XCTestCase {
    override func tearDown() {
        TokenroomHTTP.overrideSession(nil)
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func request(_ url: String = "https://usage.example.invalid/usage", method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    func testSameOriginHTTPSRedirectKeepsAProviderRequestWorking() {
        let original = request(method: "POST", headers: ["Authorization": "Bearer placeholder"], body: Data("grant=placeholder".utf8))
        let destination = request("https://USAGE.example.invalid:443/v2/usage", method: "POST", headers: ["Authorization": "Bearer placeholder"], body: original.httpBody)
        XCTAssertTrue(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: destination))
    }

    func testAnAuthenticatedRedirectIsRefusedEvenAfterAuthorizationWasStripped() {
        let original = request(headers: ["Authorization": "Bearer placeholder"])
        let stripped = request("https://elsewhere.example.invalid/usage")
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: stripped))
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: request("https://usage.example.invalid:8443/usage")), "A changed port is another origin")
    }

    func testCustomAPIKeyAndCookieHeadersStayOnTheirOrigin() {
        for header in ["x-api-key", "API-Key", "Cookie", "Proxy-Authorization"] {
            let original = request(headers: [header: "placeholder"])
            XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: request("https://elsewhere.example.invalid/usage")), header)
        }
    }

    func testPOSTCredentialsStayOnTheirOriginForBothReplayedAndChangedMethods() {
        // Devin puts a key in JSON; OAuth puts a refresh token in JSON or a form body.
        let original = request(method: "POST", body: Data("refresh_token=placeholder".utf8))
        let replayed = request("https://elsewhere.example.invalid/token", method: "POST", body: original.httpBody)
        let changedToGET = request("https://elsewhere.example.invalid/token")
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: replayed), "307/308 must not replay a credential body")
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: changedToGET), "301/302 must not change credential origin either")
    }

    func testPublicNewsMayMoveToAnotherHTTPSHostButNotCleartext() {
        let original = request(headers: ["If-None-Match": "public-etag"])
        XCTAssertTrue(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: request("https://feed.example.invalid/news.xml")))
        for destination in ["http://usage.example.invalid/news", "http://feed.example.invalid/news", "https://user:password@usage.example.invalid/news"] {
            XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: request(destination)), destination)
        }
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: nil, current: original, redirected: original))
    }

    func testCredentialAddedDuringARedirectChainCannotLeaveTheOrigin() {
        let original = request()
        let current = request(headers: ["x-api-key": "placeholder"])
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: current, redirected: request("https://elsewhere.example.invalid/usage")))
        XCTAssertFalse(TokenroomRedirectPolicy.allows(original: original, current: original, redirected: request("https://elsewhere.example.invalid/usage", headers: ["x-api-key": "placeholder"])))
    }

    func testTheDefaultSessionDelegateActuallyRefusesUnsafeRedirects() throws {
        let session = TokenroomHTTP.defaultSession
        let delegate = try XCTUnwrap(session.delegate as? any URLSessionTaskDelegate)
        let original = request(method: "POST", body: Data("refresh_token=placeholder".utf8))
        let task = session.dataTask(with: original) // Kept suspended: no networking.
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil))
        let destination = request("https://elsewhere.example.invalid/token", method: "POST", body: original.httpBody)
        let answer = LockedBox<URLRequest?>(original)
        let callbacks = Counter()
        delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: destination) { redirected in
            answer.value = redirected
            callbacks.increment()
        }
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertNil(answer.value, "Returning nil stops the redirect before credentials leave")
    }

    func testCleartextAndURLCredentialsAreRejectedBeforeDispatch() async {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data()) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        TokenroomHTTP.overrideSession(URLSession(configuration: configuration))
        for url in ["http://usage.example.invalid/usage", "https://user:password@usage.example.invalid/usage"] {
            do {
                _ = try await TokenroomHTTP.data(for: request(url, headers: ["x-api-key": "placeholder"]))
                XCTFail("Unsafe endpoint must not be dispatched")
            } catch {
                XCTAssertEqual(error as? ProviderError, .unreachable)
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
