import Foundation
import XKit
import ArgumentParser
import Crypto
import Dependencies
#if canImport(Security)
import Security
#endif

enum AuthMode: String, CaseIterable, CustomStringConvertible, ExpressibleByArgument {
    case key
    case password

    var description: String {
        switch self {
        case .key: "API Key (requires paid Apple Developer Program membership)"
        case .password: "Password (works with any Apple ID but uses private APIs)"
        }
    }
}

struct AuthOperation {
    var username: String?
    var password: String?
    var logoutFromExisting: Bool

    var mode: AuthMode?
    var signingP12: String? = nil
    var signingP12Password: String? = nil
    var quiet = false

    func run() async throws {
        if let token = try? AuthToken.saved(), !logoutFromExisting {
            if !quiet {
                print("Logged in.\n\(token)")
            }
            return
        }

        let mode: AuthMode
        if let existing = self.mode {
            mode = existing
        } else {
            mode = try await Console.choose(
                from: AuthMode.allCases,
                onNoElement: { throw Console.Error("Mode selection is required") },
                multiPrompt: "Select login mode",
                formatter: \.description
            )
        }

        let token = switch mode {
        case .password:
            try await logInWithPassword()
        case .key:
            try await logInWithKey()
        }
        try token.save()
        try await saveSigningCertificateIfProvided()

        print("Logged in.\n\(token)")
    }

    private func saveSigningCertificateIfProvided() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawPath = signingP12
            ?? env["XTOOL_SIGNING_P12"]
            ?? env["XTOOL_CERT_P12"]
        guard let rawPath else {
            return
        }

        let expandedPath = (rawPath as NSString).expandingTildeInPath
        let sourceURL = URL(fileURLWithPath: expandedPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw Console.Error("Signing p12 not found at path: \(sourceURL.path)")
        }

        let password: String
        if let explicit = signingP12Password
            ?? env["XTOOL_SIGNING_P12_PASSWORD"]
            ?? env["XTOOL_CERT_P12_PASSWORD"]
        {
            password = explicit
        } else {
            password = try await Console.getPassword("Signing certificate password: ")
        }

        @Dependency(\.persistentDirectory) var persistentDirectory
        let destinationDirectory = persistentDirectory.appendingPathComponent("signing", isDirectory: true)
        let destinationURL = destinationDirectory.appendingPathComponent("cert.p12")

        if !FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        try AuthToken.saveSigningCertificate(path: destinationURL.path, password: password)
        print("Saved signing certificate for device provisioning.")
    }

    private func logInWithKey() async throws -> AuthToken {
        let id = try await Console.promptRequired("Key ID: ", existing: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let issuerID = try await Console.promptRequired("Issuer ID: ", existing: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let path = try await Console.promptRequired("Key path: ", existing: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let pem = try String(decoding: Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        do {
            _ = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw Console.Error("Key is invalid: \(error)")
        }

        return AuthToken.appStoreConnect(.init(id: id, issuerID: issuerID, pem: pem))
    }

    private func logInWithPassword() async throws -> AuthToken {
        let username = try await Console.promptRequired("Apple ID: ", existing: username)

        let password: String
        if let existing = self.password {
            password = existing
        } else {
            password = try await Console.getPassword("Password: ")
        }
        guard !password.isEmpty else {
            throw Console.Error("Password cannot be empty.")
        }

        print("Logging in...")

        let authDelegate = XToolAuthDelegate()
        let manager = DeveloperServicesLoginManager()
        let token = try await manager.logIn(
            withUsername: username,
            password: password,
            twoFactorDelegate: authDelegate
        )

        let client = DeveloperServicesClient(loginToken: token)
        let teams = try await client.send(DeveloperServicesListTeamsRequest())
        let team = try await Console.choose(
            from: teams,
            onNoElement: {
                throw Console.Error("No development teams found")
            },
            multiPrompt: "\nSelect a team",
            formatter: {
                "\($0.name) (\($0.id.rawValue))"
            }
        )

        return AuthToken.xcode(.init(
            appleID: username,
            adsid: token.adsid,
            token: token.token,
            expiry: token.expiry,
            teamID: team.id.rawValue
        ))
    }
}

struct AuthLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Log in to Apple Developer Services"
    )

    @Option(name: [.short, .long], help: "Apple ID") var username: String?
    @Option(name: [.short, .long]) var password: String?
    @Option(name: [.short, .long]) var mode: AuthMode?
    @Option(help: "Path to signing certificate (.p12) to copy and save") var signingP12: String?
    @Option(help: "Password for signing certificate (.p12)") var signingP12Password: String?

    func run() async throws {
        try await AuthOperation(
            username: username,
            password: password,
            logoutFromExisting: true,
            mode: mode,
            signingP12: signingP12,
            signingP12Password: signingP12Password
        ).run()
    }
}

struct AuthLogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Log out of Apple Developer Services"
    )

    @Flag(
        name: [.short, .customLong("reset-2fa")],
        help: ArgumentHelp(
            "Reset 2-factor authentication data",
            discussion: """
            This resets the "pseudo-device" that xtool presents itself as \
            when authenticating with Apple using the password login mode.

            Effectively, this means you will be prompted to complete 2-factor \
            authentication again the next time you log in.
            """
        )
    ) var reset2FA = false

    func run() async throws {
        if (try? AuthToken.saved()) != nil {
            try AuthToken.clear()
            print("Logged out")
        } else {
            print("Already logged out")
        }

        if reset2FA {
            @Dependency(\.anisetteDataProvider) var anisetteProvider
            await anisetteProvider.resetProvisioning()
            print("Forgot device")
        }
    }
}

