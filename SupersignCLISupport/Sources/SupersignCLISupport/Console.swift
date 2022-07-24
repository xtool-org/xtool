import Foundation

enum Console {
    // nil = EOF
    static func prompt(_ message: String) -> String? {
        if !message.isEmpty {
            print(message, terminator: "")
        }
        fflush(stdout)
        return readLine()
    }

    static func getPassword(_ message: String) -> String? {
        if !message.isEmpty {
            print(message, terminator: "")
        }
        let password = withoutEcho { prompt("") }
        print()
        return password
    }

    private static func withoutEcho<T>(_ action: () throws -> T) rethrows -> T {
        #if os(Windows)
        // based on https://stackoverflow.com/a/4497117/3769927
        // TODO: Confirm that this works (or even compiles)

        let hConsole = CreateFileA("CONIN$", GENERIC_WRITE | GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0)
        var dwOldMode: DWORD = 0
        GetConsoleMode(hConsole, &dwOldMode)

        let dwNewMode = dwOldMode & ~ENABLE_ECHO_INPUT
        SetConsoleMode(hConsole, dwNewMode)
        defer { SetConsoleMode(hConsole, dwOldMode) }
        #else
        var origAttr = termios()
        tcgetattr(STDIN_FILENO, &origAttr)

        var newAttr = origAttr
        newAttr.c_lflag = newAttr.c_lflag & ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newAttr)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &origAttr) }
        #endif

        return try action()
    }

    static func chooseNumber(in range: Range<Int>) -> Int {
        let message = "Choice (\(range.lowerBound)-\(range.upperBound - 1)): "
        while true {
            if let choice = prompt(message).flatMap(Int.init), range.contains(choice) {
                return choice
            }
        }
    }

    static func choose<T>(
        from elements: [T],
        onNoElement: () throws -> T,
        multiPrompt: @autoclosure () -> String,
        formatter: (T) throws -> String
    ) rethrows -> T {
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
            let choice = chooseNumber(in: elements.indices)
            return elements[choice]
        }
    }

    private static let yesSet: Set<String> = ["yes", "y"]
    private static let noSet: Set<String> = ["no", "n"]

    static func confirm(_ message: String) -> Bool {
        while true {
            if let resp = prompt("\(message) (yes/no): ")?.lowercased() {
                if yesSet.contains(resp) {
                    return true
                } else if noSet.contains(resp) {
                    return false
                }
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
