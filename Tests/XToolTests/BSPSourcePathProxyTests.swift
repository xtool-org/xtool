import Testing
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Subprocess
@testable import XToolSupport

/// Lock-based completion flag; `Task.isCompleted` is not in this runtime.
private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

/// Regression: a normal shutdown (client closes stdin, child exits) must end
/// `proxy.run`. The proxy used to keep its copy of the child's stdout write
/// end open until `run` returned, so the stdout pump never saw EOF, `run`
/// never returned, and the proxy hung on every client disconnect.
@Test func proxyExitsWhenClientClosesStdin() async throws {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
        throw Console.Error("test: pipe() failed")
    }
    let (readEnd, writeEnd) = (fds[0], fds[1])
    defer { close(readEnd) }

    // One framed message, then EOF.
    let body = Data("{}".utf8)
    let bytes = [UInt8](Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes {
            write(writeEnd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        guard n > 0 else { throw Console.Error("test: write() failed (errno \(errno))") }
        offset += n
    }
    close(writeEnd)

    let proxy = BSPSourcePathProxy()
    let finished = FinishedFlag()
    let task = Task.detached {
        defer { finished.finish() }
        // /bin/cat echoes the frame to the proxy's stdout and exits once its
        // stdin (fed by the proxy) closes; `run` must return afterwards.
        try await proxy.run(
            Configuration(executable: .path("/bin/cat"), arguments: []),
            input: readEnd
        )
    }
    let deadline = ContinuousClock.now + .seconds(10)
    while !finished.isFinished, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(finished.isFinished, "proxy.run did not exit within 10s of client stdin EOF")
    if finished.isFinished {
        do {
            _ = try await task.value
        } catch {
            Issue.record("proxy.run failed: \(error)")
        }
    }
}
