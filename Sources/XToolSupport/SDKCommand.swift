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
        let output = URL(fileURLWithPath: outputDir, isDirectory: true).appending(path: "darwin.xtoolsdk")
        let builder = SDKBuilder(input: input, output: output, arch: builderArch, mode: .buildSlim)
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

    @Flag(
        help: "Install a slim SDK (uses less disk space). Slim SDKs cannot be updated in place."
    )
    var slim = false

    func run() async throws {
        try await InstallSDKOperation(path: path, slim: slim).run()
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
        guard let sdk = try DarwinSDK.current() else {
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
        if let sdk = try DarwinSDK.current() {
            print("Darwin SDK is installed")
            print("  Path: \(sdk.bundle.path)")
            print("  Flavor: \(sdk.flavor)")
            print("  Version: \(sdk.version)")
        } else {
            print("Not installed")
        }
    }
}

extension DarwinSDK {
    func isUpToDate() -> Bool {
        version == SDKBuilder.currentSDKVersion
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

struct EnsureSDKOperation {
    let quiet: Bool

    func run() async throws {
        #if os(macOS)
        if !quiet {
            print("Skipping Darwin SDK setup since we're on macOS.")
        }
        #else
        let sdk = try DarwinSDK.current()
        switch sdk.map({ ($0.isUpToDate(), $0.flavor) }) {
        case (true, _)?: // swiftlint:disable:this optional_enum_case_matching
            if !quiet {
                print("Darwin SDK is up to date.")
            }
        case (false, .slim)?: // swiftlint:disable:this optional_enum_case_matching
            throw Console.Error("""
            Darwin SDK is out of date, and was installed in 'slim' mode.

            Slim SDKs take less disk space, but can't be auto-updated.
            Please install a new SDK with
                xtool sdk install [--slim]
            """)
        case (false, .normal)?: // swiftlint:disable:this optional_enum_case_matching
            print("Darwin SDK is out of date. Rebuilding...")
            try await UpdateSDKOperation().run()
        case (false, .legacy)?: // swiftlint:disable:this optional_enum_case_matching
            print("""
            Darwin SDK is incompatible: built with an older version of xtool.

            Requesting re-install. This is a one-time rebuild; after this,
            xtool will be able to resolve incompatibilities automatically.

            """)
            try await generateSDK()
        case nil:
            print("Now generating the Darwin SDK.\n")
            try await generateSDK()
        }

        func generateSDK() async throws {
            let path = try await Console.prompt("""
            Please download Xcode from http://developer.apple.com/download/all/?q=Xcode
            and enter the path to the downloaded Xcode.xip.

            Path to Xcode.xip: \("" /* pacify swiftlint trailing_whitespace */)
            """)

            let expanded = (path as NSString).expandingTildeInPath

            try await InstallSDKOperation(path: expanded).run()
        }
        #endif
    }
}

struct InstallSDKOperation {
    let path: String
    let slim: Bool

    init(path: String, slim: Bool = false) {
        self.path = path
        self.slim = slim
    }

    func run() async throws {
        #if os(macOS)
        print("Skipping SDK install; the iOS SDK ships with Xcode on macOS")
        #else

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let sdkPath = tempDir.url.appending(path: "darwin.artifactbundle")

        if path.hasSuffix(".xtoolsdk") {
            print("Installing prebuilt SDK...")
            try await FileManager.default.copyItem(at: URL(filePath: path), to: sdkPath, preserveOwner: false)
        } else {
            // validate input before removing existing SDK
            let input = try SDKBuilder.Input(path: path)
            let arch = try ArchSelection.auto.sdkBuilderArch

            let mode: SDKBuilder.Mode = slim ? .buildSlim : .buildNormal
            let builder = SDKBuilder(input: input, output: sdkPath, arch: arch, mode: mode)
            try await builder.buildSDK()
        }

        if let sdk = try DarwinSDK.current() {
            print("Removing existing SDK...")
            try sdk.remove()
        }

        try await DarwinSDK.install(from: sdkPath.path)

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
        guard let existing = try DarwinSDK.current() else {
            throw Console.Error("Could not locate existing SDK; cannot perform update.")
        }
        let xcode = existing.bundle.appendingPathComponent("Xcode.app")
        guard xcode.dirExists else {
            // This includes prebuilt .xtoolsdk installs and installs created with --slim.
            throw Console.Error("""
            The installed SDK was built in 'slim' mode and cannot be updated in place. \
            Please install a new copy with `xtool sdk install`.
            """)
        }

        let input = try SDKBuilder.Input(path: xcode.path)
        let arch = try ArchSelection.auto.sdkBuilderArch

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let sdkURL = tempDir.url.appending(path: "darwin.artifactbundle")
        let builder = SDKBuilder(input: input, output: sdkURL, arch: arch, mode: .update)
        try await builder.buildSDK()

        guard DarwinSDK(bundle: sdkURL) != nil else {
            throw Console.Error("Invalid Darwin SDK at '\(sdkURL.path)'")
        }

        try FileManager.default.moveItem(
            at: xcode,
            to: sdkURL.appendingPathComponent("Xcode.app")
        )
        try existing.remove()
        try await DarwinSDK.install(from: sdkURL.path)

        print("Updated SDK")

        withExtendedLifetime(tempDir) {}
        #endif
    }
}
