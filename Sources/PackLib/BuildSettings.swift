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
    public let buildSystem: BuildSystem
    public let customOptions: [String]

    public var sdkOptions: [String]
    public var sdkEnvironment: [Environment.Key: String?]

    private var configOptions: [String] {
        return [
            "--configuration", configuration.rawValue,
            "--build-system", buildSystem.pmName,
            "--package-path", packagePath,
        ]
    }

    private var resolvedBaseOptions: [String] {
        configOptions + sdkOptions + customOptions
    }

    public init(
        configuration: BuildConfiguration,
        triple: String,
        buildSystem: BuildSystem = .default,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.customOptions = options
        self.triple = triple
        self.buildSystem = buildSystem

        self.sdkEnvironment = [
            // xcrun passes an SDKROOT that messes with our sdk configuration
            "SDKROOT": nil,
        ]

        switch buildSystem {
        case .swiftPM:
            // on macOS we don't explicitly install a Swift SDK but
            // SwiftPM vends "implicit" Darwin SDKs as of Swift 6.1,
            // i.e. we can pass `--swift-sdk arm64-apple-ios` and it
            // just works. See:
            // https://github.com/swiftlang/swift-package-manager/pull/6828
            self.sdkOptions = ["--swift-sdk", triple]
        case .swiftBuild:
            self.sdkOptions = ["--triple", triple]
            #if !os(macOS)
            let darwinSDK = try await DarwinSDK.current()
                .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
            self.sdkOptions += [
                "--toolset", "\(darwinSDK.bundle.path)/toolset-swb.json",
            ]
            self.sdkEnvironment.merge([
                "XCODE_EXTRA_PLATFORM_FOLDERS": "\(darwinSDK.bundle.path)/Developer/Platforms",
            ]) { $1 }
            #endif
        }
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
            executable,
            arguments: .init(baseArguments + resolvedBaseOptions + arguments),
            environment: .inherit.updating(sdkEnvironment),
            platformOptions: .withGracefulShutDown,
        )
    }

    private var baseBuildServerArguments: [String] {
        return [
            "experimental-build-server",
            "--disable-automatic-resolution",
            // this requires Swift 6.4 but we need 6.4 on Linux anyway, for the platform toolset fixes
            "--experimental-skip-acquiring-lock",
        ]
    }

    public var buildServerArguments: [String] {
        ["package"] + baseBuildServerArguments + resolvedBaseOptions
    }

    public func buildServerInvocation() async throws -> Subprocess.Configuration {
        try await swiftPMInvocation(forTool: "package", arguments: baseBuildServerArguments)
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

public enum BuildSystem: Sendable {
    case swiftPM
    case swiftBuild

    public static var `default`: Self {
        #if os(macOS)
        return .swiftBuild
        #else
        return .swiftBuild
        #endif
    }

    var pmName: String {
        switch self {
        case .swiftPM: "native"
        case .swiftBuild: "swiftbuild"
        }
    }
}
