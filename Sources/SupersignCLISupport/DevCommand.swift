import Foundation
import ArgumentParser
import PackLib
import Supersign

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run apps with SwiftPM",
        discussion: """
        This command deploys the SwiftPM-based iOS app in the current directory \
        using https://github.com/kabiroberai/swiftpack
        """
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    @Option(
        name: .shortAndLong,
        help: "Build with configuration"
    ) var configuration: BuildConfiguration = .debug

    @Option(
        name: .shortAndLong,
        help: "Preferred team ID"
    ) var team: String?

    func run() async throws {
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
            configuration: configuration,
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
        let output = try await packer.pack()

        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()
        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = SupersignCLIDelegate(preferredTeam: team.map(DeveloperServicesTeam.ID.init))
        let installer = IntegratedInstaller(
            udid: client.udid,
            lookupMode: .only(client.connectionType),
            appleID: token.appleID,
            token: token.dsToken,
            configureDevice: false,
            storage: SupersignCLI.config.storage,
            delegate: installDelegate
        )

        try await installer.install(app: output)
    }
}

extension BuildConfiguration: @retroactive ExpressibleByArgument {}
