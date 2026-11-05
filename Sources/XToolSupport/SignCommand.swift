import Foundation
import ArgumentParser
import XKit
import XUtils

extension SigningPlatform: ExpressibleByArgument {}

struct SignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign an existing iOS or tvOS app without building or installing it"
    )

    @Argument(help: "The .app directory or .ipa archive to sign") var path: String
    @Option(name: [.short, .long], help: "A new .app or .ipa output path (must not exist)") var output: String
    @Option(help: "Signing platform: ios or tvos (default: detect from the app)") var platform: SigningPlatform?
    @Flag(help: "Keep the existing bundle identifiers instead of adding the xtool prefix") var preserveBundleID = false

    func run() async throws {
        let output = URL(fileURLWithPath: output)
        let package = try await SigningPackage(input: URL(fileURLWithPath: path), output: output, platform: platform)
        // Validate and stage before loading credentials or making any provisioning requests.
        let token = try AuthToken.saved()
        let delegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(auth: token.authData(), delegate: delegate)
        let bundleID = try await installer.signInPlace(
            app: package.app, platform: package.platform, preserveBundleID: preserveBundleID
        )
        try await package.export(to: output)
        d.out.print("\nSigned \(bundleID): \(output.path)")
    }
}
