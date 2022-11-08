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
    ) throws -> Self {
        guard let username = username ?? Console.prompt("Apple ID: "), !username.isEmpty else {
            throw Console.Error("A non-empty Apple ID is required.")
        }
        guard let password = password ?? Console.getPassword("Password: "), !password.isEmpty else {
            throw Console.Error("A non-empty password is required.")
        }

        let provider = SupersetteDataProvider(deviceInfo: deviceInfo)
//        let provider = try ADIDataProvider.supersetteProvider(
//            deviceInfo: deviceInfo,
//            storage: SupersignCLI.config.storage
//        )
        if resetProvisioning {
            try withSyncContinuation(provider.resetProvisioning(completion:))
        }
        let authDelegate = SupersignCLIAuthDelegate()
        let manager = try DeveloperServicesLoginManager(
            deviceInfo: deviceInfo,
            anisetteProvider: provider
        )
        let token: DeveloperServicesLoginToken = try withSyncContinuation { cont in
            manager.logIn(
                withUsername: username,
                password: password,
                twoFactorDelegate: authDelegate,
                completion: cont
            )
        }
        _ = authDelegate
        return AuthToken(appleID: username, dsToken: token)
    }

    static func retrieve(deviceInfo: DeviceInfo, account: String?) throws -> Self {
        if let account = account, let token = Self(string: account) {
            return token
        } else {
            return try retrieve(deviceInfo: deviceInfo, username: account, password: nil)
        }
    }
}

struct DSLoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Obtain an Apple ID authentication token"
    )

    @Flag(name: [.short, .long]) var resetProvisioning = false
    @Option(name: [.short, .long], help: "Apple ID") var username: String?
    @Option(name: [.short, .long]) var password: String?

    func run() throws {
        let fullToken = try AuthToken.retrieve(
            deviceInfo: .fetch(),
            username: self.username,
            password: self.password,
            resetProvisioning: resetProvisioning
        )
        guard let string = fullToken.string else {
            throw Console.Error("Could not encode token.")
        }
        print(string)
    }
}

struct DSTeamsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Developer Services teams"
    )

    @Option(name: .shortAndLong) var account: String?

    func run() throws {
        let deviceInfo = try DeviceInfo.fetch()
        let anisetteProvider = SupersetteDataProvider(deviceInfo: deviceInfo)
//        let anisetteProvider = try ADIDataProvider.supersetteProvider(
//            deviceInfo: deviceInfo, storage: SupersignCLI.config.storage
//        )

        let token = try AuthToken.retrieve(deviceInfo: deviceInfo, account: account)
        let client = DeveloperServicesClient(
            loginToken: token.dsToken,
            deviceInfo: deviceInfo,
            anisetteProvider: anisetteProvider
        )
        let teams: [DeveloperServicesTeam] = try withSyncContinuation {
            client.send(DeveloperServicesListTeamsRequest(), completion: $0)
        }
        print(
            teams.map {
                "\($0.name) [\($0.status)]: \($0.id.rawValue)" +
                    $0.memberships.map { "\n- \($0.name) (\($0.platform))" }.joined()
            }.joined(separator: "\n")
        )
    }
}

struct DSAnisetteCommand: ParsableCommand {
    private class Provider: RawADIProvider {
        func startProvisioning(
            spim: Data,
            completion: @escaping (Result<(String, Data), Error>) -> Void
        ) {
            print("spim: \(spim.base64EncodedString())")
            completion(.success(("", Data(base64Encoded: Console.prompt("cpim: ")!)!)))
        }

        func endProvisioning(
            session: String,
            routingInfo: UInt64,
            ptm: Data,
            tk: Data,
            completion: @escaping (Result<Data, Error>) -> Void
        ) {
            print("""
            rinfo: \(routingInfo)
            ptm: \(ptm.base64EncodedString())
            tk: \(tk.base64EncodedString())
            """)
        }

        func requestOTP(
            provisioningInfo: Data,
            completion: @escaping (Result<(machineID: Data, otp: Data), Error>) -> Void
        ) {
            print("otp; pinfo: \(provisioningInfo)")
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "anisette",
        abstract: "Test out Anisette data"
    )

    func run() throws {
        let res = try withSyncContinuation {
            // swiftlint:disable:next force_try
            try! ADIDataProvider(
                rawProvider: Provider(),
                deviceInfo: .current()!,
                storage: SupersignCLI.config.storage
            ).fetchAnisetteData(completion: $0)
        }
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

struct DSCommand: ParsableCommand {
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
