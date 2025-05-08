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
            DevSDKRemoveCommand.self,
            DevSDKBuildCommand.self,
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
        guard let sdk = try DarwinSDK.current() else {
            throw Console.Error("Cannot remove SDK: no Darwin SDK installed")
        }
        try sdk.remove()
        print("Uninstalled SDK")
    }
}

struct DarwinSDK {
    private static let sdksDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".swiftpm/swift-sdks")
        .resolvingSymlinksInPath()

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

    @discardableResult
    static func install(movingFrom path: String) throws -> DarwinSDK {
        let url = URL(fileURLWithPath: path)
        guard DarwinSDK(bundle: url) != nil else { throw Console.Error("Invalid Darwin SDK at '\(path)'")}
        let targetURL = sdksDir.appendingPathComponent("darwin.artifactbundle")
        if targetURL.exists {
            throw Console.Error("Darwin SDK is already installed at '\(targetURL.path)'. Please remove it first.")
        }
        try? FileManager.default.createDirectory(at: sdksDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: targetURL)
        guard let sdk = DarwinSDK(bundle: targetURL) else {
            throw Console.Error("Darwin SDK failed to install")
        }
        return sdk
    }

    static func current() throws -> DarwinSDK? {
        let sdks = (try? FileManager.default.contentsOfDirectory(at: sdksDir, includingPropertiesForKeys: nil)) ?? []
        let darwinSDKs = sdks.compactMap { DarwinSDK(bundle: $0) }
        switch darwinSDKs.count {
        case 0:
            return nil
        case 1:
            return darwinSDKs[0]
        default:
            throw Console.Error("""
            You have multiple copies of the Darwin SDK installed. Please delete all but one to continue.
            \(darwinSDKs.map { "- \($0.bundle.path) (version '\($0.version)')" }.joined(separator: "\n"))
            """)
        }
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
        if let sdk = try DarwinSDK.current() {
            print("Removing existing SDK...")
            try sdk.remove()
        }

        let input = try SDKBuilder.Input(path: path)
        let arch = try ArchSelection.auto.sdkBuilderArch

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let builder = SDKBuilder(input: input, outputPath: tempDir.url.path, arch: arch)
        let sdkPath = try await builder.buildSDK()

        try DarwinSDK.install(movingFrom: sdkPath)

        // don't destroy tempDir before this point
        withExtendedLifetime(tempDir) {}

        print("Installed darwin.artifactbundle")
        #endif
    }
}
