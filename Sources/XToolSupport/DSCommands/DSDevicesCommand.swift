import XUtils
import Foundation
import ArgumentParser
import XKit
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

        let devices = try await DeveloperAPIPages {
            try await client.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        for device in devices {
            d.out.print("- id: \(device.id)")
            guard let attributes = device.attributes else {
                continue
            }

            if let name = attributes.name {
                d.out.print("  name: \(name)")
            }

            if let platform = attributes.platform {
                d.out.print("  platform: \(platform.rawValue)")
            }

            if let udid = attributes.udid {
                d.out.print("  udid: \(udid)")
            }

            if let deviceClass = attributes.deviceClass {
                d.out.print("  device class: \(deviceClass.rawValue)")
            }

            if let status = attributes.status {
                d.out.print("  status: \(status.rawValue)")
            }

            if let model = attributes.model {
                d.out.print("  model: \(model)")
            }

            if let addedDate = attributes.addedDate {
                d.out.print("  added date: \(addedDate.formatted(.dateTime))")
            }
        }
    }
}
