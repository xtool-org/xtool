@testable import XCLIUtils
import CustomDump
import Foundation
import Testing
import XUtils

@Suite(.timeLimit(.minutes(1)))
struct DispatchInputTests {
    @Test
    func commandInputReadsLinesAcrossDispatchBatches() async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        try pipe.fileHandleForWriting.write(contentsOf: Data("abfirst\r\n\nlast".utf8))
        try pipe.fileHandleForWriting.close()
        try await withReader(descriptor: descriptor, chunkSize: 2) { reader async throws in
            let input = CommandInput(read: { try await reader.read(upTo: $0) })
            #expect(try await input.read(upTo: .bytes(2)) == Data("ab".utf8))
            #expect(try await input.readLine() == "first")
            #expect(try await input.readLine() == "")
            #expect(try await input.readLine() == "last")
            #expect(try await input.read() == nil)
        }
    }

    @Test
    func pipeDeliversShortChunksBeforeEOF() async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        try await withReader(descriptor: descriptor) { reader in
            for bytes in [Data("first\n".utf8), Data([0, 255, 128])] {
                try pipe.fileHandleForWriting.write(contentsOf: bytes)
                let chunk = try await reader.read()
                expectNoDifference(chunk, bytes)
            }
            try pipe.fileHandleForWriting.close()
            #expect(try await reader.read() == nil)
            #expect(try await reader.read() == nil)
        }
        #expect(fcntl(descriptor.rawValue, F_GETFL) == flags)
    }

    @Test
    func pipePreservesBytesAcrossBatches() async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let bytes = Data((0..<1027).map { UInt8(truncatingIfNeeded: $0) })
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()
        try await withReader(descriptor: descriptor, chunkSize: 64) { reader in
            var received = Data()
            while let chunk = try await reader.read() {
                #expect(!chunk.isEmpty)
                #expect(chunk.count <= 64)
                received.append(chunk)
            }
            expectNoDifference(received, bytes)
        }
    }

    @Test(arguments: [false, true])
    @available(anyAppleOS 26.0, *)
    func closeFinishesBeforeOrDuringRead(pendingRead: Bool) async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        try await withReader(descriptor: descriptor) { reader async throws in
            if pendingRead {
                let reading = Task.immediate { try await reader.read() }
                defer { reading.cancel() }
                await reader.close()
                #expect(try await reading.value == nil)
            } else {
                await reader.close()
            }
            #expect(try await reader.read() == nil)
            await reader.close()
        }
        #expect(fcntl(descriptor.rawValue, F_GETFL) == flags)
    }

    @Test
    func nullInputClosesAfterEOF() async throws {
        let descriptor = try FileDescriptor.open("/dev/null", .readOnly)
        defer { try? descriptor.close() }
        try await withReader(descriptor: descriptor) { reader async throws in
            #expect(try await reader.read() == nil)
            await reader.close()
            #expect(try await reader.read() == nil)
        }
        #expect(fcntl(descriptor.rawValue, F_GETFL) != -1)
    }

    @Test
    func readErrorSurvivesClose() async throws {
        let descriptor = try FileDescriptor.open("/dev/null", .writeOnly)
        defer { try? descriptor.close() }
        try await withReader(descriptor: descriptor) { reader in
            await #expect(throws: Errno.badFileDescriptor) { try await reader.read() }
            await reader.close()
            await #expect(throws: Errno.badFileDescriptor) { try await reader.read() }
        }
    }

    @Test
    func invalidDescriptorFailsDuringInitOrRead() async throws {
        // DispatchIO can report initialization failure before or after init returns.
        await #expect(throws: Errno.badFileDescriptor) {
            try await withReader(descriptor: FileDescriptor(rawValue: -1)) { reader in
                _ = try await reader.read()
            }
        }
    }

    @Test
    func fileReadsAreBoundedAndPreserveAllBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let bytes = Data((0..<10_003).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: path)
        let descriptor = try FileDescriptor.open(FilePath(path.path), .readOnly)
        defer { try? descriptor.close() }
        try await withReader(descriptor: descriptor, chunkSize: 1024) { reader in
            var received = Data()
            while let chunk = try await reader.read() {
                #expect(!chunk.isEmpty)
                #expect(chunk.count <= 1024)
                received.append(chunk)
            }
            expectNoDifference(received, bytes)
            #expect(try await reader.read() == nil)
        }
    }

    @Test
    func idleConsumerDoesNotStartAnotherBatch() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data(repeating: 255, count: 16 * 1024).write(to: path)
        let descriptor = try FileDescriptor.open(FilePath(path.path), .readOnly)
        defer { try? descriptor.close() }
        try await withReader(descriptor: descriptor, chunkSize: 1024) { reader in
            #expect(try await reader.read() != nil)
            // Allow any unintended read-ahead to run while the consumer is idle.
            try await Task.sleep(for: .milliseconds(20))
            await reader.close()
            let offset = try descriptor.seek(offset: 0, from: .current)
            #expect(offset > 0)
            #expect(offset <= 1024)
        }
    }

    @Test
    func deinitClosesPendingIOAndRestoresDescriptor() async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        weak var weakReader: DispatchInput?
        do {
            let reader: DispatchInput = try DispatchInput(fileDesciptor: descriptor)
            weakReader = reader
            try pipe.fileHandleForWriting.write(contentsOf: Data("a".utf8))
            let chunk = try await withInputTestTimeout {
                try await reader.read()
            } cleanup: { [reader] in
                await reader.close()
            }
            expectNoDifference(chunk, Data("a".utf8))
            #expect(fcntl(descriptor.rawValue, F_GETFL) & O_NONBLOCK != 0)
        }
        #expect(weakReader == nil)
        // poll for channel.close() to finish
        let deadline = ContinuousClock.now + .seconds(2)
        while fcntl(descriptor.rawValue, F_GETFL) != flags {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for input operation")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func withReader(
        descriptor: FileDescriptor,
        chunkSize: Int = DispatchInput.defaultChunkSize,
        operation: (DispatchInput) async throws -> Void,
    ) async throws {
        let reader = try DispatchInput(fileDesciptor: descriptor, chunkSize: chunkSize)
        defer { await reader.close() }
        try await withInputTestTimeout {
            try await operation(reader)
        } cleanup: {
            await reader.close()
        }
    }
}
