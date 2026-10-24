import Foundation
import XKit
import ArgumentParser
import Crypto
import Dependencies

private extension GrandSlamMacProfile {
    var menuDescription: String {
        switch self {
        case .provider:
            "Provider default (identity supplied by the Anisette server)"
        case .modern:
            "Modern Mac (macOS 27; for Advanced Data Protection accounts, experimental)"
        }
    }
}

private func parseMacProfile(_ name: String) throws -> GrandSlamMacProfile {
    guard let profile = GrandSlamMacProfile(rawValue: name) else {
        throw Console.Error("Invalid Mac profile '\(name)'; expected 'provider' or 'modern'.")
    }
    return profile
}

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

    var macProfile: GrandSlamMacProfile?
    var mode: AuthMode?
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

        if mode == .key && macProfile != nil {
            throw Console.Error("--mac-profile can only be used with password login.")
        }

        let token = switch mode {
        case .password:
            try await logInWithPassword()
        case .key:
            try await logInWithKey()
        }
        try token.save()

        print("Logged in.\n\(token)")
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

    private func selectMacProfile() async throws {
        @Dependency(\.keyValueStorage) var storage

        let environmentProfile = ProcessInfo.processInfo.environment[GrandSlamMacProfile.environmentVariable]
        let selected: GrandSlamMacProfile
        if let environmentProfile, !environmentProfile.isEmpty {
            if macProfile != nil {
                throw Console.Error("Use either --mac-profile or XTL_GSA_MAC_PROFILE, not both.")
            }
            selected = try parseMacProfile(environmentProfile)
        } else if let macProfile {
            selected = macProfile
        } else if username != nil && password != nil {
            // Preserve non-interactive password logins without requiring a new flag.
            if let saved = try storage.string(forKey: GrandSlamMacProfile.storageKey) {
                selected = try parseMacProfile(saved)
            } else {
                selected = .provider
            }
        } else {
            if let saved = try storage.string(forKey: GrandSlamMacProfile.storageKey) {
                print("Saved Apple device profile: \(saved)")
            }
            selected = try await Console.choose(
                from: GrandSlamMacProfile.allCases,
                onNoElement: { .provider },
                multiPrompt: "Select Apple device profile",
                formatter: \.menuDescription
            )
        }

        // Reused by later commands such as `xtool dev run`, so signing and
        // provisioning use the same identity as password authentication.
        try storage.setString(selected.rawValue, forKey: GrandSlamMacProfile.storageKey)
        print("Apple device profile: \(selected.rawValue) (saved)")
    }

    private func logInWithPassword() async throws -> AuthToken {
        print("""
        Heads up:
          This works by emulating a virtual Mac to interact with Apple services.
          We use a third-party service to create a randomized device ID token
          (Anisette Data) but your credentials are only ever sent to Apple.
          Still, consider using a secondary Apple ID since this is a private API.
        """)

        try await selectMacProfile()

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

        @Dependency(\.anisetteDataProvider) var anisetteProvider

        return AuthToken.xcode(.init(
            appleID: username,
            adsid: token.adsid,
            token: token.token,
            expiry: token.expiry,
            teamID: team.id.rawValue,
            anisetteProviderID: anisetteProvider.providerID
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
    @Option(name: .long, help: "Apple device profile for password login: provider or modern")
    var macProfile: String?

    func run() async throws {
        let selectedProfile = try macProfile.map { try parseMacProfile($0) }
        try await AuthOperation(
            username: username,
            password: password,
            logoutFromExisting: true,
            macProfile: selectedProfile,
            mode: mode
        ).run()
    }
}

struct AuthProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Show or change the Apple device profile without logging in again"
    )

    @Argument(help: "Profile to save: provider or modern (omit to display the current profile)")
    var profile: String?

    func run() async throws {
        @Dependency(\.keyValueStorage) var storage

        if let profile {
            let selected = try parseMacProfile(profile)
            try storage.setString(selected.rawValue, forKey: GrandSlamMacProfile.storageKey)
            print("Saved Apple device profile: \(selected.rawValue)")
        }

        if let environment = ProcessInfo.processInfo.environment[GrandSlamMacProfile.environmentVariable],
           !environment.isEmpty {
            let selected = try parseMacProfile(environment)
            print("Effective Apple device profile: \(selected.rawValue) (environment override)")
        } else {
            let saved = try storage.string(forKey: GrandSlamMacProfile.storageKey)
            print("Effective Apple device profile: \(saved ?? GrandSlamMacProfile.provider.rawValue)")
        }
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
        } else {
            print("Logged out")
        }
    }
}

struct AuthCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage Apple Developer Services authentication",
        subcommands: [
            AuthLoginCommand.self,
            AuthProfileCommand.self,
            AuthLogoutCommand.self,
            AuthStatusCommand.self,
        ],
        defaultSubcommand: AuthLoginCommand.self
    )
}
