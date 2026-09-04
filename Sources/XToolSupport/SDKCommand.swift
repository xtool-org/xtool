import Foundation
import XKit
import ArgumentParser
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
            DevSDKMountDDICommand.self,
        ],
        defaultSubcommand: DevSDKInstallCommand.self
    )
}

struct DevSDKMountDDICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount-ddi",
        abstract: "Extract a Developer Disk Image from Xcode.xip/Xcode.app and mount it on a connected device",
        discussion: """
        Locates the DeviceSupport folder matching the connected device's iOS version inside the \
        given Xcode.xip/Xcode.app (real Xcode ships these under Contents/Developer/Platforms/\
        iPhoneOS.platform/DeviceSupport/<version>/), extracts DeveloperDiskImage.dmg + its \
        signature, and mounts it -- unmounting whatever Developer image is currently mounted \
        first, if any, so this can be used to replace a stale or mismatched DDI.
        """
    )

    @Argument(
        help: "Path to Xcode.xip or Xcode.app",
        completion: .file(extensions: ["xip", "app"])
    )
    var path: String

    @Option(
        help: ArgumentHelp(
            "DeviceSupport version to use instead of the connected device's own version",
            discussion: """
            Newer Xcode releases don't ship a DeviceSupport folder for every historical iOS \
            version -- pass e.g. '16.4' to use the closest available one if there's no exact \
            match for the device's own version.
            """
        )
    )
    var version: String?

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let client = try await connectionOptions.client()
        let connection = try await Connection.connection(
            forUDID: client.udid,
            preferences: .init(lookupMode: .only(client.connectionType))
        ) { _ in }
        let versionPrefix: String
        if let version {
            versionPrefix = version
        } else {
            let productVersion = try await connection.client.value(
                ofType: String.self, forDomain: nil, key: "ProductVersion"
            )
            versionPrefix = productVersion.split(separator: ".").prefix(2).joined(separator: ".")
        }

        let cacheDir = try TemporaryDirectory(name: "DDIMount-\(versionPrefix)")

        print("Extracting Developer Disk Image for iOS \(versionPrefix) from '\(path)'...")
        let result = try await DDIExtractor.extract(
            xcodePath: path,
            versionPrefix: versionPrefix,
            outputDir: cacheDir.url
        )
        print("Extracted to \(result.dmg.path)")

        let mounter = try await DDIMounter(connection: connection)
        if try mounter.isMounted() {
            print("Unmounting existing Developer Disk Image...")
            // MobileImageMounterClient doesn't wrap unmount (mobile_image_mounter_unmount_image);
            // ideviceimagemounter (same libimobiledevice suite already relied on elsewhere for
            // interactive debugging this session) does, and is the more battle-tested path here.
            try await Subprocess.run(
                .name("ideviceimagemounter"),
                arguments: ["-u", client.udid, "unmount", "/Developer"],
                output: .discarded
            )
            .checkSuccess()
        }

        print("Mounting new Developer Disk Image...")
        try await mounter.mountIfNeeded(
            local: .init(dmg: result.dmg, signature: result.signature),
            fetchRemote: {
                throw Console.Error("Internal error: extracted DDI not found locally")
            }
        ) { progress in
            print("\r[Mounting] \(Int(progress * 100))%", terminator: "")
            fflush(stdoutSafe)
        }
        print("\nMounted Developer Disk Image for iOS \(versionPrefix) on \(client.deviceName).")

        withExtendedLifetime(cacheDir) {}
    }
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

struct DarwinSDK {
    let bundle: URL
    let version: String

    init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ["darwin.xtoolsdk", "darwin.artifactbundle"].contains(bundle.lastPathComponent) {
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

        try await addHostClangResourceDir(to: url)

        try await Subprocess.run(
            .name("swift"),
            arguments: ["sdk", "install", url.path],
            output: .discarded
        )
        .checkSuccess()
    }

    private static func addHostClangResourceDir(to sdk: URL) async throws {
        let clangURL = try await ToolRegistry.locate("clang")
        let process = try await Subprocess.run(
            .path(FilePath(clangURL.path)),
            arguments: ["-print-resource-dir"],
            output: .string(limit: .max)
        ).checkSuccess()
        let output = process.standardOutput ?? ""
        let hostClangResources = URL(filePath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        let hostInclude = hostClangResources.appending(path: "include")
        let sdkInclude = sdk.appending(path: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include")
        try FileManager.default.copyItem(at: hostInclude, to: sdkInclude)
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
