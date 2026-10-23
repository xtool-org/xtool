import Dependencies
import Foundation
import PackLib
import Subprocess
import XUtils

struct MacToolOutput: Sendable {
    var output: Data
    var error: Data
}

/// The Mac host tools that signing, notarization and `dev run` invoke.
struct MacHostClient: DependencyKey, Sendable {
    var isMacOS: @Sendable () -> Bool = { false }
    /// Runs a tool to completion, capturing both streams; codesign reports metadata on stderr.
    var capture: @Sendable (String, [String]) async throws -> MacToolOutput = { tool, _ in
        throw StringError("Unexpected host tool invocation: \(tool)")
    }
    /// Runs a tool to completion, capturing stdout while stderr progress reaches the terminal.
    var stream: @Sendable (String, [String]) async throws -> Data = { tool, _ in
        throw StringError("Unexpected host tool invocation: \(tool)")
    }
    /// Runs an app attached to this terminal and returns its exit status.
    var launch: @Sendable (URL, [String]) async throws -> Int32 = { _, _ in throw StringError("Unexpected Mac launch") }

    static let liveValue = Self(
        isMacOS: {
            #if os(macOS)
            true
            #else
            false
            #endif
        },
        capture: { executable, arguments in
            let result = try await Subprocess.run(
                .path(.init(executable)), arguments: .init(arguments),
                platformOptions: .withGracefulShutDown, output: .data(limit: .max), error: .data(limit: .max)
            )
            do { try result.checkSuccess() } catch {
                throw StringError("\(executable) failed: \(String(decoding: result.standardError, as: UTF8.self))")
            }
            return MacToolOutput(output: result.standardOutput, error: result.standardError)
        },
        stream: { executable, arguments in
            let result = try await Subprocess.run(
                .path(.init(executable)), arguments: .init(arguments),
                output: .string(limit: .max), error: .currentStandardError
            ).checkSuccess()
            return Data(result.standardOutput.utf8)
        },
        launch: { executable, arguments in
            let result = try await Subprocess.run(
                .path(.init(executable.path)), arguments: .init(arguments),
                platformOptions: .withGracefulShutDown,
                output: .currentStandardOutput, error: .currentStandardError
            )
            switch result.terminationStatus {
            case .exited(let code): return code
            case .signaled(let signal): return 128 + signal
            }
        }
    )

    static let testValue = Self()
}

extension DependencyValues {
    var macHostClient: MacHostClient {
        get { self[MacHostClient.self] }
        set { self[MacHostClient.self] = newValue }
    }
}
