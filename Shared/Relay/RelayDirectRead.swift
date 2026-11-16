import Foundation

enum RelayDirectRead {
    struct Incomplete: Error, Equatable {
        var name: String
    }

    static func records<Record: Sendable>(
        known: Set<String>,
        companions: @escaping @Sendable (String) -> [String],
        always: [String],
        discover: @escaping @Sendable () async throws -> Set<String>,
        fetch: @escaping @Sendable ([String]) async throws -> [String: Result<Record?, any Error>]
    ) async throws -> [Record] {
        let first = known.sorted()
        async let discovering = discover()
        async let fetching = fetch(first + first.flatMap(companions) + always)
        let discovered = try await discovering
        var answers = try await fetching
        let added = discovered.subtracting(known).sorted()
        if !added.isEmpty {
            try Task.checkCancellation()
            answers.merge(try await fetch(added + added.flatMap(companions))) { _, later in later }
        }
        var records: [Record] = []
        var taken: Set<String> = []
        for name in first + added + (first + added).flatMap(companions) + always where taken.insert(name).inserted {
            guard let answer = answers[name] else { throw Incomplete(name: name) }
            if let record = try answer.get() { records.append(record) }
        }
        return records
    }
}
