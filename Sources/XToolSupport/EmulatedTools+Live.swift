import Dependencies
import Foundation
import Subprocess
import XUtils

// MARK: - Tools

extension EmulatedTools: DependencyKey {
    static let liveValue = EmulatedTools({
        var tools: [any EmulatedTool] = [
            SwiftCompilerTool(),
        ]
        #if !os(macOS)
        tools += [
            LSRegisterTool(),
            EmbeddedBinaryValidationTool(),
            ObjcopyTool(mode: .strip),
            ObjcopyTool(mode: .bitcodeStrip),
            ChmodTool(),
            TouchTool(),
            CodesignTool(),
            DerqTool(),
        ]
        #endif
        return tools
    }())
}

private struct LSRegisterTool: EmulatedTool {
    var name: String { "lsregister" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        .result(status: .exit(0), stdout: Data(), stderr: Data())
    }
}

private struct EmbeddedBinaryValidationTool: EmulatedTool {
    var name: String { "embeddedBinaryValidationUtility" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        .result(status: .exit(0), stdout: Data(), stderr: Data())
    }
}

private struct ObjcopyTool: EmulatedTool {
    enum Mode {
        case strip
        case bitcodeStrip

        var name: String {
            switch self {
            case .strip: "strip"
            case .bitcodeStrip: "bitcode_strip"
            }
        }
    }

    let mode: Mode
    var name: String { mode.name }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        let remaining = commandLine.dropFirst().filter { $0 != "-no_atom_info" }
        return try await Subprocess.run(
            .name("llvm-objcopy"),
            arguments: Arguments(
                executablePathOverride: name,
                remainingValues: remaining,
            ),
            environment: Environment(environment),
            workingDirectory: workingDirectory.map { FilePath($0) },
            output: .data(limit: .max),
            error: .data(limit: .max),
        )
        .emulatedToolResult
    }
}

private struct ChmodTool: EmulatedTool {
    var name: String { "chmod" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        var remaining = Array(commandLine.dropFirst())
        // SetAttributesSpec conditions the -H flag on whether the target is Darwin, rather
        // than whether the host is Darwin
        if let index = remaining.firstIndex(of: "-RH") {
            remaining[index] = "-R"
        }
        return try await Subprocess.run(
            .name("chmod"),
            arguments: Arguments(remaining),
            environment: Environment(environment),
            workingDirectory: workingDirectory.map { FilePath($0) },
            output: .data(limit: .max),
            error: .data(limit: .max),
        )
        .emulatedToolResult
    }
}

private struct TouchTool: EmulatedTool {
    var name: String { "touch" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        // SwiftBuild typically hardcodes `/usr/bin/touch`, which is absent on some Linux distros
        // like Nix. This finds it in PATH instead.
        try await Subprocess.run(
            .name("touch"),
            arguments: Arguments(Array(commandLine.dropFirst())),
            environment: Environment(environment),
            workingDirectory: workingDirectory.map { FilePath($0) },
            output: .data(limit: .max),
            error: .data(limit: .max),
        )
        .emulatedToolResult
    }
}

extension Environment {
    init(_ dictionary: [String: String]) {
        self = .custom([]).updating(
            Dictionary(uniqueKeysWithValues: dictionary.map {
                (Environment.Key(stringLiteral: $0.key), $0.value)
            })
        )
    }
}

extension ExecutionResult where Output == DataOutput, Error == DataOutput {
    var emulatedToolResult: EmulatedToolResult {
        .result(
            status: terminationStatus.emulatedToolExitStatus,
            stdout: standardOutput,
            stderr: standardError
        )
    }
}

extension TerminationStatus {
    var emulatedToolExitStatus: EmulatedToolExitStatus {
        switch self {
        case .exited(let code): .exit(numericCast(code))
        case .signaled(let signal): .uncaughtSignal(numericCast(signal))
        }
    }
}
