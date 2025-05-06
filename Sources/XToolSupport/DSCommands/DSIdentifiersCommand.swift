import Foundation
import ArgumentParser
import XKit
import DeveloperAPI

struct DSIdentifiersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identifiers",
        abstract: "Interact with bundle identifiers",
        subcommands: [
            DSIdentifiersListCommand.self,
        ],
        defaultSubcommand: DSIdentifiersListCommand.self
    )
}

struct DSIdentifiersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List bundle identifiers"
    )

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())
        let bundleIDs = try await client.bundleIdsGetCollection().ok.body.json.data
        for bundleID in bundleIDs {
            print("- id: \(bundleID.id)")
            guard let attributes = bundleID.attributes else {
                continue
            }
            if let name = attributes.name {
                print("  name: \(name)")
            }
            if let identifier = attributes.identifier {
                print("  identifier: \(identifier)")
            }
            if let platform = attributes.platform {
                print("  platform: \(platform.rawValue)")
            }
            if let seedId = attributes.seedId {
                print("  seedId: \(seedId)")
            }
        }
    }
}
