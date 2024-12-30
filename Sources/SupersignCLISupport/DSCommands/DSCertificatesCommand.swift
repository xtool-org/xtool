import Foundation
import ArgumentParser
import Supersign
import DeveloperAPI

struct DSCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certificates",
        abstract: "Interact with certificates",
        subcommands: [
            DSCertificatesListCommand.self,
        ],
        defaultSubcommand: DSCertificatesListCommand.self
    )
}

struct DSCertificatesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List certificates"
    )

    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())
        let certificates = try await client.certificatesGetCollection().ok.body.json.data
        for certificate in certificates {
            print("- id: \(certificate.id)")
            guard let attributes = certificate.attributes else {
                continue
            }

            if let name = attributes.name {
                print("  name: \(name)")
            }

            if let certificateType = attributes.certificateType {
                print("  type: \(certificateType.rawValue)")
            }

            if let displayName = attributes.displayName {
                print("  display name: \(displayName)")
            }

            if let serialNumber = attributes.serialNumber {
                print("  serial number: \(serialNumber)")
            }

            if let platform = attributes.platform {
                print("  platform: \(platform.rawValue)")
            }

            if let expirationDate = attributes.expirationDate {
                print("  expiry: \(expirationDate.formatted(.dateTime))")
            }

            if let contentString = attributes.certificateContent {
                guard let content = Data(base64Encoded: contentString) else {
                    print("  content: error: bad base64")
                    continue
                }
                do {
                    let certificate = try Certificate(data: content)
                    print("  content:")
                    switch Result(catching: { try certificate.developerIdentity() }) {
                    case .success(let id):
                        print("    common name: \(id)")
                    case .failure(let error):
                        print("    common name: error: \(error)")
                    }
                    switch Result(catching: { try certificate.teamID() }) {
                    case .success(let teamID):
                        print("    team id: \(teamID)")
                    case .failure(let error):
                        print("    team id: error: \(error)")
                    }
                } catch {
                    print("  content: error: \(error)")
                }
            }
        }
    }
}
