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

        if try DarwinSDK.current() == nil {
            let path = try await Console.prompt("""
            Logged in! Now installing the Darwin SDK.
            
            Please download the SDK from http://developer.apple.com/download/all/?q=Xcode
            and enter the path to the downloaded Xcode.xip.
            
            Path to Xcode.xip: 
            """)

            try await InstallSDKOperation(path: path).run()
        }
    }
}

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
        let configPath = URL(fileURLWithPath: "supersign.yml")
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

        let installDelegate = SupersignCLIDelegate()
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
        abstract: "Develop iOS apps with SwiftPM",
        subcommands: [
            DevSetupCommand.self,
            DevNewCommand.self,
            DevSDKCommand.self,
            DevXcodeCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: ExpressibleByArgument {}
