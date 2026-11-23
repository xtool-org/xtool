import XCLIUtils
import XPIF
import Foundation
import ArgumentParser
import XKit
import Dependencies
import XUtils
import Subprocess

struct PackOperation {
    struct BuildOptions: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Build with configuration"
        ) var configuration: BuildConfiguration = .debug

        @Flag(
            name: .shortAndLong,
            help: "Verbose output"
        ) var verbose = false

        @Option(
            help: "Xcode scheme to build (overrides xtool.yml)"
        ) var scheme: String?

        init() {}

        // this is load bearing: synthesized init doesn't work with ArgumentParser
        init(
            configuration: BuildConfiguration,
            verbose: Bool = false,
            scheme: String? = nil,
        ) {
            self.configuration = configuration
            self.verbose = verbose
            self.scheme = scheme
        }
    }

    static let defaultTriple = "arm64-apple-ios"

    var triple: String?
    var buildOptions = BuildOptions(configuration: .debug)
    var hotReloadable = false

    @discardableResult
    func run() async throws -> ProjectBuildResult {
        try await run { result, _ in result }
    }

    /// Builds the project, then invokes `body` while the build coordinator is still alive.
    func run<R>(
        _ body: (ProjectBuildResult, BuildCoordinator) async throws -> R
    ) async throws -> R {
        let project = try await XToolProject.discover(start: URL(filePath: "."))

        try await EnsureSDKOperation(quiet: true).run()

        await project.tryEnsureLSPConfig()

        var description = try await project.describe(
            configuration: buildOptions.configuration,
            triple: triple ?? Self.defaultTriple,
            scheme: buildOptions.scheme
        )
        description.hotReloadable = hotReloadable
        let coordinator = try await BuildCoordinator(description: description)
        defer { await coordinator.close() }
        let result = try await ProjectBuildOperation(
            buildCoordinator: coordinator,
            verbose: buildOptions.verbose
        ).run()
        return try await body(result, coordinator)
    }
}

struct DevXcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-xcode-project",
        abstract: "Generate Xcode project"
    )

    func run() async throws {
        let project = try await XToolProject.discover(start: URL(filePath: "."))
        guard case .swiftPM(let swiftPM) = project else {
            throw Console.Error("generate-xcode-project requires a SwiftPM-based project")
        }

        let result = try await SwiftPMBuildDescriber(project: swiftPM).writeXcodeProject()

        d.out.print("Wrote to \(result.url.path)")
    }
}

