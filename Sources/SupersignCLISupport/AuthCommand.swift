import Foundation
import Supersign
import ArgumentParser
import Crypto
import Dependencies

enum AuthMode: String, CaseIterable, CustomStringConvertible, ExpressibleByArgument {
    case key
    case password

    var description: String {
        switch self {
        case .key: "Key (requires paid Apple Developer Program membership)"
        case .password: "Password (works with any Apple ID but uses private APIs)"
        }
    }
}

struct AuthOperation {
    var username: String?
    var password: String?
    var logoutFromExisting: Bool

    var mode: AuthMode? = nil

    func run() async throws {
        if let token = try? AuthToken.saved(), !logoutFromExisting {
            print("Logged in.\n\(token)")
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

        print("Logged in")
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

        let authDelegate = SupersignCLIAuthDelegate()
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

    func run() async throws {
        try await AuthOperation(
            username: username,
            password: password,
            logoutFromExisting: true,
            mode: mode
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
            This resets the "pseudo-device" that Supersign presents itself as \
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
        abstract: "Authenticate with Apple Developer Services",
        subcommands: [
            AuthLoginCommand.self,
            AuthLogoutCommand.self,
            AuthStatusCommand.self,
        ],
        defaultSubcommand: AuthLoginCommand.self
    )
}

extension DeviceInfo {
    static func fetch() throws -> Self {
        guard let deviceInfo = DeviceInfo.current() else {
            throw Console.Error("Could not fetch client info.")
        }
        return deviceInfo
    }
}

extension DeviceInfoProvider: DependencyKey {
    private static let current = Result { try DeviceInfo.fetch() }
    public static let liveValue = DeviceInfoProvider { try current.get() }
}
