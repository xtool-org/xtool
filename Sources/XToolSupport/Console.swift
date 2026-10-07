import Foundation
import XKit
import XUtils
import NIOPosix
import NIOCore
#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#endif

enum Console {
    private static let fallbackReadBufferSize = 256

    private static func withStdio<T>(
        input: CInt,
        output: CInt,
        _ body: (
            _ stdin: NIOAsyncChannelInboundStream<ByteBuffer>,
            _ stdout: NIOAsyncChannelOutboundWriter<ByteBuffer>
        ) async throws -> T
    ) async throws -> T {
        try await NIOPipeBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .takingOwnershipOfDescriptors(
                input: FileDescriptor(rawValue: input).duplicate().rawValue,
                output: FileDescriptor(rawValue: output).duplicate().rawValue
            )
            .flatMapThrowing { try NIOAsyncChannel(wrappingChannelSynchronously: $0) }
            .get()
            .executeThenClose { try await body($0, $1) }
    }

    static func prompt(_ message: String) async throws -> String {
        try await prompt(
            message,
            input: FileDescriptor.standardInput.rawValue,
            output: FileDescriptor.standardOutput.rawValue
        )
    }

    static func prompt(_ message: String, input: CInt, output: CInt) async throws -> String {
        if isEpollRegisterable(input), isEpollRegisterable(output) {
            return try await promptUsingNIO(message, input: input, output: output)
        }
        return try await promptUsingFileDescriptors(message, input: input, output: output)
    }

    /// Linux `epoll_ctl` returns `EPERM` for `/dev/null`, and SwiftNIO turns that into a fatal error.
    /// `isatty` and `poll` miss it: non-ttys already work, and `poll` reports `/dev/null` as ready.
    #if os(Linux)
    static func isEpollRegisterable(_ descriptor: CInt) -> Bool {
        let epollFD = epoll_create1(numericCast(EPOLL_CLOEXEC))
        guard epollFD >= 0 else {
            return true
        }
        defer { try? FileDescriptor(rawValue: epollFD).close() }

        var event = epoll_event()
        // Glibc imports these as an enum; Musl imports them as integers.
        #if canImport(Musl)
        event.events = numericCast(EPOLLERR) | numericCast(EPOLLHUP)
        #else
        event.events = numericCast(EPOLLERR.rawValue) | numericCast(EPOLLHUP.rawValue)
        #endif
        guard epoll_ctl(epollFD, numericCast(EPOLL_CTL_ADD), descriptor, &event) == 0 else {
            return errno != EPERM
        }
        return true
    }
    #else
    static func isEpollRegisterable(_: CInt) -> Bool {
        true
    }
    #endif

    private static func promptUsingNIO(
        _ message: String,
        input: CInt,
        output: CInt
    ) async throws -> String {
        try await withStdio(input: input, output: output) { stdin, stdout in
            do {
                try await stdout.write(ByteBuffer(bytes: message.utf8))
            } catch ChannelError.ioOnClosedChannel {
                // An already-closed pipe is drained and the channel closed before this write.
                // Those bytes are buffered on `stdin`; the caller's output descriptor is still open.
                try FileDescriptor(rawValue: output).writeAll(message.utf8)
            }

            fflush(stdoutSafe)

            var data = Data()
            for try await chunk in stdin {
                let view = chunk.readableBytesView
                if let endIndex = view.firstIndex(of: UInt8(ascii: "\n")) {
                    data += view[..<endIndex]
                    break
                } else {
                    data += view
                }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private static func promptUsingFileDescriptors(
        _ message: String,
        input: CInt,
        output: CInt
    ) async throws -> String {
        try FileDescriptor(rawValue: output).writeAll(message.utf8)
        fflush(stdoutSafe)
        return try await Task.detached {
            try Self.readLine(from: input)
        }.value
    }

    private static func readLine(from descriptor: CInt) throws -> String {
        let input = FileDescriptor(rawValue: descriptor)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: fallbackReadBufferSize)
        while true {
            let bytesRead = try buffer.withUnsafeMutableBytes { rawBuffer in
                try input.read(into: rawBuffer)
            }
            if bytesRead == 0 {
                break
            }
            let chunk = buffer.prefix(bytesRead)
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: chunk[..<newline])
                break
            }
            data.append(contentsOf: chunk)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func promptRequired(_ message: String, existing: String?) async throws -> String {
        let value: String
        if let existing {
            value = existing
        } else {
            value = try await Console.prompt(message)
        }
        guard !value.isEmpty else {
            throw Console.Error("Input cannot be empty.")
        }
        return value
    }

    static func getPassword(_ message: String) async throws -> String {
        if !message.isEmpty {
            print(message, terminator: "")
        }
        let password = try await withoutEcho { try await prompt("") }
        print()
        return password
    }

    private static func withoutEcho<T>(_ action: () async throws -> T) async rethrows -> T {
        #if os(Windows)
        // based on https://stackoverflow.com/a/4497117/3769927
        // TODO: Confirm that this works (or even compiles)

        let hConsole = CreateFileA("CONIN$", GENERIC_WRITE | GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0)
        var dwOldMode: DWORD = 0
        GetConsoleMode(hConsole, &dwOldMode)

        let dwNewMode = dwOldMode & ~ENABLE_ECHO_INPUT
        SetConsoleMode(hConsole, dwNewMode)
        defer { SetConsoleMode(hConsole, dwOldMode) }

        return try action()
        #else
        var origAttr = termios()
        tcgetattr(STDIN_FILENO, &origAttr)

        var newAttr = origAttr
        newAttr.c_lflag = newAttr.c_lflag & ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newAttr)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &origAttr) }

        return try await action()
        #endif
    }

    static func chooseNumber(in range: Range<Int>) async throws -> Int {
        let message = "Choice (\(range.lowerBound)-\(range.upperBound - 1)): "
        while true {
            if let choice = try await Int(prompt(message)), range.contains(choice) {
                return choice
            }
        }
    }

    static func choose<T>(
        from elements: [T],
        onNoElement: () throws -> T,
        multiPrompt: @autoclosure () -> String,
        formatter: (T) throws -> String
    ) async throws -> T {
        switch elements.count {
        case 0:
            return try onNoElement()
        case 1:
            return elements[0]
        default:
            print(multiPrompt())
            try elements.enumerated().forEach { index, element in
                try print("\(index): \(formatter(element))")
            }
            let choice = try await chooseNumber(in: elements.indices)
            return elements[choice]
        }
    }

    private static let yesSet: Set<String> = ["yes", "y"]
    private static let noSet: Set<String> = ["no", "n"]

    static func confirm(_ message: String) async throws -> Bool {
        while true {
            let resp = try await prompt("\(message) (yes/no): ").lowercased()
            if yesSet.contains(resp) {
                return true
            } else if noSet.contains(resp) {
                return false
            }
        }
    }

    struct Error: Swift.Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
