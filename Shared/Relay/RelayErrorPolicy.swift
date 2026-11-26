import CloudKit
import Foundation

enum RelayErrorPolicy {
    enum Outcome: Equatable {
        case noAccount
        case paused(String)
        case retry(after: TimeInterval, message: String)
        case unavailable
        case cancelled
        case failed(String)

        var stopsBatch: Bool {
            switch self {
            case .failed: false
            case .noAccount, .paused, .retry, .unavailable, .cancelled: true
            }
        }
    }

    static func unusableAccount(_ status: CKAccountStatus) -> String? {
        switch status {
        case .available, .noAccount:
            nil
        case .temporarilyUnavailable:
            "Couldn't use iCloud until your Apple Account is verified again. Open Settings and tap your name."
        case .restricted:
            "Couldn't use iCloud: Screen Time or device management restricts it on this device."
        case .couldNotDetermine:
            "Couldn't reach iCloud."
        @unknown default:
            "Couldn't reach iCloud."
        }
    }

    static func isConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? CKError {
            return error.retryAfterSeconds == nil && [.networkUnavailable, .networkFailure].contains(error.code)
        }
        return (error as? URLError).map(TokenroomHTTP.meansOffline) ?? false
    }

    static func outcome(for error: Error, defaultRetry: TimeInterval, networkRetry: TimeInterval? = nil) -> Outcome {
        if error is CancellationError || (error as? CKError)?.code == .operationCancelled {
            return .cancelled
        }
        if let networkRetry, isConnectionFailure(error) {
            return .retry(after: networkRetry, message: "Couldn't reach iCloud. Trying again soon.")
        }
        guard let error = error as? CKError else {
            return .failed("Couldn't reach iCloud.")
        }
        switch error.code {
        case .notAuthenticated:
            return .noAccount
        case .userDeletedZone:
            #if os(macOS)
            return .paused("Tokenroom's iCloud data was deleted. To start again, turn Send readings to iCloud off and on in Settings › iPhone & Watch.")
            #else
            return .paused("Tokenroom's iCloud data was deleted. To start again, turn Send readings to iCloud off and on in Tokenroom on your Mac, or choose Delete Tokenroom Data from iCloud in Settings here.")
            #endif
        case .quotaExceeded:
            return .paused("Couldn't save: iCloud storage is full.")
        case .requestRateLimited, .zoneBusy, .serviceUnavailable, .networkUnavailable, .networkFailure:
            return .retry(after: error.retryAfterSeconds ?? defaultRetry, message: "Couldn't reach iCloud. Trying again soon.")
        case .badContainer:
            return .retry(after: max(error.retryAfterSeconds ?? 0, defaultRetry), message: "Couldn't reach Tokenroom's iCloud container yet. Trying again soon.")
        case .missingEntitlement, .permissionFailure:
            return .unavailable
        default:
            return .failed("Couldn't reach iCloud.")
        }
    }
}
