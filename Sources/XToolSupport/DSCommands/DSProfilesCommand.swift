import XUtils
import Foundation
import ArgumentParser
import XKit
import DeveloperAPI

struct DSProfilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Interact with profiles",
        subcommands: [
            DSProfilesListCommand.self,
        ],
        defaultSubcommand: DSProfilesListCommand.self
    )
}

struct DSProfilesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List profiles"
    )

    private static let encoder = JSONEncoder()

    // swiftlint:disable:next cyclomatic_complexity
    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())

        let profiles = try await DeveloperAPIPages {
            try await client.profilesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        for profile in profiles {
            d.out.print("- id: \(profile.id)")
            guard let attributes = profile.attributes else {
                continue
            }

            if let name = attributes.name {
                d.out.print("  name: \(name)")
            }

            if let platform = attributes.platform {
                d.out.print("  platform: \(platform.rawValue)")
            }

            if let profileType = attributes.profileType {
                d.out.print("  profile type: \(profileType.rawValue)")
            }

            if let profileState = attributes.profileState {
                d.out.print("  profile state: \(profileState.rawValue)")
            }

            if let uuid = attributes.uuid {
                d.out.print("  uuid: \(uuid)")
            }

            if let createdDate = attributes.createdDate {
                d.out.print("  created date: \(createdDate.formatted(.dateTime))")
            }

            if let expirationDate = attributes.expirationDate {
                d.out.print("  expiration date: \(expirationDate.formatted(.dateTime))")
            }

            if let contentString = attributes.profileContent {
                guard let contentData = Data(base64Encoded: contentString) else {
                    d.out.print("  content: error: bad base64")
                    continue
                }

                do {
                    let profile = try Mobileprovision(data: contentData)
                    let digest = try profile.digest()
                    d.out.print("    team identifiers:")
                    for teamID in digest.teamIdentifiers {
                        d.out.print("    - \(teamID.rawValue)")
                    }
                    d.out.print("    certificates:")
                    for certificate in digest.certificates {
                        d.out.print("    - \(certificate.serialNumber())")
                    }
                    d.out.print("    devices:")
                    for device in digest.devices {
                        d.out.print("    - \(device)")
                    }
                    let entitlements = try? String(decoding: Self.encoder.encode(digest.entitlements), as: UTF8.self)
                    d.out.print("    entitlements: \(entitlements ?? "<error>")")
                } catch {
                    d.out.print("  content: error: \(error)")
                }
            }
        }
    }
}
