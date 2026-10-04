import Foundation

extension RelayProvider {
    /// A widget's failed check keeps the last measurement, but cannot keep calling it live.
    /// Successful-check timestamps stay intact, so a fresh cache cannot make old data newer.
    func retainingAfterFailure(_ error: ProviderError, at now: Date) -> RelayProvider {
        guard (checkedAt ?? fetchedAt).map({ $0 <= now }) != false else { return self }
        var result = self
        switch error {
        case .signedOut(let message):
            result.state = "signedOut"
            result.message = message
            result.windows = []
        case .notEntitled(let message):
            result.state = "notEntitled"
            result.message = message
            result.windows = []
        case .expired(let message):
            result.state = "expired"
            result.message = message
            if (checkedAt ?? fetchedAt).map({ now.timeIntervalSince($0) > 86_400 }) != false {
                result.windows = []
            }
        case .rateLimited:
            result.state = "rateLimited"
            result.message = "Too many requests. Waiting before checking again."
        case .unreachable, .parse:
            result.state = "unreachable"
            result.message = "Couldn't check usage. Showing the last successful reading."
        }
        return result
    }
}
