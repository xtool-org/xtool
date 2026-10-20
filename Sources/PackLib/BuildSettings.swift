import Foundation
import Subprocess
import XUtils
import Superutils

public struct BuildSettings: Sendable {
    private static let customBinDir =
        // this is the same option used by SwiftPM itself for dev builds
        ProcessInfo.processInfo.environment["SWIFTPM_CUSTOM_BIN_DIR"].map { FilePath($0) }

    public var packagePath: String
    public let configuration: BuildConfiguration
    public let triple: String
    public let customOptions: [String]

    public var sdkEnvironment: [Environment.Key: String?] {
        return [
            // xcrun passes an SDKROOT that messes with our sdk configuration
            "SDKROOT": nil,
        ]
    }

    private var configOptions: [String] {
        return [
            "--build-system", "swiftbuild",
            "--package-path", packagePath,
        ]
    }

    public init(
        configuration: BuildConfiguration,
        triple: String,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.customOptions = options
        self.triple = triple
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let _swiftURL = Task {
        try await FilePath(xcrun(["-f", "swift"]))
    }

    public static func swiftURL() async throws -> FilePath {
        try await _swiftURL.value
    }

    private static let _swiftcURL = Task {
        try await FilePath(xcrun(["-f", "swiftc"]))
    }

    public static func swiftcURL() async throws -> FilePath {
        try await _swiftcURL.value
    }
    #else
    public static func swiftURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swift")).orThrow(StringError("Got bad path for swift executable"))
    }

    public static func swiftcURL() async throws -> FilePath {
        try await FilePath(ToolRegistry.locate("swiftc")).orThrow(StringError("Got bad path for swiftc executable"))
    }
    #endif

    private static let _runtimeResourcePath = Task<String, Error> {
        struct SwiftTargetInfo: Decodable {
            struct Paths: Decodable {
                var runtimeResourcePath: String
            }
            var paths: Paths
        }
        let process = try await Subprocess.run(
            .path(try await swiftcURL()),
            arguments: ["-print-target-info"],
            output: .data(limit: .max)
        ).checkSuccess()
        let targetInfo = try JSONDecoder().decode(
            SwiftTargetInfo.self,
            from: process.standardOutput
        )
        return targetInfo.paths.runtimeResourcePath
    }

    public static func runtimeResourcePath() async throws -> String {
        try await _runtimeResourcePath.value
    }

    public static func toolchainPath() async throws -> String {
        // we can't simply return the parent of `swiftc` because the `swiftc` in PATH
        // might be a trampoline (e.g. xcrun or swiftly)
        let toolchainResourcePath = try await runtimeResourcePath()
        let trimmed: Substring
        if toolchainResourcePath.hasSuffix("/usr/lib/swift") {
            trimmed = toolchainResourcePath.dropLast("/usr/lib/swift".count)
        } else if toolchainResourcePath.hasSuffix("/usr/local/lib/swift") {
            trimmed = toolchainResourcePath.dropLast("/usr/local/lib/swift".count)
        } else {
            throw StringError("Unexpected toolchain resource path: \(toolchainResourcePath)")
        }
        return trimmed.isEmpty ? "/" : String(trimmed)
    }

    public func withPackagePath(_ path: String) -> Self {
        var copy = self
        copy.packagePath = path
        return copy
    }

    public func swiftPMInvocation(
        forTool tool: String,
        arguments: [String],
    ) async throws -> Subprocess.Configuration {
        let executable: Executable
        let baseArguments: [String]
        if let customBinDir = Self.customBinDir {
            executable = .path(customBinDir.appending("swift-\(tool)"))
            baseArguments = []
        } else {
            #if os(macOS)
            // xcrun/libxcrun (via the /usr/bin/swift trampoline) is very trigger-happy
            // to add SDKROOT=.../MacOSX.sdk to our invocations. We avoid this by
            // 1) invoking the real swift executable (located with `xcrun -f`) and
            // 2) explicitly removing SDKROOT from the env, as it may be inherited
            // through a parent process (e.g. `swift run xtool`).
            executable = .path(try await Self.swiftURL())
            #else
            executable = .name("swift")
            #endif
            baseArguments = [tool]
        }

        return Configuration(
            executable: executable,
            arguments: .init(baseArguments + configOptions + customOptions + arguments),
            environment: .inherit.updating(sdkEnvironment),
            platformOptions: .withGracefulShutDown,
        )
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release

    var swiftBuildValue: String {
        switch self {
        case .debug: "Debug"
        case .release: "Release"
        }
    }
}
