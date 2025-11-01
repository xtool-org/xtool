import Foundation
import XKit
import Version
import ArgumentParser
import Dependencies
import PackLib
import XUtils
import Subprocess

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "Manage the Darwin Swift SDK",
        subcommands: [
            DevSDKInstallCommand.self,
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

struct DevSDKRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the Darwin Swift SDK"
    )

    func run() async throws {
        guard let sdk = try await DarwinSDK.current() else {
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
        if let sdk = try await DarwinSDK.current() {
            print("Installed at \(sdk.bundle.path)")
        } else {
            print("Not installed")
        }
    }
}

struct DarwinSDK {
    let bundle: URL
    let version: String

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

    static func install(from path: String) async throws {
        // we can't just move into ~/.swiftpm/swift-sdks because the swiftpm directory
        // location depends on factors like $XDG_CONFIG_HOME. Rather than replicating
        // SwiftPM's logic, which may change, it's more reliable to directly invoke
        // `swift sdk install`. See: https://github.com/xtool-org/xtool/pull/40

        let url = URL(fileURLWithPath: path)
        guard DarwinSDK(bundle: url) != nil else { throw Console.Error("Invalid Darwin SDK at '\(path)'")}

        try await Subprocess.run(
            .name("swift"),
            arguments: ["sdk", "install", url.path],
            output: .discarded
        )
        .checkSuccess()
    }

    static func current() async throws -> DarwinSDK? {
        let outputString: String
        do {
            outputString = try await Subprocess.run(
                .name("swift"),
                arguments: ["sdk", "configure", "darwin", "arm64-apple-ios", "--show-configuration"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
            ?? ""
        } catch SubprocessFailure.exited {
            return nil
        }

        // should be something like
        // swiftResourcesPath: /home/user/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
        // swiftlint:disable:previous line_length
        let resourcesPathPrefix = "swiftResourcesPath: "

        guard let resourcesPath = outputString
            .split(separator: "\n")
            .first(where: { $0.hasPrefix(resourcesPathPrefix) })?
            .dropFirst(resourcesPathPrefix.count)
            else { return nil }

        var resourcesURL = URL(fileURLWithPath: String(resourcesPath))
        for _ in 0..<6 {
            resourcesURL = resourcesURL.deletingLastPathComponent()
        }

        return DarwinSDK(bundle: resourcesURL)
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
        let outputString: String?
        do {
            outputString = try await Subprocess.run(
                .name("swift"),
                arguments: ["--version"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
        } catch {
            throw Console.Error("Failed to obtain Swift version")
        }
        var output = outputString?[...] ?? ""
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
        if let sdk = try await DarwinSDK.current() {
            print("Removing existing SDK...")
            try sdk.remove()
        }

        let input = try SDKBuilder.Input(path: path)
        let arch = try ArchSelection.auto.sdkBuilderArch

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let builder = SDKBuilder(input: input, outputPath: tempDir.url.path, arch: arch)
        let sdkPath = try await builder.buildSDK()

        try await DarwinSDK.install(from: sdkPath)

        // don't destroy tempDir before this point
        withExtendedLifetime(tempDir) {}
        #endif
    }
}
