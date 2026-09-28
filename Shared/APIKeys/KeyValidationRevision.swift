import Foundation

/// A result authorizes only the exact input revision that produced it. Never persisted.
struct KeyValidationRevision {
    struct Attempt: Equatable, Sendable {
        let id = UUID()
        let credential: APIKeyCredential
    }

    private(set) var attempt: Attempt?

    mutating func begin(_ credential: APIKeyCredential) -> Attempt {
        let next = Attempt(credential: credential)
        attempt = next
        return next
    }

    mutating func invalidate() { attempt = nil }

    func accepts(_ result: Attempt, current: APIKeyCredential) -> Bool {
        attempt == result && result.credential == current
    }
}
