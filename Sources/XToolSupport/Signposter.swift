import XUtils
import Foundation

enum Signposter {
    static let start = Date()

    static let isEnabled = ProcessInfo.processInfo.environment["XTL_SIGNPOST"] == "1"

    static func setup() {
        _ = start
    }

    static func track(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let start = Self.start
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        let elapsedString = String(format: "%.2f", elapsed)
        d.out.print("[\(elapsedString)s] \(message())")
    }
}
