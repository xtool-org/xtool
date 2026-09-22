import Dependencies

/// Anything registered here will be cleaned up when the process exits
public actor ShutdownRegistry: DependencyKey {
    public static var liveValue: ShutdownRegistry { ShutdownRegistry() }
    public static var testValue: ShutdownRegistry { ShutdownRegistry() }

    private var operations: [@Sendable () async -> Void] = []
    private var shutdownTask: Task<Void, Never>?

    public init() {}

    public func register(_ operation: @escaping @Sendable () async -> Void) async {
        if shutdownTask != nil {
            await operation()
        } else {
            operations.append(operation)
        }
    }

    /// Runs cleanup in reverse registration order, once, even for concurrent callers.
    public func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let pending = operations.reversed()
        operations.removeAll()
        let task = Task {
            for operation in pending { await operation() }
        }
        shutdownTask = task
        await task.value
    }
}

extension DependencyValues {
    public var shutdownRegistry: ShutdownRegistry {
        get { self[ShutdownRegistry.self] }
        set { self[ShutdownRegistry.self] = newValue }
    }
}
