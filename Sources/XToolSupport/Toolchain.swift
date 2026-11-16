import XUtils
import Dependencies
import Foundation
import Subprocess

public struct Toolchain: Sendable {
    public var toolchainRoot: FilePath
    public var swiftTool: FilePath
    public var swiftVersion: SwiftVersion
    public var runtimeResourcePath: FilePath
}

public struct ToolchainProvider: DependencyKey, Sendable {
    public var toolchain: @Sendable () async throws -> Toolchain

    public init(toolchain: @escaping @Sendable () async throws -> Toolchain) {
        self.toolchain = toolchain
    }

    public static var liveValue: Self {
        Self { try await liveToolchain.value }
    }

    public static var testValue: Self {
        // allow tests to use the live Swift toolchain by default
        liveValue
    }

    fileprivate static let liveToolchain = Task<Toolchain, Error> {
        #if os(macOS)
        let swiftTool = FilePath(
            try await Subprocess.run(
                .path("/usr/bin/xcrun"),
                arguments: ["-f", "swift"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        #else
        let swiftTool = try await Executable.name("swift").resolveExecutablePath(in: .inherit)
        #endif

        struct SwiftTargetInfo: Decodable {
            var compilerVersion: String
            struct Paths: Decodable {
                var runtimeResourcePath: String
            }
            var paths: Paths
        }
        let targetInfo: SwiftTargetInfo
        do {
            let process = try await Subprocess.run(
                .path(swiftTool),
                arguments: ["-print-target-info"],
                output: .data(limit: .max)
            ).checkSuccess()
            targetInfo = try JSONDecoder().decode(
                SwiftTargetInfo.self,
                from: process.standardOutput
            )
        } catch {
            throw Console.Error("Failed to query Swift compiler info: \(error)")
        }

        let runtimeResourcePath = targetInfo.paths.runtimeResourcePath
        let swiftVersion = try SwiftVersion(targetInfo.compilerVersion).orThrow(
            Console.Error("Could not parse Swift version: '\(targetInfo.compilerVersion)'")
        )

        let trimmed: Substring
        if runtimeResourcePath.hasSuffix("/usr/lib/swift") {
            trimmed = runtimeResourcePath.dropLast("/usr/lib/swift".count)
        } else if runtimeResourcePath.hasSuffix("/usr/local/lib/swift") {
            trimmed = runtimeResourcePath.dropLast("/usr/local/lib/swift".count)
        } else {
            throw Console.Error("Unexpected toolchain resource path: \(runtimeResourcePath)")
        }
        let toolchainRoot = FilePath(trimmed.isEmpty ? "/" : String(trimmed))

        return Toolchain(
            toolchainRoot: toolchainRoot,
            swiftTool: swiftTool,
            swiftVersion: swiftVersion,
            runtimeResourcePath: FilePath(runtimeResourcePath),
        )
    }
}

extension DependencyValues {
    public var toolchainProvider: ToolchainProvider {
        get { self[ToolchainProvider.self] }
        set { self[ToolchainProvider.self] = newValue }
    }

    public var toolchain: Toolchain {
        get async throws {
            try await toolchainProvider.toolchain()
        }
    }
}
