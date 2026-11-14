import Foundation

/// Runs `operation` while holding an exclusive advisory lock on the file at `url`.
///
/// The lock excludes other processes as well as other callers in this process.
/// It waits by polling, so no thread is blocked and cancellation is honored, and
/// the kernel releases it if the process dies.
package func withFileLock<T: Sendable>(
    at url: URL,
    _ operation: @Sendable () async throws -> T
) async throws -> T {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = try FileDescriptor.open(
        FilePath(url.path),
        .writeOnly,
        options: [.create],
        permissions: [.ownerReadWrite],
    )
    defer { try? fd.close() }
    while try !fd.tryLock(mode: .exclusive) {
        try await Task.sleep(for: .milliseconds(20))
    }
    return try await operation()
}
