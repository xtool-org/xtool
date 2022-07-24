import Foundation
import Supersign
import ArgumentParser

struct InstallSuperchargeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install Supercharge"
    )

    @Option(name: .shortAndLong) var udid: String?
    @Option(name: .shortAndLong) var account: String?

    func run() throws {
        guard let app = SupersignCLI.config.superchargeApp else {
            throw Console.Error("This copy of Supersign is not configured to install Supercharge.")
        }

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
        try withExtendedLifetime(ConnectionManager(searchMode: .usb, delegate: connDelegate)) {
            semaphore.wait()
        }

        let client = Console.choose(
            from: clients,
            onNoElement: { fatalError() },
            multiPrompt: "Choose device",
            formatter: { "\($0.deviceName) (udid: \($0.udid))" }
        )

        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = SupersignCLIDelegate(preferredTeam: nil) {
            semaphore.signal()
        }
        let installer = IntegratedInstaller(
            udid: client.udid,
            connectionPreferences: .init(lookupMode: .only(.usb)),
            appleID: username,
            credentials: credentials,
            configureDevice: true,
            storage: SupersignCLI.config.storage,
            delegate: installDelegate
        )
        installer.install(app: app)
        semaphore.wait()
        _ = installer
    }
}

struct SuperchargeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supercharge",
        abstract: "Configure/install Supercharge",
        subcommands: [InstallSuperchargeCommand.self],
        defaultSubcommand: InstallSuperchargeCommand.self
    )
}
