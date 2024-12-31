import Foundation

public struct BuildSettings: Sendable {
    private static let customBinDir =
        // this is the same option used by SwiftPM itself for dev builds
        ProcessInfo.processInfo.environment["SWIFTPM_CUSTOM_BIN_DIR"].map { URL(fileURLWithPath: $0) }

    private static let envURL = URL(fileURLWithPath: "/usr/bin/env")

    public let packagePath: String
    public let configuration: BuildConfiguration
    public let triple: String
    public let sdkOptions: [String]
    public let options: [String]

    public init(
        configuration: BuildConfiguration,
        packagePath: String = ".",
        options: [String] = []
    ) async throws {
        self.packagePath = packagePath
        self.configuration = configuration
        self.options = options

        // TODO: allow customizing?
        self.triple = "arm64-apple-ios"

        #if os(macOS)
        let sdkPath = try await Self.xcrun(["-show-sdk-path", "--sdk", "iphoneos"])
        self.sdkOptions = [
            "--triple", triple,
            "--sdk", sdkPath,
        ]
        #else
        self.sdkOptions = [
            "--swift-sdk", triple
        ]
        #endif
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        let xcrun = Process()
        let pipe = Pipe()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = arguments
        xcrun.standardOutput = pipe
        try await xcrun.runUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let swiftURL = Task {
        try await URL(fileURLWithPath: xcrun(["-f", "swift"]))
    }
    #endif

    public func swiftPMInvocation(
        forTool tool: String,
        arguments: [String],
        packagePathOverride: String? = nil
    ) async throws -> Process {
        let process = Process()

        let baseArguments: [String]
        if let customBinDir = Self.customBinDir {
            process.executableURL = customBinDir.appendingPathComponent("swift-\(tool)")
            baseArguments = []
        } else {
            #if os(macOS)
            // xcrun/libxcrun (via the /usr/bin/swift trampoline) is very trigger-happy
            // to add SDKROOT=.../MacOSX.sdk to our invocations. We avoid this by
            // 1) invoking the real swift executable (located with `xcrun -f`) and
            // 2) explicitly removing SDKROOT from the env, as it may be inherited
            // through the `swift run pack` invocation.
            process.executableURL = try await Self.swiftURL.value
            #else
            process.executableURL = try await ToolRegistry.locate("swift")
            #endif
            baseArguments = [tool]
        }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SDKROOT")
        process.environment = env
        process.arguments = baseArguments + [
            "--package-path", packagePathOverride ?? packagePath,
            "--configuration", configuration.rawValue,
        ] + sdkOptions + options + arguments
        return process
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release
}
