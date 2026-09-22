@testable import XCLIUtils
import Dependencies
import Foundation
import Testing
import XUtils

struct CommandInputTests {
    @Test(.timeLimit(.minutes(1)))
    func pipeReadsBytesAndEOFWithoutClosingOriginal() async throws {
        let pipe = Pipe()
        let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        let reader = StandardCommandInput(descriptor: descriptor)
        defer { await reader.close() }
        let bytes = Data([0, 255, 128, 10])
        try pipe.fileHandleForWriting.write(contentsOf: bytes)
        try pipe.fileHandleForWriting.close()
        #expect(try await reader.read() == bytes)
        #expect(try await reader.read() == nil)
        await reader.close()
        #expect(fcntl(descriptor.rawValue, F_GETFL) == flags)
    }

    @Test(.timeLimit(.minutes(1)))
    func redirectedFileUsesBoundedChunks() async throws {
        let path = URL(filePath: "/tmp/xtool-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }
        let bytes = Data(repeating: 255, count: StandardCommandInput.chunkSize * 2 + 7)
        try bytes.write(to: path)
        let descriptor = try FileDescriptor.open(FilePath(path.path), .readOnly)
        defer { try? descriptor.close() }
        let reader = StandardCommandInput(descriptor: descriptor)
        defer { await reader.close() }
        var received = Data()
        while let chunk = try await reader.read() {
            #expect(chunk.count <= StandardCommandInput.chunkSize)
            received.append(chunk)
        }
        #expect(received == bytes)
        #expect(try await reader.read() == nil)
        await reader.close()
        #expect(fcntl(descriptor.rawValue, F_GETFL) != -1)
    }

    @Test(.timeLimit(.minutes(1)))
    func nullInputIsEOF() async throws {
        let descriptor = try FileDescriptor.open("/dev/null", .readOnly)
        defer { try? descriptor.close() }
        let reader = StandardCommandInput(descriptor: descriptor)
        defer { await reader.close() }
        #expect(try await reader.read() == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func closingOrCancellingUnblocksPipeRead() async throws {
        for cancel in [false, true] {
            let pipe = Pipe()
            let descriptor = FileDescriptor(rawValue: pipe.fileHandleForReading.fileDescriptor)
            let reader = StandardCommandInput(descriptor: descriptor)
            let task = Task { try await reader.read() }
            // Wait until NIO has opened the duplicate and the pipe read can be pending.
            while fcntl(descriptor.rawValue, F_GETFL) & O_NONBLOCK == 0 {
                try await Task.sleep(for: .milliseconds(1))
            }
            if cancel { task.cancel() }
            await reader.close()
            do {
                #expect(try await task.value == nil)
                #expect(!cancel)
            } catch is CancellationError {
                #expect(cancel)
            }
        }
    }

    #if os(macOS)
    @Test(.timeLimit(.minutes(1)))
    func terminalInputPreservesEchoAndCanonicalMode() async throws {
        var controller: Int32 = -1
        var terminal: Int32 = -1
        try #require(openpty(&controller, &terminal, nil, nil, nil) == 0)
        let controllerHandle = FileHandle(fileDescriptor: controller, closeOnDealloc: true)
        let descriptor = FileDescriptor(rawValue: terminal)
        defer { try? descriptor.close() }
        var original = termios()
        try #require(tcgetattr(terminal, &original) == 0)
        let flags = fcntl(terminal, F_GETFL)
        let reader = StandardCommandInput(descriptor: descriptor)
        defer { await reader.close() }
        try await withDependencies {
            $0.commandInput = CommandInput(read: { try await reader.read() })
            $0.out.write = { _, _, flush in #expect(flush) }
        } operation: {
            try controllerHandle.write(contentsOf: Data("first\nsecond\n".utf8))
            #expect(try await Console.prompt("First: ") == "first")
            #expect(try await Console.prompt("Second: ") == "second")
        }
        await reader.close()
        var restored = termios()
        try #require(tcgetattr(terminal, &restored) == 0)
        #expect(original.c_lflag == restored.c_lflag)
        #expect(original.c_iflag == restored.c_iflag)
        #expect(fcntl(terminal, F_GETFL) == flags)
        try controllerHandle.close()
    }
    #endif
}
