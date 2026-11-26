import Foundation
import Security

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

enum KeychainGate {
    private static let key = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "app.tokenroom.keychain")
        queue.setSpecific(key: key, value: 1)
        return queue
    }()

    static func sync<T>(_ work: () throws -> T) rethrows -> T {
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
