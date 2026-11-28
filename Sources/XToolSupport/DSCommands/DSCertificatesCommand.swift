import XUtils
import Foundation
import ArgumentParser
import XKit
import DeveloperAPI
import Dependencies
import XCLIUtils

struct DSCertificatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "certificates",
        abstract: "Interact with certificates",
        subcommands: [
            DSCertificatesListCommand.self,
            DSCertificatesImportCommand.self,
            DSCertificatesExportCommand.self,
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

        let certificates = try await DeveloperAPIPages(\.links.next) {
            try await client.certificatesGetCollection().ok.body.json
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

struct DSCertificatesImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an existing signing certificate using its private key",
        discussion: """
        xtool looks up the certificate matching the private key on the team \
        you're logged in to, and uses it for signing instead of creating a \
        certificate of its own.

        The key must be an unencrypted PEM file. To extract one from a .p12 file:

          openssl pkcs12 -in identity.p12 -nocerts -nodes -out key.pem
        """
    )

    @Argument(
        help: "Path to the private key (PEM)",
        completion: .file(extensions: ["pem", "key"])
    ) var path: String

    func run() async throws {
        let pem = try String(decoding: Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        let privateKey: PrivateKey
        do {
            privateKey = try PrivateKey(pemEncoded: pem)
        } catch {
            throw Console.Error("Could not read private key: \(error)")
        }

        let auth = try AuthToken.saved().authData()
        let client = DeveloperAPIClient(auth: auth)
        let candidates = try await DeveloperAPIPages(\.links.next) {
            try await client.certificatesGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        .compactMap { certificate -> (DeveloperServicesCertificate, Certificate)? in
            guard let content = certificate.attributes?.certificateContent.flatMap({ Data(base64Encoded: $0) }),
                  let parsed = try? Certificate(data: content),
                  parsed.isPaired(with: privateKey)
                  else { return nil }
            return (certificate, parsed)
        }
        // the same key may have been used for multiple CSRs; prefer the newest
        .sorted { $1.1.wasIssuedBefore($0.1) }

        guard let (certificate, parsed) = candidates.first(where: {
            $0.0.attributes?.expirationDate.map { $0 > Date() } ?? true
        }) else {
            throw Console.Error(
                candidates.isEmpty
                    ? "No certificate on your team matches this private key."
                    : "All certificates matching this private key have expired."
            )
        }

        @Dependency(\.signingInfoManager) var signingInfoManager
        try signingInfoManager.setInfo(
            SigningInfo(privateKey: privateKey, certificate: parsed),
            forIdentityID: auth.identityID
        )

        let name = certificate.attributes?.name ?? (try? parsed.developerIdentity())
        d.out.print("Imported certificate\(name.map { " \"\($0)\"" } ?? "") (\(certificate.id))")
    }
}

struct DSCertificatesExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export the private key of xtool's signing certificate",
        discussion: """
        The key is written as an unencrypted PEM file, which can be imported \
        on another machine with `xtool ds certificates import`.
        """
    )

    @Argument(
        help: "Path to write the private key to",
        completion: .file(extensions: ["pem", "key"])
    ) var path: String

    func run() async throws {
        let auth = try AuthToken.saved().authData()

        @Dependency(\.signingInfoManager) var signingInfoManager
        guard let signingInfo = try signingInfoManager.info(forIdentityID: auth.identityID) else {
            throw Console.Error("""
            xtool does not have a signing certificate for this account yet. \
            One is created the first time you install an app.
            """)
        }

        guard !FileManager.default.fileExists(atPath: path) else {
            throw Console.Error("\(path) already exists.")
        }
        guard FileManager.default.createFile(
            atPath: path,
            contents: try signingInfo.privateKey.pemData(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw Console.Error("Could not write to \(path).")
        }

        let certificate = signingInfo.certificate
        let name = (try? certificate.developerIdentity()) ?? "certificate"
        d.out.print("Exported private key for \"\(name)\" (serial number \(certificate.serialNumber())) to \(path)")
    }
}
