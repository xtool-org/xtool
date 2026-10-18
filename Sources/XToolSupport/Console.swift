import Foundation
import XKit
import XUtils

enum Console {
    /// Bridges the synchronous, blocking stdin read to a cancellable async
    /// read. SIGINT is delivered as task cancellation by
    /// XToolCommand.cancellableMain, so a prompt must observe cancellation.
    private final class PromptRead: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, any Swift.Error>?
        private var cancelled = false

        /// Returns true when the continuation was installed and the caller
        /// should start the blocking read. Returns false when cancellation
        /// already happened: the continuation is resumed immediately and no
        /// read thread should be started.
        func install(_ continuation: CheckedContinuation<String?, any Swift.Error>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            return true
        }

        func finish(returning value: String?) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }

        func finish(throwing error: any Swift.Error) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            continuation?.resume(throwing: CancellationError())
            continuation = nil
        }
    }

    static func prompt(_ message: String) async throws -> String {
        print(message, terminator: "")
        fflush(stdoutSafe)

        let read = PromptRead()
        return try await withTaskCancellationHandler {
            let line = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Swift.Error>) in
                if read.install(continuation) {
                    let thread = Thread {
                        do {
                            read.finish(returning: try readLineFromStandardInput())
                        } catch {
                            read.finish(throwing: error)
                        }
                    }
                    thread.name = "xtool-console-prompt"
                    thread.start()
                }
            }
            guard let line else {
                // EOF (e.g. stdin redirected from /dev/null): surface a clean
                // error instead of trapping on NIO's epoll registration.
                throw Error("Unexpected end of input.")
            }
            return line.hasSuffix("\r") ? String(line.dropLast()) : line
        } onCancel: {
            // Unblock the suspended continuation; the read thread's blocking
            // read is abandoned and dies when the process exits.
            read.cancel()
        }
    }

    /// Reads a line from stdin using FileHandle (raw read(), not C stdio).
    /// C stdio's readLine() holds the stdin lock while blocked, which
    /// deadlocks exit() after SIGINT cancels a prompt.
    private static func readLineFromStandardInput() throws -> String? {
        var data = Data()
        let handle = FileHandle.standardInput
        while true {
            guard let chunk = try handle.read(upToCount: 1), !chunk.isEmpty else {
                // EOF (nil or empty read)
                return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
            }
            if chunk.first == UInt8(ascii: "\n") {
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
