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
        buildSystem: BuildSystem? = nil,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.customOptions = options
        self.triple = triple
        let target = try TargetTriple(triple)
        // SwiftBuild has not been validated for macOS cross-compilation. Keep the
        // established iOS default, and use the proven SwiftPM backend for macOS.
        self.buildSystem = if let buildSystem {
            buildSystem
        } else if target.platform == .macOS {
            .swiftPM
        } else {
            try await .default()
        }

        self.sdkEnvironment = [
            // xcrun passes an SDKROOT that messes with our sdk configuration
            "SDKROOT": nil,
        ]

        switch self.buildSystem {
        case .swiftPM:
            // on macOS we don't explicitly install a Swift SDK but
            // SwiftPM vends "implicit" Darwin SDKs as of Swift 6.1,
            // i.e. we can pass `--swift-sdk arm64-apple-ios` and it
            // just works. See:
            // https://github.com/swiftlang/swift-package-manager/pull/6828
            self.sdkOptions = ["--swift-sdk", Self.sdkIdentity(for: target)]
            if target.deploymentTarget != nil {
                self.sdkOptions += ["--triple", Self.compilerTriple(for: target)]
            }
        case .swiftBuild:
            guard target.platform != .macOS else {
                throw StringError("macOS builds currently require the SwiftPM backend; SwiftBuild is not validated")
            }
            self.sdkOptions = ["--triple", triple]
            #if !os(macOS)
            let darwinSDK = try DarwinSDK.current()
                .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
            self.sdkOptions += [
                "--toolset", "\(darwinSDK.bundle.path)/toolset-swb.json",
            ]
            self.sdkEnvironment.merge([
                "XCODE_EXTRA_PLATFORM_FOLDERS": "\(darwinSDK.bundle.path)/Developer/Platforms",
                // SWB looks for dsymutil in the PATH. Other stuff (lld, libtool) is handled by toolset-swb.json.
                "PATH": "\(darwinSDK.bundle.path)/toolset/bin:\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
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

    public func withPackagePath(_ path: String) -> Self {
        var copy = self
        copy.packagePath = path
        return copy
    }

    /// An SDK's unversioned identity selects its tools and libraries; the
    /// compiler triple separately carries the plan's effective minimum OS.
    public func withTarget(_ target: ResolvedTarget) throws -> Self {
        guard target.triple == triple else {
            throw StringError("Build settings target differs from the resolved plan")
        }
        var copy = self
        switch buildSystem {
        case .swiftPM:
            copy.sdkOptions = ["--swift-sdk", Self.sdkIdentity(for: try TargetTriple(triple)),
                               "--triple", target.compilerTriple]
        case .swiftBuild:
            // Keep the initializer's triple and toolset. SwiftBuild applies a versioned triple's
            // deployment target to every package, so dependencies would compile for the app's
            // minimum instead of their own; the wrapper package's `platforms` carries the plan's.
            break
        }
        return copy
    }

    private static func sdkIdentity(for target: TargetTriple) -> String {
        switch target.platform {
        case .iOS: "\(target.architecture)-apple-ios"
        case .iOSSimulator: "\(target.architecture)-apple-ios-simulator"
        case .macOS: "\(target.architecture)-apple-macosx"
        }
    }

    private static func compilerTriple(for target: TargetTriple) -> String {
        let version = target.deploymentTarget ?? target.platform.minimumDeploymentTarget
        return switch target.platform {
        case .iOS: "\(target.architecture)-apple-ios\(version)"
        case .iOSSimulator: "\(target.architecture)-apple-ios\(version)-simulator"
        case .macOS: "\(target.architecture)-apple-macosx\(version)"
        }
    }

    /// LLD otherwise records the deployment version as the SDK version on Linux.
    /// Keep this target-only: SwiftPM CLI linker flags also affect host macros.
    func macOSLinkerArguments() async throws -> [String] {
        let sdkRoot: URL
        if let custom = swiftSDKsPath {
            sdkRoot = try Self.macOSSDKRoot(in: URL(fileURLWithPath: custom), architecture: try TargetTriple(triple).architecture)
        } else {
            #if os(macOS)
            sdkRoot = URL(fileURLWithPath: try await Self.xcrun(["--sdk", "macosx", "--show-sdk-path"]))
            #else
            guard let sdk = try DarwinSDK.current() else {
                throw StringError("No Darwin SDK configured. Please run `xtool setup`.")
            }
            sdkRoot = try Self.macOSSDKRoot(in: sdk.bundle.deletingLastPathComponent(),
                                            architecture: try TargetTriple(triple).architecture)
            #endif
        }
        let data = try Data(contentsOf: sdkRoot.appendingPathComponent("SDKSettings.json"))
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = settings["Version"] as? String else {
            throw StringError("Missing SDK version in \(sdkRoot.path)/SDKSettings.json")
        }
        try TargetTriple.validateVersion(version)
        let tripleIndex = sdkOptions.firstIndex(of: "--triple")
        let target = try TargetTriple(tripleIndex.map { sdkOptions[$0 + 1] } ?? triple)
        return ["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker",
                target.deploymentTarget ?? target.platform.minimumDeploymentTarget, "-Xlinker", version]
    }

    private var swiftSDKsPath: String? {
        for (index, option) in customOptions.enumerated() {
            if option.hasPrefix("--swift-sdks-path=") { return String(option.dropFirst("--swift-sdks-path=".count)) }
            if option == "--swift-sdks-path", index + 1 < customOptions.count { return customOptions[index + 1] }
        }
        return nil
    }

    private static func macOSSDKRoot(in directory: URL, architecture: String) throws -> URL {
        let bundles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "artifactbundle" }
        var roots: [URL] = []
        for bundle in bundles {
            let metadata = bundle.appendingPathComponent("swift-sdk.json")
            guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
            let data = try Data(contentsOf: metadata)
            guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let triples = settings["targetTriples"] as? [String: [String: Any]],
                  let path = triples["\(architecture)-apple-macosx"]?["sdkRootPath"] as? String else { continue }
            roots.append(URL(fileURLWithPath: path, relativeTo: bundle).standardizedFileURL)
        }
        guard roots.count == 1, let root = roots.first else {
            throw StringError("Expected exactly one macOS Swift SDK in \(directory.path); found \(roots.count)")
        }
        return root
    }

    /// Reject combinations whose failure is already known, before a builder
    /// creates its wrapper or starts resolving/compiling a package.
    func validateProductBuild(for target: ResolvedTarget, hostIsMacOS: Bool) throws {
        // `init` already rejects SwiftBuild for macOS, and `withTarget` a different triple.
        guard target.platform != .macOS || hostIsMacOS || configuration == .release else {
            throw StringError("macOS Debug builds on Linux need unavailable codesign support; use --configuration release")
        }
        // Build options may tune compilation, but cannot silently replace the
        // already-resolved target, product, backend, or package.
        let reserved = ["--triple", "--swift-sdk", "--sdk", "--arch", "--destination", "--configuration", "-c",
                        "--build-system", "--package-path", "--product", "--target", "--show-bin-path", "--build-tests"]
        for option in customOptions {
            if reserved.contains(where: { option == $0 || option.hasPrefix("\($0)=") }) {
                throw StringError("Build option '\(option)' conflicts with the resolved product build settings")
            }
        }
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

        var options = resolvedBaseOptions
        var environment = sdkEnvironment
        #if !os(macOS)
        let target = try TargetTriple(triple)
        if buildSystem == .swiftPM && target.platform == .macOS {
            let directory: URL
            if let path = swiftSDKsPath {
                directory = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                directory = try DarwinSDK.current()
                    .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
                    .bundle.deletingLastPathComponent()
            }
            let cache = URL(fileURLWithPath: packagePath, isDirectory: true).appendingPathComponent(".build/xtool-sdk")
            let destination = try SwiftSDKConfiguration.destination(in: directory, for: target, cacheDirectory: cache)
            let compilerTriple = sdkOptions.firstIndex(of: "--triple").map { sdkOptions[$0 + 1] }
                ?? Self.compilerTriple(for: target)
            options = configOptions + ["--destination", destination.url.path, "--triple", compilerTriple] + customOptions
            environment["PATH"] = (destination.toolSearchPaths + [ProcessInfo.processInfo.environment["PATH"] ?? ""])
                .joined(separator: ":")
        }
        #endif
        return Configuration(
            executable: executable,
            arguments: .init(baseArguments + options + arguments),
            environment: .inherit.updating(environment),
            platformOptions: .withGracefulShutDown,
        )
    }

    // loosely based on
    // https://github.com/swiftlang/sourcekit-lsp/blob/c55899a/Sources/BuildServerIntegration/ExternalBuildServerAdapter.swift#L92
    private var baseBuildServerArguments: [String] {
        return [
            "experimental-build-server",
            "--disable-automatic-resolution",
            "--scratch-path", ".build/index-build",
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

    public static func `default`() async throws -> Self {
        if try await SwiftVersion.current.supportsSwiftBuild {
            return .swiftBuild
        } else {
            return .swiftPM
        }
    }

    var pmName: String {
        switch self {
        case .swiftPM: "native"
        case .swiftBuild: "swiftbuild"
        }
    }
}
