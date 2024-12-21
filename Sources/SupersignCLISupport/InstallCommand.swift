import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an ipa file to your device"
    )

    @Option(
        name: .shortAndLong,
        help: "Preferred team ID"
    ) var team: String?

    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The path to a custom app/ipa to install"
    ) var path: String

    func run() async throws {
        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()

        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = SupersignCLIDelegate()
        let installer = IntegratedInstaller(
            udid: client.udid,
            lookupMode: .only(client.connectionType),
            appleID: token.appleID,
            token: token.dsToken,
            teamID: token.teamID,
            configureDevice: false,
            storage: SupersignCLI.config.storage,
            delegate: installDelegate
        )

        do {
            try await installer.install(app: URL(fileURLWithPath: path))
            print("\nSuccessfully installed!")
        } catch {
            print("\nFailed :(")
            print("Error: \(error)")
        }
    }
}
