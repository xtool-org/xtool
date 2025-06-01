import Foundation
import XKit
import Version
import ArgumentParser
import Dependencies
import PackLib

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "Manage the Darwin Swift SDK",
        subcommands: [
            DevSDKInstallCommand.self,
            DevSDKUpdateCommand.self,
            DevSDKRemoveCommand.self,
            DevSDKBuildCommand.self,
            DevSDKStatusCommand.self,
        ],
        defaultSubcommand: DevSDKInstallCommand.self
    )
}

struct DevSDKBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the Darwin SDK from Xcode.xip"
    )

    @Argument(
        help: "Path to Xcode.xip or Xcode.app",
        completion: .file(extensions: ["xip", "app"])
    )
    var path: String

    @Argument(
        help: "Output directory"
    )
    var outputDir: String

    @Option(
        help: ArgumentHelp(
            "The architecture of the Linux host the SDK is being built for.",
            discussion: "Defaults to 'auto', which attempts to match the current host architecture."
        )
    ) var arch: ArchSelection = .auto

    func run() async throws {
        let builderArch = try arch.sdkBuilderArch
        let input = try SDKBuilder.Input(path: path)
        let builder = SDKBuilder(input: input, outputPath: outputDir, arch: builderArch)
        let sdkPath = try await builder.buildSDK()
        print("Built SDK at \(sdkPath)")
    }
}

enum ArchSelection: String, ExpressibleByArgument {
    case auto
    case x86_64
    case arm64

    var sdkBuilderArch: SDKBuilder.Arch {
        get throws {
            switch self {
            case .auto:
                #if arch(arm64)
                .aarch64
                #elseif arch(x86_64)
                .x86_64
                #else
                throw Console.Error("Could not auto-detect target architecture. Please specify one with '--arch'.")
                #endif
            case .arm64: .aarch64
            case .x86_64: .x86_64
            }
        }
    }
}

struct DevSDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Darwin Swift SDK"
    )

    @Argument(
        help: "Path to Xcode.xip or Xcode.app",
        completion: .file(extensions: ["xip", "app"])
    )
    var path: String

    func run() async throws {
        try await InstallSDKOperation(path: path).run()
    }
}

struct DevSDKUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update the installed Darwin Swift SDK"
    )

    func run() async throws {
        try await UpdateSDKOperation().run()
    }
}

struct DevSDKRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the Darwin Swift SDK"
    )

    func run() async throws {
        guard let sdk = DarwinSDK.current() else {
            throw Console.Error("Cannot remove SDK: no Darwin SDK installed")
        }
        try sdk.remove()
        print("Uninstalled SDK")
    }
}

struct DevSDKStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get the status of the Darwin Swift SDK"
    )

    func run() async throws {
        if let sdk = DarwinSDK.current() {
            print("Installed at \(sdk.bundle.path)")
        } else {
            print("Not installed")
        }
    }
}

struct DarwinSDK {
    var bundle: URL
    var version: String

    private static let swiftPMConfigDir: URL = {
        // https://github.com/swiftlang/swift-package-manager/pull/7386
        if let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            URL(fileURLWithPath: configHome)
                .appendingPathComponent("swiftpm")
        } else {
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".swiftpm")
        }
    }()

    private static let swiftSDKsDir = Self.swiftPMConfigDir.appendingPathComponent("swift-sdks")

    init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if bundle.lastPathComponent == "darwin.artifactbundle" {
            self.version = "unknown"
        } else {
            return nil
        }
    }

    mutating func install() throws {
        let sdksDir = Self.swiftSDKsDir
        try? FileManager.default.createDirectory(
            at: sdksDir,
            withIntermediateDirectories: true
        )

        let destination = sdksDir.appendingPathComponent("darwin.artifactbundle")
        try FileManager.default.moveItem(at: bundle, to: destination)
        bundle = destination
    }

    static func current() -> DarwinSDK? {
        let bundle = swiftSDKsDir.appendingPathComponent("darwin.artifactbundle")
        guard bundle.dirExists else { return nil }
        return DarwinSDK(bundle: bundle)
    }

    func isUpToDate() -> Bool {
        true
    }

    func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }
}

private enum SwiftVersion {}
extension SwiftVersion {
    static func current() async throws -> Version {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let swift = Process()
        swift.executableURL = try await ToolRegistry.locate("swift")
        swift.arguments = ["--version"]
        swift.standardOutput = outPipe
        swift.standardError = errPipe
        async let outputTask = outPipe.fileHandleForReading.readToEnd()
        do {
            try await swift.runUntilExit()
        } catch is Process.Failure {
            throw Console.Error("Failed to obtain Swift version")
        }
        let outputData = try await outputTask
        var output = String(decoding: outputData ?? Data(), as: UTF8.self)[...]
        if output.hasPrefix("Apple ") {
            output = output.dropFirst("Apple ".count)
        }
        guard output.hasPrefix("Swift version ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output.dropFirst("Swift version ".count)
        guard let space = output.firstIndex(of: " ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output[..<space]
        guard let version = Version(tolerant: output) else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        return version
    }
}

struct InstallSDKOperation {
    let path: String

    func run() async throws {
        #if os(macOS)
        print("Skipping SDK install; the iOS SDK ships with Xcode on macOS")
        #else
        let input = try SDKBuilder.Input(path: path)
        let arch = try ArchSelection.auto.sdkBuilderArch

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")

        if let existing = DarwinSDK.current() {
            print("Removing existing SDK...")
            try existing.remove()
        }

        let builder = SDKBuilder(input: input, outputPath: tempDir.url.path, arch: arch)
        let sdkPath = try await builder.buildSDK()

        guard var sdk = DarwinSDK(bundle: URL(fileURLWithPath: sdkPath)) else {
            throw Console.Error("Invalid Darwin SDK at '\(sdkPath)'")
        }
        try sdk.install()

        print("Installed SDK")

        // don't destroy tempDir before this point
        withExtendedLifetime(tempDir) {}
        #endif
    }
}

struct UpdateSDKOperation {
    func run() async throws {
        #if os(macOS)
        print("Skipping SDK install; the iOS SDK ships with Xcode on macOS")
        #else
        guard let existing = DarwinSDK.current() else {
            throw Console.Error("Could not locate existing SDK; cannot perform update.")
        }
        let xcode = existing.bundle.appendingPathComponent("Xcode.app")

        let input = try SDKBuilder.Input(path: xcode.path, update: true)
        let arch = try ArchSelection.auto.sdkBuilderArch

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let builder = SDKBuilder(input: input, outputPath: tempDir.url.path, arch: arch)
        let sdkPath = try await builder.buildSDK()
        let sdkURL = URL(fileURLWithPath: sdkPath)

        guard var sdk = DarwinSDK(bundle: sdkURL) else {
            throw Console.Error("Invalid Darwin SDK at '\(sdkPath)'")
        }

        try FileManager.default.moveItem(
            at: xcode,
            to: sdkURL.appendingPathComponent("Xcode.app")
        )
        try existing.remove()
        try sdk.install()

        print("Updated SDK")

        withExtendedLifetime(tempDir) {}
        #endif
    }
}
