import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
import XUtils

struct CommandOutputTests {
    @Test
    func dependencyOutputSupportsStringAndVariadicPrinting() {
        struct Output: Equatable, Sendable {
            var message: String
            var stream: CommandOutput.Stream
            var flush: Bool
        }
        let received = LockIsolated<[Output]>([])
        withDependencies {
            $0.out.write = { data, stream, flush in
                received.withValue {
                    $0.append(Output(message: String(decoding: data, as: UTF8.self), stream: stream, flush: flush))
                }
            }
        } operation: {
            d.out.print()
            d.out.print("message")
            d.out.print("progress", 42, separator: ": ", terminator: "", stream: .stderr, flush: true)
        }
        #expect(received.value == [
            Output(message: "\n", stream: .stdout, flush: false),
            Output(message: "message\n", stream: .stdout, flush: false),
            Output(message: "progress: 42", stream: .stderr, flush: true),
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func fullNonblockingPipePreservesAllBytes() async throws {
        let pipe = Pipe()
        let writer = FileDescriptor(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        let reader = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let flags = fcntl(writer.rawValue, F_GETFL)
        try #require(flags != -1)
        try #require(fcntl(writer.rawValue, F_SETFL, flags | O_NONBLOCK) == 0)

        // Fill the pipe before invoking the output writer, forcing EAGAIN.
        let padding = Data(repeating: 255, count: 4096)
        var prefix = Data()
        while true {
            do {
                let count = try padding.withUnsafeBytes { try writer.write($0) }
                prefix.append(padding.prefix(count))
            } catch let error as Errno where error.rawValue == EAGAIN || error.rawValue == EWOULDBLOCK {
                break
            }
        }
        let message = Data([0, 255, 128]) + Data(String(repeating: "output é 🌍\n", count: 100_000).utf8)
        let writing = Task.detached {
            defer { try? pipe.fileHandleForWriting.close() }
            try message.withUnsafeBytes { try writer.writeAllWaiting($0) }
        }
        // Let the writer encounter the full pipe before draining it.
        try await Task.sleep(for: .milliseconds(20))
        let received = try await Task.detached {
            var received = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = try buffer.withUnsafeMutableBytes { try reader.read(into: $0) }
                if count == 0 { return received }
                received.append(contentsOf: buffer.prefix(count))
            }
        }.value
        try await writing.value
        #expect(received == prefix + message)
        #expect(fcntl(reader.rawValue, F_GETFL) != -1)
    }

    @Test
    func invalidDescriptorThrowsInsteadOfRaisingAnException() {
        let descriptor = FileDescriptor(rawValue: -1)
        #expect(throws: Errno.badFileDescriptor) {
            try Data("output".utf8).withUnsafeBytes { try descriptor.writeAllWaiting($0) }
        }
        // Empty output does not attempt a system call.
        #expect(throws: Never.self) {
            try Data().withUnsafeBytes { try descriptor.writeAllWaiting($0) }
        }
    }
}
