import Foundation

public enum Example {}
extension Example {
    public static func pass() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            print("xtool test succeeded")
            exit(0)
        }
    }
}

nonisolated(nonsending) public func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: nonisolated(nonsending) @Sendable @escaping () async throws -> T,
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

public struct TimeoutError: Error {}

public struct StringError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
}
