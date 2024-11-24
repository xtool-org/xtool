import Foundation
import Supersign
import ArgumentParser

extension DeviceInfo {
    static func fetch() throws -> Self {
        guard let deviceInfo = DeviceInfo.current() else {
            throw Console.Error("Could not fetch client info.")
        }
        return deviceInfo
    }
}

private extension AuthToken {
    static func retrieve(
        deviceInfo: DeviceInfo,
        username: String?,
        password: String?,
        resetProvisioning: Bool = false
    ) async throws -> Self {
        guard let username = username ?? Console.prompt("Apple ID: "), !username.isEmpty else {
            throw Console.Error("A non-empty Apple ID is required.")
        }
        guard let password = password ?? Console.getPassword("Password: "), !password.isEmpty else {
            throw Console.Error("A non-empty password is required.")
        }

        let provider = try ADIDataProvider.adiProvider(
            deviceInfo: deviceInfo,
            storage: SupersignCLI.config.storage
        )
        if resetProvisioning {
            await provider.resetProvisioning()
        }
        let authDelegate = SupersignCLIAuthDelegate()
        let manager = try DeveloperServicesLoginManager(
            deviceInfo: deviceInfo,
            anisetteProvider: provider
        )
        let token = try await manager.logIn(
            withUsername: username,
            password: password,
            twoFactorDelegate: authDelegate
        )
        _ = authDelegate
        return AuthToken(appleID: username, dsToken: token)
    }

    static func retrieve(deviceInfo: DeviceInfo, account: String?) async throws -> Self {
        if let account = account, let token = Self(string: account) {
            return token
        } else {
            return try await retrieve(deviceInfo: deviceInfo, username: account, password: nil)
        }
    }
}

struct DSLoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Obtain an Apple ID authentication token"
    )

    @Flag(name: [.short, .long]) var resetProvisioning = false
    @Option(name: [.short, .long], help: "Apple ID") var username: String?
    @Option(name: [.short, .long]) var password: String?
    @Flag(
        name: [.long],
        help: "Print the auth token to standard output instead of persisting it."
    ) var printToken = false

    func run() async throws {
        let fullToken = try await AuthToken.retrieve(
            deviceInfo: .fetch(),
            username: self.username,
            password: self.password,
            resetProvisioning: resetProvisioning
        )
        if printToken {
            guard let string = fullToken.string else {
                throw Console.Error("Could not encode token.")
            }
            print(string)
        } else {
            try fullToken.save()
            print("Logged in!")
        }
    }
}

struct DSTeamsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Developer Services teams"
    )

    @Option(name: .shortAndLong) var account: String?

    func run() async throws {
        let token = try account.flatMap(AuthToken.init(string:)) ?? AuthToken.saved()

        let deviceInfo = try DeviceInfo.fetch()
        let anisetteProvider = try ADIDataProvider.adiProvider(
            deviceInfo: deviceInfo, storage: SupersignCLI.config.storage
        )

        let client = DeveloperServicesClient(
            loginToken: token.dsToken,
            deviceInfo: deviceInfo,
            anisetteProvider: anisetteProvider
        )
        let teams: [DeveloperServicesTeam] = try await client.send(DeveloperServicesListTeamsRequest())
        print(
            teams.map {
                "\($0.name) [\($0.status)]: \($0.id.rawValue)" +
                    $0.memberships.map { "\n- \($0.name) (\($0.platform))" }.joined()
            }.joined(separator: "\n")
        )
    }
}

struct DSAnisetteCommand: AsyncParsableCommand {
    private class Provider: RawADIProvider, RawADIProvisioningSession {
        func startProvisioning(spim: Data, userID: UUID) -> (RawADIProvisioningSession, Data) {
            print("spim: \(spim.base64EncodedString())")
            return (self, Data(base64Encoded: Console.prompt("cpim: ")!)!)
        }

        func endProvisioning(
            routingInfo: UInt64,
            ptm: Data,
            tk: Data
        ) -> Data {
            print("""
            rinfo: \(routingInfo)
            ptm: \(ptm.base64EncodedString())
            tk: \(tk.base64EncodedString())
            """)
            return Data(base64Encoded: Console.prompt("pinfo: ")!)!
        }

        func requestOTP(
            userID: UUID,
            routingInfo: inout UInt64,
            provisioningInfo: Data
        ) -> (machineID: Data, otp: Data) {
            print("otp; pinfo: \(provisioningInfo)")
            return (Data(), Data())
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "anisette",
        abstract: "Test out Anisette data"
    )

    func run() async throws {
        // swiftlint:disable:next force_try
        let res = try! await ADIDataProvider(
            rawProvider: Provider(),
            deviceInfo: .current()!,
            storage: SupersignCLI.config.storage
        ).fetchAnisetteData()

        print(res)
    }
}

struct DSTeamsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teams",
        abstract: "Interact with Developer Services teams",
        subcommands: [DSTeamsListCommand.self],
        defaultSubcommand: DSTeamsListCommand.self
    )
}

struct DSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ds",
        abstract: "Interact with Apple Developer Services",
        subcommands: [
            DSLoginCommand.self,
            DSTeamsCommand.self,
            DSAnisetteCommand.self
        ]
    )
}
