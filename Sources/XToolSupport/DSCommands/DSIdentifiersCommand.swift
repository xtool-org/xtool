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
            DSIdentifiersDeleteCommand.self,
        ],
        defaultSubcommand: DSIdentifiersListCommand.self
    )
}

struct DSIdentifiersDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a bundle identifier"
    )

    @Argument(help: "The Developer Services id of the bundle identifier to delete (see `xtool ds identifiers list`)")
    var id: String

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())
        _ = try await client.bundleIdsDeleteInstance(path: .init(id: id)).noContent
        print("Deleted \(id)")
    }
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
