import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an ipa file to your device"
    )

    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The path to a custom app/ipa to install"
    ) var path: String

    func run() async throws {
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

        do {
            try await installer.install(app: URL(fileURLWithPath: path))
            print("\nSuccessfully installed!")
        } catch let error as CancellationError {
            throw error
        } catch {
            print("\nError: \(error)")
            throw ExitCode.failure
        }
    }
}
