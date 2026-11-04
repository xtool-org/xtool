import XUtils
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

        let bundleIDs = try await DeveloperAPIPages {
            try await client.bundleIdsGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        for bundleID in bundleIDs {
            d.out.print("- id: \(bundleID.id)")
            guard let attributes = bundleID.attributes else {
                continue
            }
            if let name = attributes.name {
                d.out.print("  name: \(name)")
            }
            if let identifier = attributes.identifier {
                d.out.print("  identifier: \(identifier)")
            }
            if let platform = attributes.platform {
                d.out.print("  platform: \(platform.rawValue)")
            }
            if let seedId = attributes.seedId {
                d.out.print("  seedId: \(seedId)")
            }
        }
    }
}
