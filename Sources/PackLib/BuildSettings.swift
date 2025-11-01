import Foundation
import Subprocess
import XUtils

public struct BuildSettings: Sendable {
    private static let customBinDir =
        // this is the same option used by SwiftPM itself for dev builds
        ProcessInfo.processInfo.environment["SWIFTPM_CUSTOM_BIN_DIR"].map { FilePath($0) }

    private static let envURL = URL(fileURLWithPath: "/usr/bin/env")

    public let packagePath: String
    public let configuration: BuildConfiguration
    public let triple: String
    public let sdkOptions: [String]
    public let options: [String]

    public init(
        configuration: BuildConfiguration,
        triple: String,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.options = options
        self.triple = triple

        // on macOS we don't explicitly install a Swift SDK but
        // SwiftPM vends "implicit" Darwin SDKs as of Swift 6.1,
        // i.e. we can pass `--swift-sdk arm64-apple-ios` and it
        // just works. See:
        // https://github.com/swiftlang/swift-package-manager/pull/6828
        self.sdkOptions = ["--swift-sdk", triple]
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static let swiftURL = Task {
        try await FilePath(xcrun(["-f", "swift"]))
    }
    #endif

    public func swiftPMInvocation(
        forTool tool: String,
        arguments: [String],
        packagePathOverride: String? = nil
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
            // through the `swift run pack` invocation.
            executable = .path(try await Self.swiftURL.value)
            #else
            executable = .name("swift")
            #endif
            baseArguments = [tool]
        }

        let extraArguments: [String] = [
            "--package-path", packagePathOverride ?? packagePath,
            "--configuration", configuration.rawValue,
        ]

        var rawEnv = ProcessInfo.processInfo.environment
        rawEnv.removeValue(forKey: "SDKROOT")
        let env = Dictionary(uniqueKeysWithValues: rawEnv.map {
            (Environment.Key(rawValue: $0)!, $1)
        })

        return Configuration(
            executable,
            arguments: .init(baseArguments + extraArguments + sdkOptions + options + arguments),
            environment: .custom(env),
            platformOptions: .withGracefulShutDown,
        )
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release
}
