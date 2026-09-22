import Foundation
import XUtils
import Dependencies

package enum Console {
    package static func prompt(_ message: String) async throws -> String {
        @Dependency(\.commandInput) var input
        d.out.print(message, terminator: "", flush: true)
        guard let line = try await input.readLine() else { throw Console.Error("Input ended before a response was received.") }
        return line
    }

    package static func promptRequired(_ message: String, existing: String?) async throws -> String {
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

    package static func getPassword(_ message: String) async throws -> String {
        if !message.isEmpty {
            d.out.print(message, terminator: "")
        }
        let password = try await withoutEcho { try await prompt("") }
        d.out.print()
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

    package static func chooseNumber(in range: Range<Int>) async throws -> Int {
        let message = "Choice (\(range.lowerBound)-\(range.upperBound - 1)): "
        while true {
            if let choice = try await Int(prompt(message)), range.contains(choice) {
                return choice
            }
        }
    }

    package static func choose<T>(
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
            d.out.print(multiPrompt())
            try elements.enumerated().forEach { index, element in
                try d.out.print("\(index): \(formatter(element))")
            }
            let choice = try await chooseNumber(in: elements.indices)
            return elements[choice]
        }
    }

    private static let yesSet: Set<String> = ["yes", "y"]
    private static let noSet: Set<String> = ["no", "n"]

    package static func confirm(_ message: String) async throws -> Bool {
        while true {
            let resp = try await prompt("\(message) (yes/no): ").lowercased()
            if yesSet.contains(resp) {
                return true
            } else if noSet.contains(resp) {
                return false
            }
        }
    }

    package struct Error: Swift.Error, CustomStringConvertible {
        package let description: String
        package init(_ description: String) {
            self.description = description
        }
    }
}
