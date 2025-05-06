import Foundation
import ArgumentParser
import PackLib
import XKit

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
        return try await packer.pack()
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

    func run() async throws {
        try await PackOperation(buildOptions: packOptions).run()
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

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let output = try await PackOperation(buildOptions: packOptions).run()

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

        try await installer.install(app: output)
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
