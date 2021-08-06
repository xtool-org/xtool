import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct InstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an ipa file to your device"
    )

    @Option(name: .shortAndLong) var udid: String?
    @Option(name: .shortAndLong) var account: String?
    @Flag var search: ConnectionManager.SearchMode = .all

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

        print("Waiting for device to be connected...")
        var clients: [ConnectionManager.Client]!
        let semaphore = DispatchSemaphore(value: 0)
        let connDelegate = ConnectionDelegate { currClients in
            if let udid = udid {
                if let client = currClients.first(where: { $0.udid == udid }) {
                    clients = [client]
                } else {
                    return
                }
            } else {
                clients = currClients
            }
            semaphore.signal()
        }
        try withExtendedLifetime(ConnectionManager(searchMode: search, delegate: connDelegate)) {
            semaphore.wait()
        }

        let client = Console.choose(
            from: clients,
            onNoElement: { fatalError() },
            multiPrompt: "Choose device",
            formatter: { "\($0.deviceName) (\($0.connectionType), udid: \($0.udid))" }
        )

        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = SupersignCLIDelegate(preferredTeam: nil) {
            semaphore.signal()
        }
        let installer = IntegratedInstaller(
            udid: client.udid,
            connectionPreferences: .init(lookupMode: .only(client.connectionType)),
            appleID: username,
            credentials: credentials,
            configureDevice: false,
            signingInfoManager: SupersignCLI.config.signingInfoManager,
            delegate: installDelegate
        )
        installer.install(app: URL(fileURLWithPath: path))
        semaphore.wait()
        _ = installer
    }
}
