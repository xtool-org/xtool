// swiftlint:disable prefer_dependency_print

import Dependencies
import Foundation
import CXKit

/// Task-scoped command output, shared by build, packaging, and device operations.
public struct CommandOutput: DependencyKey, Sendable {
    public enum Stream: String, Codable, Sendable {
        case stdout
        case stderr
    }

    public var write: @Sendable (_ data: Data, _ stream: Stream, _ flush: Bool) -> Void

    public init(write: @escaping @Sendable (Data, Stream, Bool) -> Void) {
        self.write = write
    }

    public func print(
        _ message: String = "",
        terminator: String = "\n",
        stream: Stream = .stdout,
        flush: Bool = false
    ) {
        write(Data((message + terminator).utf8), stream, flush)
    }

    @_disfavoredOverload
    public func print(
        _ items: Any...,
        separator: String = " ",
        terminator: String = "\n",
        stream: Stream = .stdout,
        flush: Bool = false
    ) {
        print(
            items.map { String(describing: $0) }.joined(separator: separator),
            terminator: terminator,
            stream: stream,
            flush: flush
        )
    }

    public static var liveValue: Self {
        let outputLock = NSLock()
        return Self { data, stream, flush in
            let descriptor: FileDescriptor = stream == .stdout ? .standardOutput : .standardError
            // Keep concurrent messages together, including across partial writes.
            outputLock.withLock {
                try? data.withUnsafeBytes { try descriptor.writeAllWaiting($0) }
                if flush { fflush(get_stdout()) }
            }
        }
    }

    public static var testValue: Self { Self(write: unimplemented("CommandOutput.write")) }
}

extension DependencyValues {
    public var out: CommandOutput {
        get { self[CommandOutput.self] }
        set { self[CommandOutput.self] = newValue }
    }
}