struct AuthStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get Apple Developer Services auth status"
    )

    func run() async throws {
        if let token = try? AuthToken.saved() {
            print("Logged in.\n\(token)")
            print(try signingCertificateStatus())
        } else {
            print("Logged out")
        }
    }

    private func signingCertificateStatus() throws -> String {
        guard let path = try AuthToken.savedSigningCertificatePath() else {
            return "- Signing certificate: not configured"
        }

        let fileExists = FileManager.default.fileExists(atPath: path)
        let hasPassword = !(try AuthToken.savedSigningCertificatePassword() ?? "").isEmpty

        var lines = [
            "- Signing certificate: configured",
            "- Signing certificate path: \(path)",
            "- Signing certificate file: \(fileExists ? "present" : "missing")",
            "- Signing certificate password: \(hasPassword ? "saved" : "missing")",
        ]

        #if canImport(Security)
        if fileExists,
           hasPassword,
           let certSummary = try loadSavedCertificateSummary(path: path) {
            lines.append("- Signing certificate subject: \(certSummary.subject)")
            lines.append("- Signing certificate serial: \(certSummary.serial)")
        }
        #endif

        return lines.joined(separator: "\n")
    }

    #if canImport(Security)
    private func loadSavedCertificateSummary(path: String) throws -> (subject: String, serial: String)? {
        guard let password = try AuthToken.savedSigningCertificatePassword(),
              let p12Data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else {
            return nil
        }

        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var importedItems: CFArray?
        guard SecPKCS12Import(p12Data as CFData, options as CFDictionary, &importedItems) == errSecSuccess,
              let importedItems,
              let firstItem = (importedItems as NSArray).firstObject as? NSDictionary,
              let identityAny = firstItem[kSecImportItemIdentity as String]
        else {
            return nil
        }

        let identity = identityAny as! SecIdentity
        var certificateRef: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              let certificateRef
        else {
            return nil
        }

        let certData = SecCertificateCopyData(certificateRef) as Data
        guard let certificate = try? Certificate(data: certData) else {
            return nil
        }

        let subject = (try? certificate.developerIdentity()) ?? "unknown"
        let serial = certificate.serialNumber()
        return (subject, serial)
    }
    #endif
}

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage Apple Developer Services authentication",
        subcommands: [
            AuthLoginCommand.self,
            AuthLogoutCommand.self,
            AuthStatusCommand.self,
        ],
        defaultSubcommand: AuthLoginCommand.self
    )
}
