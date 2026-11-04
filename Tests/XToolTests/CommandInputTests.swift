@testable import XCLIUtils
import XUtils
import ConcurrencyExtras
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CommandInputTests {
    @Test(arguments: [Data("bar".utf8), Data([0, 255, 128, 13, 10])])
    func rawReadCoalescesBytesAfterLine(remainder: Data) async throws {
        let channel = DataChannel()
        let input = CommandInput(channel: channel)
        channel.write(Data("foo\n".utf8) + remainder)
        channel.write(Data("next\nlast".utf8))
        channel.finish(error: nil)

        #expect(try await input.readLine() == "foo")
        #expect(try await input.read() == remainder + Data("next\nlast".utf8))
        #expect(try await input.read() == nil)
        #expect(try await input.readLine() == nil)
    }

    @Test
    func lineReadsAfterRawReadPreserveFollowingLines() async throws {
        let channel = DataChannel()
        let input = CommandInput(channel: channel)
        channel.write(Data("raw".utf8))
        #expect(try await input.read() == Data("raw".utf8))
        channel.write(Data("foo\r\n\nbar\nlast".utf8))
        channel.finish(error: nil)

        #expect(try await input.readLine() == "foo")
        #expect(try await input.readLine() == "")
        #expect(try await input.readLine() == "bar")
        #expect(try await input.read() == Data("last".utf8))
        #expect(try await input.readLine() == nil)
    }

    @Test
    func lineReadAccumulatesSplitUTF8AndCRLF() async throws {
        let channel = DataChannel()
        let input = CommandInput(channel: channel)
        // Split both a Unicode scalar and the CRLF terminator across reads.
        let chunks = LockIsolated([
            Data([0xF0, 0x9F]),
            Data([0x98, 0x80, 13]),
            Data("\n\nlast".utf8),
        ])
        channel.onRequest { [channel] in
            let chunk = chunks.withValue { $0.isEmpty ? nil : $0.removeFirst() }
            if let chunk {
                channel.write(chunk)
            } else {
                channel.finish(error: nil)
            }
        }
        try await withInputTestTimeout { () async throws in
            #expect(try await input.readLine() == "😀")
            #expect(try await input.readLine() == "")
            #expect(try await input.readLine() == "last")
            #expect(try await input.readLine() == nil)
        } cleanup: {
            channel.finish(error: nil)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func cancellingLineDiscardsConsumedPrefixAndPreservesFutureInput() async throws {
        let channel = DataChannel()
        defer { channel.finish(error: nil) }
        let input = CommandInput(channel: channel)
        channel.write(Data("discarded prefix".utf8))
        let reading = Task.immediate { try await input.readLine() }
        defer { reading.cancel() }

        try await withInputTestTimeout { () async throws in
            reading.cancel()
            await #expect(throws: CancellationError.self) { try await reading.value }
            channel.write(Data("next\nkept".utf8))
            #expect(try await input.readLine() == "next")
            #expect(try await input.read() == Data("kept".utf8))
        } cleanup: {
            channel.finish(error: nil)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func finishingChannelWakesLineReadAndReturnsItsUnterminatedBytes() async throws {
        let channel = DataChannel()
        let input = CommandInput(channel: channel)
        channel.write(Data("partial".utf8))
        let reading = Task.immediate { try await input.readLine() }
        defer { reading.cancel(); channel.finish(error: nil) }
        try await withInputTestTimeout { () async throws in
            channel.finish(error: nil)
            #expect(try await reading.value == "partial")
            #expect(try await input.read() == nil)
        } cleanup: {
            channel.finish(error: nil)
        }
    }
}
