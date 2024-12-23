import Foundation
import ArgumentParser
import PackLib
import Supersign

struct DevSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up Supersign for iOS development",
        discussion: """
        Authenticates with Apple if needed, then adds the iOS SDK to SwiftPM.

        Equivalent to running `supersign auth && supersign dev sdk`
        """
    )

    func run() async throws {
        try await AuthOperation(logoutFromExisting: false).run()
        try await InstallSDKOperation().run()
    }
}

struct PackOperation {
    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Build with configuration"
        ) var configuration: BuildConfiguration = .debug
    }

    var options: Options

    @discardableResult
    func run() async throws -> URL {
        print("Planning...")

        let schema: PackSchema
        let configPath = URL(fileURLWithPath: "swiftpack.yml")
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
            configuration: options.configuration,
            options: []
        )

        let planner = Planner(
            buildSettings: buildSettings,
            schema: schema
        )
        let plan = try await planner.createPlan()

        let packer = Packer(
            buildSettings: buildSettings,
            plan: plan
        )
        return try await packer.pack()
    }
}

struct DevBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build app with SwiftPM",
        discussion: """
        This command builds the SwiftPM-based iOS app in the current directory \
        using https://github.com/kabiroberai/swiftpack
        """
    )

    @OptionGroup var packOptions: PackOperation.Options

    func run() async throws {
        try await PackOperation(options: packOptions).run()
    }
}

struct DevRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run app with SwiftPM",
        discussion: """
        This command deploys the SwiftPM-based iOS app in the current directory \
        using https://github.com/kabiroberai/swiftpack
        """
    )

    @OptionGroup var packOptions: PackOperation.Options

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let output = try await PackOperation(options: packOptions).run()

        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()
        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = SupersignCLIDelegate()
        let installer = IntegratedInstaller(
            udid: client.udid,
            lookupMode: .only(client.connectionType),
            auth: try token.authData(),
            configureDevice: false,
            storage: SupersignCLI.config.storage,
            delegate: installDelegate
        )

        defer { print() }

        try await installer.install(app: output)
    }
}

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Develop iOS apps with SwiftPM",
        subcommands: [
            DevSetupCommand.self,
            DevNewCommand.self,
            DevSDKCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: @retroactive ExpressibleByArgument {}
