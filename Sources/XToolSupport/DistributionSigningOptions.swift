import Foundation
import ArgumentParser
import XKit

/// Options to sign with an identity and provisioning profiles that already exist,
/// as needed for App Store, TestFlight and Ad Hoc builds (typically in CI).
struct DistributionSigningOptions: ParsableArguments {
    static let defaultPasswordEnvironmentVariable = "XTOOL_P12_PASSWORD"

    @Option(
        help: ArgumentHelp(
            "Sign for distribution with the identity in this .p12 file",
            discussion: """
            The file must hold an Apple Distribution certificate and its private key. Nothing is \
            created or revoked on your Apple Developer account.
            """,
            valueName: "path"
        )
    ) var p12: String?

    @Option(
        help: ArgumentHelp(
            "Environment variable that holds the .p12 password",
            discussion: "Defaults to '\(defaultPasswordEnvironmentVariable)'. An unset variable means an empty password.",
            valueName: "name"
        )
    ) var p12PasswordEnv: String = defaultPasswordEnvironmentVariable

    @Option(
        help: ArgumentHelp(
            "File that holds the .p12 password (takes precedence over the environment variable)",
            valueName: "path"
        )
    ) var p12PasswordFile: String?

    @Option(
        name: .customLong("profile"),
        help: ArgumentHelp(
            "An App Store or Ad Hoc .mobileprovision (repeatable)",
            discussion: "Each bundle is signed with the most specific profile that matches its bundle ID.",
            valueName: "path"
        )
    ) var profiles: [String] = []

    @Option(
        help: ArgumentHelp(
            "A plist of entitlements to use instead of the ones already in the app's signature",
            discussion: "Entitlements the profile does not allow are rejected.",
            valueName: "path"
        )
    ) var entitlements: String?

    var isEnabled: Bool { p12 != nil }

    func validate() throws {
        if p12 == nil {
            if !profiles.isEmpty || entitlements != nil || p12PasswordFile != nil {
                throw ValidationError("--profile, --entitlements and --p12-password-file require --p12.")
            }
        } else if profiles.isEmpty {
            throw ValidationError("Distribution signing with --p12 requires at least one --profile.")
        }
    }

    private func password() throws -> String {
        if let p12PasswordFile {
            let contents = try String(contentsOfFile: p12PasswordFile, encoding: .utf8)
            // tolerate the trailing newline that editors and `echo` add
            return contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
        }
        return ProcessInfo.processInfo.environment[p12PasswordEnv] ?? ""
    }

    func makeSigner() throws -> DistributionSigner {
        guard let p12 else { throw ValidationError("--p12 is required.") }
        let identity = try DistributionIdentity(p12: URL(fileURLWithPath: p12), password: password())
        let profiles = try self.profiles.map { try DistributionProfile(contentsOf: URL(fileURLWithPath: $0)) }
        let entitlements = try self.entitlements.map {
            try PropertyListDecoder().decode(Entitlements.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
        return try DistributionSigner(identity: identity, profiles: profiles, entitlements: entitlements)
    }

    /// Signs `app` in place, printing progress.
    func sign(app: URL) async throws {
        let signer = try makeSigner()
        defer { print() }
        do {
            let result = try await signer.sign(
                app: app,
                status: { print("\r\u{1B}[K\($0)...", terminator: "") },
                progress: { progress in
                    if let progress {
                        print("\r\(Int(progress * 100))%", terminator: "")
                    }
                }
            )
            print("\r\u{1B}[KSigned \(result.bundleID)", terminator: "")
        } catch let error as CancellationError {
            throw error
        } catch {
            print("\nError: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
