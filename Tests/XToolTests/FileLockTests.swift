import Foundation
import ConcurrencyExtras
import Testing
import XUtils

struct FileLockTests {
    @Test func excludesConcurrentHolders() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtool-lock-test-\(UUID().uuidString)")
            .appendingPathComponent("state.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let holders = LockIsolated(0)
        let overlapped = LockIsolated(false)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    // Each call opens its own descriptor, as separate processes would.
                    try await withFileLock(at: url) {
                        holders.withValue {
                            $0 += 1
                            if $0 > 1 { overlapped.setValue(true) }
                        }
                        try await Task.sleep(for: .milliseconds(30))
                        holders.withValue { $0 -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(!overlapped.value)
    }
}
