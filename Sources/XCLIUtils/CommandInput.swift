import ConcurrencyExtras
import Dependencies
import Foundation
import NIOCore
import NIOPosix
import XUtils

/// A single consumer's command input. A nil chunk means EOF.
package struct CommandInput: DependencyKey, Sendable {
    package var read: @Sendable () async throws -> Data?
    package var close: @Sendable () async -> Void
    private let lines = LineBuffer()

    package init(
        read: @escaping @Sendable () async throws -> Data?,
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.read = read
        self.close = close
    }

    package func readLine() async throws -> String? {
        try await lines.readLine(read: read)
    }

    package static var liveValue: Self {
        let input = StandardCommandInput()
        return Self(read: { try await input.read() }, close: { await input.close() })
    }

    package static var testValue: Self { Self(read: unimplemented("CommandInput.read", placeholder: nil)) }

    private actor LineBuffer {
        var buffer = Data()
        var ended = false

        func readLine(read: @Sendable () async throws -> Data?) async throws -> String? {
            while true {
                try Task.checkCancellation()
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    return line.trimmingTrailingCarriageReturn()
                }
                if ended {
                    guard !buffer.isEmpty else { return nil }
                    defer { buffer.removeAll() }
                    return String(decoding: buffer, as: UTF8.self).trimmingTrailingCarriageReturn()
                }
                if let chunk = try await read() {
                    buffer.append(chunk)
                } else {
                    ended = true
                }
            }
        }
    }
}

private extension String {
    func trimmingTrailingCarriageReturn() -> String {
        hasSuffix("\r") ? String(dropLast()) : self
    }
}

extension DependencyValues {
    package var commandInput: CommandInput {
        get { self[CommandInput.self] }
        set { self[CommandInput.self] = newValue }
    }
}

/// Buffers packets received before a command starts reading, without decoding bytes.
package struct CommandInputQueue: Sendable {
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    package init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
    }

    package var input: CommandInput {
        CommandInput(read: { try await read() }, close: { finish() })
    }

    package func read() async throws -> Data? {
        try Task.checkCancellation()
        var iterator = stream.makeAsyncIterator()
        let chunk = try await iterator.next()
        try Task.checkCancellation()
        return chunk
    }

    package func receive(_ data: Data?) {
        if let data { continuation.yield(data) } else { finish() }
    }

    package func finish(throwing error: (any Error)? = nil) {
        continuation.finish(throwing: error)
    }
}

/// Lazily opens stdin, retaining one reader across successive local prompts.
actor StandardCommandInput {
    static let chunkSize = 64 * 1024
    private let descriptor: XUtils.FileDescriptor
    private var source: Task<Source, any Error>?
    private var fileRead: Task<Data?, any Error>?
    private var isClosed = false

    private enum Source: Sendable {
        case file(FileHandle)
        case pipe(any Channel, CommandInputQueue, flags: Int32)
    }

    init(descriptor: XUtils.FileDescriptor = .standardInput) {
        self.descriptor = descriptor
    }

    func read() async throws -> Data? {
        try Task.checkCancellation()
        guard !isClosed else { return nil }
        if source == nil {
            source = Task { try await open() }
            @Dependency(\.shutdownRegistry) var shutdownRegistry
            await shutdownRegistry.register { await self.close() }
        }
        guard let opening = source else { return nil }
        let source = try await opening.value
        try Task.checkCancellation()
        guard !isClosed else { return nil }
        let data: Data?
        switch source {
        case .file(let handle):
            let task = Task {
                try await NIOThreadPool.singleton.runIfActive {
                    let data = try handle.read(upToCount: Self.chunkSize)
                    return data?.isEmpty == false ? data : nil
                }
            }
            fileRead = task
            defer { fileRead = nil }
            data = try await task.cancellableValue
        case .pipe(let channel, let queue, _):
            channel.read()
            data = try await queue.read()
        }
        try Task.checkCancellation()
        return data
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        guard let source = try? await source?.value else { return }
        switch source {
        case .file(let handle):
            _ = try? await fileRead?.value
            try? handle.close()
        case .pipe(let channel, let queue, let flags):
            queue.finish()
            try? await channel.close().get()
            // dup shares status flags with stdin; undo NIO's O_NONBLOCK change.
            _ = fcntl(descriptor.rawValue, F_SETFL, flags)
        }
    }

    private func open() async throws -> Source {
        var info = stat()
        guard fstat(descriptor.rawValue, &info) == 0 else { throw Errno(rawValue: errno) }
        let duplicate = try descriptor.duplicate()
        let kind = info.st_mode & mode_t(S_IFMT)
        // Regular files and /dev/null cannot be registered with epoll on Linux.
        if kind == mode_t(S_IFREG) || (kind == mode_t(S_IFCHR) && isatty(descriptor.rawValue) == 0) {
            return .file(FileHandle(fileDescriptor: duplicate.rawValue, closeOnDealloc: true))
        }
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        let queue = CommandInputQueue()
        do {
            let channel = try await NIOPipeBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: Self.chunkSize))
                .takingOwnershipOfDescriptor(input: duplicate.rawValue) { channel in
                    channel.pipeline.addHandler(Receiver(queue: queue)).map { channel }
                }
            return .pipe(channel, queue, flags: flags)
        } catch {
            try? duplicate.close()
            _ = fcntl(descriptor.rawValue, F_SETFL, flags)
            throw error
        }
    }

    private final class Receiver: ChannelInboundHandler, Sendable {
        typealias InboundIn = ByteBuffer
        let queue: CommandInputQueue

        init(queue: CommandInputQueue) { self.queue = queue }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            queue.receive(Data(unwrapInboundIn(data).readableBytesView))
        }

        func channelInactive(context: ChannelHandlerContext) { queue.finish() }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            queue.finish(throwing: error)
            context.close(promise: nil)
        }
    }
}