struct DevBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build iOS app",
        discussion: """
        This command builds the Swift package or Xcode iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions

    @Flag(
        name: .shortAndLong,
        help: "Codesign the built app",
    ) var sign = false

    @Flag(
        name: .shortAndLong,
        help: "Output a .ipa file instead of a .app"
    ) var ipa = false

    @Option(
        help: ArgumentHelp(
            "Custom target triple to build for",
            discussion: "Defaults to '\(PackOperation.defaultTriple)'"
        )
    ) var triple: String?

    func run() async throws {
        let signingAuthToken: AuthToken?
        if sign {
            guard let token = try AuthToken.savedIfPresent() else {
                throw Console.Error("`build --sign` requires logging in with `xtool auth`")
            }
            signingAuthToken = token
        } else {
            signingAuthToken = nil
        }

        let url = try await PackOperation(
            triple: triple,
            buildOptions: packOptions
        ).run().url

        if let signingAuthToken {
            let installDelegate = XToolInstallerDelegate()
            let installer = IntegratedInstaller(
                auth: signingAuthToken.authData(),
                delegate: installDelegate
            )
            do {
                defer {
                    await installDelegate.finish()
                    d.out.print()
                }
                try await installer.signInPlace(app: url)
            } catch let error as CancellationError {
                throw error
            } catch {
                d.out.print("Error: \(error)")
                throw ExitCode.failure
            }
        }

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
                    d.out.print("\rPackaging... \(percent)%", terminator: "")
                } else {
                    d.out.print("\rPackaging...", terminator: "")
                }
            }
            d.out.print()
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: ipaURL, to: finalURL)
        } else {
            finalURL = url
        }

        d.out.print("Wrote to \(finalURL.path)")
    }
}

struct DevRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run iOS app",
        discussion: """
        This command deploys the Swift package or Xcode iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions

    @Flag(
        name: [.customShort("s"), .customLong("simulator")],
        help: "Target the iOS Simulator (macOS only)",
    ) var explicitSimulator = false

    @Flag(
        inversion: .prefixedEnableDisable,
        help: "Attach console when running on the simulator (default: true)",
    ) var console: Bool?

    @Flag(
        name: .shortAndLong,
        help: "Hot reload Swift files as they're edited (implies --simulator)",
    ) var watch = false

    var simulator: Bool {
        explicitSimulator || watch
    }

    @Option(help: .hidden) var xloadPath: String?

    #if os(macOS)
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
        let operation = PackOperation(
            triple: triple,
            buildOptions: packOptions,
            hotReloadable: watch,
        )

        #if os(macOS)
        if simulator {
            if watch {
                // keep the coordinator alive: the hot reloader uses it to get compiler args
                try await operation.run { output, coordinator in
                    let hotReloader = try await HotReloader(coordinator: coordinator, xloadPath: xloadPath)
                    try await SimInstallOperation(
                        path: output.url,
                        bundleID: output.bundleID,
                        console: console != false,
                        hotReloader: hotReloader,
                    ).run()
                }
            } else {
                let output = try await operation.run()
                try await SimInstallOperation(
                    path: output.url,
                    bundleID: output.bundleID,
                    console: console != false,
                ).run()
            }
            return
        }
        #endif

        let output = try await operation.run()

        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()
        d.out.print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(
            auth: token.authData(),
            delegate: installDelegate
        )

        defer {
            await installDelegate.finish()
            d.out.print()
        }

        do {
            try await installer.install(
                app: output.url,
                udid: client.udid,
                lookupMode: .only(client.connectionType),
                configureDevice: false,
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            d.out.print("\nError: \(error)")
            throw ExitCode.failure
        }
    }

    func validate() throws {
        #if !os(macOS)
        guard !simulator else {
            throw ValidationError("`--simulator` is only supported on macOS")
        }
        #endif

        if console == true && !simulator {
            throw ValidationError("`--enable-console` is only supported when targeting the simulator")
        }

        if watch && packOptions.configuration != .debug {
            throw ValidationError("`--watch` is only supported with the debug configuration")
        }

        if xloadPath != nil && !watch {
            throw ValidationError("`--xload-path` requires `--watch`")
        }
    }
}

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run a Swift package or Xcode project",
        subcommands: [
            DevXcodeCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
            DevBSPCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: ExpressibleByArgument {}

#if os(macOS)
import Subprocess

struct SimInstallOperation {
    var path: URL
    var bundleID: String
    var console: Bool
    var hotReloader: HotReloader?

    // TODO: allow customizing this
    var simulator = "booted"

    func run() async throws {
        let simctlRaw = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["-f", "simctl"],
            output: .string(limit: .max)
        ).checkSuccess().standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let simctl = FilePath(simctlRaw)

        try await Subprocess.run(
            .path(simctl),
            arguments: ["install", simulator, path.path],
            output: .discarded
        )
        .checkSuccess()

        d.out.print("Installed to simulator")

        var launchFlags: [String] = [
            "--terminate-running-process",
        ]
        if console {
            launchFlags.append("--console-pty")
        }

        try await withThrowingDiscardingTaskGroup { group in
            if let hotReloader {
                group.addTask { try await hotReloader.watch() }
            }

            try await Subprocess.run(
                .path(simctl),
                arguments: Arguments(["launch"] + launchFlags + [simulator, bundleID]),
                environment: .inherit.updating(hotReloader?.launchEnvironment ?? [:]),
                platformOptions: .withGracefulShutDown,
                output: .xtoolOutput(),
                error: .xtoolError(),
            )
            .checkSuccess()

            // With the console attached, `launch` returns once the app exits, so we're done.
            // Otherwise it returns immediately, so keep watching until we're interrupted.
            if console { group.cancelAll() }
        }
    }
}
#endif
