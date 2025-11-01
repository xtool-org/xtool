import Foundation
import ArgumentParser
import PackLib
import XKit
import Dependencies
import XUtils

struct PackOperation {
    struct BuildOptions: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Build with configuration"
        ) var configuration: BuildConfiguration = .debug

        init() {}

        init(configuration: BuildConfiguration) {
            self.configuration = configuration
        }
    }

    static let defaultTriple = "arm64-apple-ios"

    var triple: String?
    var buildOptions = BuildOptions(configuration: .debug)
    var xcode = false

    @discardableResult
    func run() async throws -> URL {
        print("Planning...")

        let schema: PackSchema
        let configPath = URL(fileURLWithPath: "xtool.yml")
        if FileManager.default.fileExists(atPath: configPath.path) {
            schema = try await PackSchema(url: configPath)
        } else {
            schema = .default
            print("""
            warning: Could not locate configuration file '\(configPath.path)'. Using default \
            configuration with 'com.example' organization ID.
            """)
        }

        let buildSettings = try await BuildSettings(
            configuration: buildOptions.configuration,
            triple: triple ?? Self.defaultTriple,
            options: []
        )

        let planner = Planner(
            buildSettings: buildSettings,
            schema: schema
        )
        let plan = try await planner.createPlan()

        #if os(macOS)
        if xcode {
            return try await XcodePacker(plan: plan).createProject()
        }
        #endif

        let packer = Packer(
            buildSettings: buildSettings,
            plan: plan
        )
        let bundle = try await packer.pack()

        let productsWithEntitlements = plan
            .allProducts
            .compactMap { p in p.entitlementsPath.map { (p, $0) } }
        if !productsWithEntitlements.isEmpty {
            let mapping = try await withThrowingTaskGroup(of: (URL, Entitlements).self) { group in
                for (product, path) in productsWithEntitlements {
                    group.addTask {
                        let data = try await Data(reading: URL(fileURLWithPath: path))
                        let decoder = PropertyListDecoder()
                        let entitlements = try decoder.decode(Entitlements.self, from: data)
                        return (product.directory(inApp: bundle), entitlements)
                    }
                }
                return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            print("Pseudo-signing...")
            try await Signer.first().sign(
                app: bundle,
                identity: .adhoc,
                entitlementMapping: mapping,
                progress: { _ in }
            )
        }

        return bundle
    }
}

struct DevXcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-xcode-project",
        abstract: "Generate Xcode project",
        discussion: "This option does nothing on Linux"
    )

    func run() async throws {
        try await PackOperation(xcode: true).run()
    }
}

struct DevBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build app with SwiftPM",
        discussion: """
        This command builds the SwiftPM-based iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions

    @Flag(
        help: "Output a .ipa file instead of a .app"
    ) var ipa = false

    @Option(
        help: ArgumentHelp(
            "Custom target triple to build for",
            discussion: "Defaults to '\(PackOperation.defaultTriple)'"
        )
    ) var triple: String?

    func run() async throws {
        let url = try await PackOperation(
            triple: triple,
            buildOptions: packOptions
        ).run()

        let finalURL: URL
        if ipa {
            @Dependency(\.zipCompressor) var compressor
            finalURL = url.deletingPathExtension().appendingPathExtension("ipa")
            let tmpDir = try TemporaryDirectory(name: "Payload")
            let payloadDir = tmpDir.url
            try FileManager.default.moveItem(at: url, to: payloadDir.appendingPathComponent(url.lastPathComponent))
            let ipaURL = try await compressor.compress(directory: payloadDir) { progress in
                if let progress {
                    let percent = Int(progress * 100)
                    print("\rPackaging... \(percent)%", terminator: "")
                } else {
                    print("\rPackaging...", terminator: "")
                }
            }
            print()
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: ipaURL, to: finalURL)
        } else {
            finalURL = url
        }

        print("Wrote to \(finalURL.path)")
    }
}

struct DevRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run app with SwiftPM",
        discussion: """
        This command deploys the SwiftPM-based iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions

    #if os(macOS)
    @Flag(
        name: .shortAndLong,
        help: "Target the iOS Simulator"
    ) var simulator = false

    var triple: String? {
        if simulator {
            #if arch(arm64)
            return "arm64-apple-ios-simulator"
            #elseif arch(x86_64)
            return "x86_64-apple-ios-simulator"
            #else
            #error("Unsupported architecture")
            #endif
        }
        return nil
    }
    #else
    var triple: String? { nil }
    #endif

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let output = try await PackOperation(triple: triple, buildOptions: packOptions).run()

        #if os(macOS)
        if simulator {
            try await SimInstallOperation(path: output).run()
            return
        }
        #endif

        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()
        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(
            udid: client.udid,
            lookupMode: .only(client.connectionType),
            auth: try token.authData(),
            configureDevice: false,
            delegate: installDelegate
        )

        defer { print() }

        do {
            try await installer.install(app: output)
        } catch let error as CancellationError {
            throw error
        } catch {
            print("\nError: \(error)")
            throw ExitCode.failure
        }
    }
}

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run an xtool SwiftPM project",
        subcommands: [
            DevXcodeCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: ExpressibleByArgument {}

#if os(macOS)
import Subprocess

struct SimInstallOperation {
    var path: URL

    // TODO: allow customizing this
    var simulator = "booted"

    func run() async throws {
        try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["simctl", "install", simulator, path.path],
            output: .discarded
        )
        .checkSuccess()
        print("Installed to simulator")
    }
}
#endif
