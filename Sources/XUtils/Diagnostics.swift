import Foundation

public struct Diagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable {
        case warning
        case note
    }

    public var severity: Severity
    public var message: String

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public actor Diagnostics {
    private var entries: [Diagnostic] = []

    public init() {}

    public func append(_ diagnostic: Diagnostic) {
        entries.append(diagnostic)
    }

    public func warn(_ message: String) {
        entries.append(Diagnostic(severity: .warning, message: message))
    }

    public func note(_ message: String) {
        entries.append(Diagnostic(severity: .note, message: message))
    }

    public func drain() -> [Diagnostic] {
        let out = entries
        entries.removeAll()
        return out
    }

    public func all() -> [Diagnostic] {
        entries
    }
}
