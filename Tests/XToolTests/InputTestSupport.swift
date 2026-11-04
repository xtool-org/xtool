import Foundation
import Testing

/// Releases suspended reads on timeout so a regression cannot hang the test process.
func withInputTestTimeout<T>(
    _ timeout: Duration = .seconds(5),
    operation: () async throws -> T,
    cleanup: @escaping @Sendable () async -> Void,
) async throws -> T {
    let watchdog = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        Issue.record("Input operation exceeded timeout of \(timeout)")
        await cleanup()
    }
    defer {
        watchdog.cancel()
        await watchdog.value
    }
    return try await operation()
}
