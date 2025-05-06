import Foundation
import XKit
import SystemPackage
import NIOPosix
import NIOCore

enum Console {
    private static func withStdio<T>(
        _ body: (
            _ stdin: NIOAsyncChannelInboundStream<ByteBuffer>,
            _ stdout: NIOAsyncChannelOutboundWriter<ByteBuffer>
        ) async throws -> T
    ) async throws -> T {
        try await NIOPipeBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .takingOwnershipOfDescriptors(
                input: FileDescriptor.standardInput.duplicate().rawValue,
                output: FileDescriptor.standardOutput.duplicate().rawValue
            )
            .flatMapThrowing { try NIOAsyncChannel(wrappingChannelSynchronously: $0) }
            .get()
            .executeThenClose { try await body($0, $1) }
    }

    static func prompt(_ message: String) async throws -> String {
        try await withStdio { stdin, stdout in
            try await stdout.write(ByteBuffer(bytes: message.utf8))

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
