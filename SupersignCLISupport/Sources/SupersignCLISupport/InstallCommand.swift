import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an ipa file to your device"
    )

    @Option(name: .shortAndLong) var account: String?
    @Option(
        name: .shortAndLong,
        help: "Preferred team ID"
    ) var team: String?
    @OptionGroup @FromArguments var client: ConnectionManager.Client

    @Argument(
        help: "The path to a custom app/ipa to install"
    ) var path: String

    func run() throws {
        let username: String
        let credentials: IntegratedInstaller.Credentials

        if let account = account, let auth = AuthToken(string: account) {
            username = auth.appleID
            credentials = .token(auth.dsToken)
        } else {
            guard let appleID = account ?? Console.prompt("Apple ID: "),
                  let password = Console.getPassword("Password: ")
            else { return }
            username = appleID
            credentials = .password(password)
        }

        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let semaphore = DispatchSemaphore(value: 0)
        let installDelegate = SupersignCLIDelegate(preferredTeam: team.map(DeveloperServicesTeam.ID.init)) {
            semaphore.signal()
        }
        let installer = IntegratedInstaller(
            udid: client.udid,
            connectionPreferences: .init(lookupMode: .only(client.connectionType)),
            appleID: username,
            credentials: credentials,
            configureDevice: false,
            storage: SupersignCLI.config.storage,
            delegate: installDelegate
        )
        installer.install(app: URL(fileURLWithPath: path))
        semaphore.wait()
        _ = installer
    }
}
