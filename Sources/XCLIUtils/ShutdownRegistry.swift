import ConcurrencyExtras
import Dependencies

/// Anything registered here will be cleaned up when the process exits
public final class ShutdownRegistry: DependencyKey, Sendable {
    public static var liveValue: ShutdownRegistry { ShutdownRegistry() }
    public static var testValue: ShutdownRegistry { ShutdownRegistry() }

    private struct State {
        var operations: [@Sendable () async -> Void] = []
        var shutdownTask: Task<Void, Never>?
    }

    private let state = LockIsolated(State())

    public init() {}

    /// Register cleanup before shutdown begins.
    public func register(_ operation: @escaping @Sendable () async -> Void) {
        state.withValue { $0.operations.append(operation) }
    }

    /// Runs cleanup in reverse registration order, once, even for concurrent callers.
    public func shutdown() async {
        let task = state.withValue { state in
            if let task = state.shutdownTask { return task }
            let pending = state.operations.reversed()
            state.operations.removeAll()
            let task = Task {
                for operation in pending { await operation() }
            }
            state.shutdownTask = task
            return task
        }
        await task.value
    }
}

extension DependencyValues {
    public var shutdownRegistry: ShutdownRegistry {
        get { self[ShutdownRegistry.self] }
        set { self[ShutdownRegistry.self] = newValue }
    }
}
