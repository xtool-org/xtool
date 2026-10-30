import XUtils
import Foundation
import ArgumentParser
import XKit
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

    // swiftlint:disable:next cyclomatic_complexity
    func run() async throws {
        let client = DeveloperAPIClient(auth: try AuthToken.saved().authData())

        let certificates = try await DeveloperAPIPages {
            try await client.certificatesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        for certificate in certificates {
            d.out.print("- id: \(certificate.id)")
            guard let attributes = certificate.attributes else {
                continue
            }

            if let name = attributes.name {
                d.out.print("  name: \(name)")
            }

            if let certificateType = attributes.certificateType {
                d.out.print("  type: \(certificateType.rawValue)")
            }

            if let displayName = attributes.displayName {
                d.out.print("  display name: \(displayName)")
            }

            if let serialNumber = attributes.serialNumber {
                d.out.print("  serial number: \(serialNumber)")
            }

            if let platform = attributes.platform {
                d.out.print("  platform: \(platform.rawValue)")
            }

            if let expirationDate = attributes.expirationDate {
                d.out.print("  expiry: \(expirationDate.formatted(.dateTime))")
            }

            if let contentString = attributes.certificateContent {
                guard let content = Data(base64Encoded: contentString) else {
                    d.out.print("  content: error: bad base64")
                    continue
                }
                do {
                    let certificate = try Certificate(data: content)
                    d.out.print("  content:")
                    switch Result(catching: { try certificate.developerIdentity() }) {
                    case .success(let id):
                        d.out.print("    common name: \(id)")
                    case .failure(let error):
                        d.out.print("    common name: error: \(error)")
                    }
                    switch Result(catching: { try certificate.teamID() }) {
                    case .success(let teamID):
                        d.out.print("    team id: \(teamID)")
                    case .failure(let error):
                        d.out.print("    team id: error: \(error)")
                    }
                } catch {
                    d.out.print("  content: error: \(error)")
                }
            }
        }
    }
}
