import Foundation
import ArgumentParser
import Supersign
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

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())
        let profiles = try await client.profilesGetCollection().ok.body.json.data
        for profile in profiles {
            print("- id: \(profile.id)")
            guard let attributes = profile.attributes else {
                continue
            }

            if let name = attributes.name {
                print("  name: \(name)")
            }

            if let platform = attributes.platform {
                print("  platform: \(platform.rawValue)")
            }

            if let profileType = attributes.profileType {
                print("  profile type: \(profileType.rawValue)")
            }

            if let profileState = attributes.profileState {
                print("  profile state: \(profileState.rawValue)")
            }

            if let uuid = attributes.uuid {
                print("  uuid: \(uuid)")
            }

            if let createdDate = attributes.createdDate {
                print("  created date: \(createdDate.formatted(.dateTime))")
            }

            if let expirationDate = attributes.expirationDate {
                print("  expiration date: \(expirationDate.formatted(.dateTime))")
            }

            if let contentString = attributes.profileContent {
                guard let contentData = Data(base64Encoded: contentString) else {
                    print("  content: error: bad base64")
                    continue
                }

                do {
                    let profile = try Mobileprovision(data: contentData)
                    let digest = try profile.digest()
                    print("    team identifiers:")
                    for teamID in digest.teamIdentifiers {
                        print("      - \(teamID.rawValue)")
                    }
                    print("    certificates:")
                    for certificate in digest.certificates {
                        print("      - \(certificate.serialNumber())")
                    }
                    print("    devices:")
                    for device in digest.devices {
                        print("      - \(device)")
                    }
                    let entitlements = try? String(decoding: Self.encoder.encode(digest.entitlements), as: UTF8.self)
                    print("    entitlements: \(entitlements ?? "<error>")")
                } catch {
                    print("  content: error: \(error)")
                }
            }
        }
    }
}
