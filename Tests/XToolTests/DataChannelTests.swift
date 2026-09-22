@testable import XCLIUtils
import ConcurrencyExtras
import CustomDump
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct DataChannelTests {
    private enum TestError: Error { case producer, drain }

    @Test(arguments: [1, 3, 100])
    func byteLimitPreservesRemainder(limit: Int) async throws {
        let channel = DataChannel()
        channel.write(Data([0, 255]))
        channel.write(Data([128, 13, 10]))
        channel.finish(error: nil)
        let bytes = Data([0, 255, 128, 13, 10])

        let first = try await channel.read(upTo: .bytes(limit))
        expectNoDifference(first, Data(bytes.prefix(limit)))
        if limit < bytes.count {
            let remainder = try await channel.read()
            expectNoDifference(remainder, Data(bytes.dropFirst(limit)))
        }
        #expect(try await channel.read() == nil)
        #expect(try await channel.read() == nil)
    }

    @Test
    func zeroLimitDoesNotConsumeBufferedBytes() async throws {
        let channel = DataChannel()
        channel.write(Data("kept".utf8))
        channel.finish(error: nil)
        #expect(try await channel.read(upTo: .bytes(0)) == Data())
        let bytes = try await channel.read()
        expectNoDifference(bytes, Data("kept".utf8))
    }

    @Test(arguments: [false, true])
    func newlinePreservesRemainderAfterPartialRead(consumePrefix: Bool) async throws {
        let channel = DataChannel()
        channel.write(Data("abfirst\nsecond line with a long remainder".utf8))
        channel.finish(error: nil)
        if consumePrefix {
            let prefix = try await channel.read(upTo: .bytes(2))
            expectNoDifference(prefix, Data("ab".utf8))
        }
        let line = try await channel.read(upTo: .newline)
        expectNoDifference(line, Data((consumePrefix ? "first\n" : "abfirst\n").utf8))
        let remainder = try await channel.read()
        expectNoDifference(remainder, Data("second line with a long remainder".utf8))
    }

    @Test
    func newlineReturnsEmptyLineAndUnterminatedChunk() async throws {
        let channel = DataChannel()
        channel.write(Data("\npartial".utf8))
        channel.finish(error: nil)
        #expect(try await channel.read(upTo: .newline) == Data("\n".utf8))
        let remainder = try await channel.read(upTo: .newline)
        expectNoDifference(remainder, Data("partial".utf8))
        #expect(try await channel.read() == nil)
    }

    @Test
    func throwingLimitLeavesBufferAvailable() async throws {
        let channel = DataChannel()
        channel.write(Data("kept".utf8))
        channel.finish(error: nil)
        await #expect(throws: TestError.drain) {
            try await channel.read(drain: { _ in throw TestError.drain })
        }
        let bytes = try await channel.read()
        expectNoDifference(bytes, Data("kept".utf8))
    }

    @Test(arguments: [false, true])
    func finishDrainsBufferAndKeepsFirstTerminalResult(failed: Bool) async throws {
        let channel = DataChannel()
        channel.write(Data("before".utf8))
        channel.finish(error: failed ? TestError.producer : nil)
        channel.write(Data("ignored".utf8))
        channel.finish(error: failed ? nil : TestError.producer)
        let bytes = try await channel.read()
        expectNoDifference(bytes, Data("before".utf8))
        for _ in 0..<2 {
            if failed {
                await #expect(throws: TestError.producer) { try await channel.read() }
            } else {
                #expect(try await channel.read() == nil)
            }
        }
    }

    @Test
    func requestsDataOnlyWhenBufferIsEmpty() async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let requests = LockIsolated(0)
        channel.onRequest { [channel] in
            requests.withValue { $0 += 1 }
            channel.write(Data("new".utf8))
        }
        channel.write(Data("buffered".utf8))
        try await withInputTestTimeout {
            let buffered = try await channel.read()
            expectNoDifference(buffered, Data("buffered".utf8))
            #expect(requests.value == 0)
            for expectedRequests in 1...2 {
                let bytes = try await channel.read()
                expectNoDifference(bytes, Data("new".utf8))
                #expect(requests.value == expectedRequests)
            }
        } cleanup: {
            channel.finish(error: nil)
        }
        channel.finish(error: nil)
        #expect(try await channel.read() == nil)
        #expect(requests.value == 2)
    }

    @Test(arguments: [false, true])
    @available(anyAppleOS 26.0, *)
    func finishWakesPendingRead(failed: Bool) async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let reading = Task.immediate { try await channel.read() }
        defer { reading.cancel() }
        try await withInputTestTimeout { () async throws in
            channel.finish(error: failed ? TestError.producer : nil)
            if failed {
                await #expect(throws: TestError.producer) { try await reading.value }
            } else {
                #expect(try await reading.value == nil)
            }
        } cleanup: {
            channel.finish(error: nil)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func concurrentReadThrowsWithoutDisruptingPendingRead() async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let reading = Task.immediate { try await channel.read() }
        defer { reading.cancel() }

        try await withInputTestTimeout {
            await #expect(throws: DataChannel.Errors.concurrentRead) {
                try await channel.read()
            }

            channel.write(Data("first".utf8))
            let first = try await reading.value
            expectNoDifference(first, Data("first".utf8))

            channel.write(Data("next".utf8))
            let next = try await channel.read()
            expectNoDifference(next, Data("next".utf8))
        } cleanup: {
            channel.finish(error: nil)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func cancelledPendingReadAllowsAnotherRead() async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let reading = Task.immediate { try await channel.read() }
        defer { reading.cancel() }
        try await withInputTestTimeout {
            reading.cancel()
            await #expect(throws: CancellationError.self) { try await reading.value }
            channel.write(Data("kept".utf8))
            let bytes = try await channel.read()
            expectNoDifference(bytes, Data("kept".utf8))
        } cleanup: {
            channel.finish(error: nil)
        }
    }

    @Test
    func alreadyCancelledReadDoesNotConsumeBufferOrRequestData() async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let requested = LockIsolated(false)
        channel.onRequest { requested.setValue(true) }
        channel.write(Data("kept".utf8))
        let reading = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await channel.read()
        }
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(!requested.value)
        let bytes = try await channel.read()
        expectNoDifference(bytes, Data("kept".utf8))
    }
}
