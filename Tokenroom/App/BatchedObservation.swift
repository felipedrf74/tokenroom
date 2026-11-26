import Foundation
import Observation

@MainActor
final class BatchedObservation<Value> {
    static var defaultSettle: @Sendable () async -> Void {
        { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private let settle: @Sendable () async -> Void
    private let read: () -> Value
    private let apply: (Value) -> Void
    private var pending: Task<Void, Never>?

    init(
        settle: @escaping @Sendable () async -> Void = BatchedObservation.defaultSettle,
        read: @escaping () -> Value,
        apply: @escaping (Value) -> Void
    ) {
        self.settle = settle
        self.read = read
        self.apply = apply
    }

    func start() {
        readAndApply()
    }

    private func readAndApply() {
        let value = withObservationTracking(read) { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        apply(value)
    }

    private func changed() {
        guard pending == nil else { return }
        pending = Task { [weak self, settle] in
            await settle()
            guard let self else { return }
            self.pending = nil
            self.readAndApply()
        }
    }
}
