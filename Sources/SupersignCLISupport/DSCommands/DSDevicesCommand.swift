import Foundation
import ArgumentParser
import Supersign
import DeveloperAPI

struct DSDevicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "Interact with devices",
        subcommands: [
            DSDevicesListCommand.self,
        ],
        defaultSubcommand: DSDevicesListCommand.self
    )
}

struct DSDevicesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List devices"
    )

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())
        let devices = try await client.devicesGetCollection().ok.body.json.data
        for device in devices {
            print("- id: \(device.id)")
            guard let attributes = device.attributes else {
                continue
            }

            if let name = attributes.name {
                print("  name: \(name)")
            }

            if let platform = attributes.platform {
                print("  platform: \(platform.rawValue)")
            }

            if let udid = attributes.udid {
                print("  udid: \(udid)")
            }

            if let deviceClass = attributes.deviceClass {
                print("  device class: \(deviceClass.rawValue)")
            }

            if let status = attributes.status {
                print("  status: \(status.rawValue)")
            }

            if let model = attributes.model {
                print("  model: \(model)")
            }

            if let addedDate = attributes.addedDate {
                print("  added date: \(addedDate.formatted(.dateTime))")
            }
        }
    }
}
