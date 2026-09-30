import Foundation
import Security

/// Runs blocking work (processes, SQLite, file reads, the Keychain CLI) off Swift's
/// cooperative thread pool, which must never wait on I/O.
enum BlockingIO {
    private static let queue = DispatchQueue(
        label: "app.tokenroom.blocking-io",
        qos: .utility,
        attributes: .concurrent
    )

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// One keychain operation at a time.
///
/// The legacy macOS keychain takes a process-wide lock and then waits on securityd.
/// Overlapping `SecItem` calls deadlock that lock. The threads they occupy are the
/// same pool Swift's timers use, so a check that should give up after a few seconds
/// never does and the menu stays on "Updating…". Re-entrant, so a read that already
/// holds the gate can update the same item.
enum KeychainGate {
    private static let key = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "app.tokenroom.keychain")
        queue.setSpecific(key: key, value: 1)
        return queue
    }()

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
        // The main thread runs the call itself. Waiting on this queue from there
        // deadlocks when SecItem needs the main thread. Refresh calls come from
        // BlockingIO, so they still run here one at a time.
        if DispatchQueue.getSpecific(key: key) != nil || Thread.isMainThread {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    static func copyMatching(_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?) {
        sync {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        }
    }

    static func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        sync { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    }

    static func add(_ attributes: [String: Any]) -> OSStatus {
        sync { SecItemAdd(attributes as CFDictionary, nil) }
    }

    static func delete(_ query: [String: Any]) -> OSStatus {
        sync { SecItemDelete(query as CFDictionary) }
    }
}
