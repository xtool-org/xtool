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
        let output = URL(fileURLWithPath: outputDir, isDirectory: true).appending(path: "darwin.xtoolsdk")
        let builder = SDKBuilder(input: input, output: output, arch: builderArch)
        try await builder.buildSDK()
        print("Built SDK at \(output.path). You can install it with `xtool sdk install`.")
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
        help: "Path to Xcode.xip, Xcode.app, or darwin.xtoolsdk",
        completion: .file(extensions: ["xip", "app", "xtoolsdk"])
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

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let sdkPath = tempDir.url.appending(path: "darwin.artifactbundle")

        if path.hasSuffix(".xtoolsdk") {
            print("Installing prebuilt SDK...")
            try FileManager.default.copyItem(at: URL(filePath: path), to: sdkPath)
        } else {
            // validate input before removing existing SDK
            let input = try SDKBuilder.Input(path: path)
            let arch = try ArchSelection.auto.sdkBuilderArch

            let builder = SDKBuilder(input: input, output: sdkPath, arch: arch)
            try await builder.buildSDK()
        }

        if let sdk = try await DarwinSDK.current() {
            print("Removing existing SDK...")
            try sdk.remove()
        }

        try await DarwinSDK.install(from: sdkPath.path)

        // don't destroy tempDir before this point
        withExtendedLifetime(tempDir) {}
        #endif
    }
}
