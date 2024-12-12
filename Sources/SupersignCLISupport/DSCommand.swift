import Foundation
import Supersign
import ArgumentParser

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
    private final class Provider: RawADIProvider, RawADIProvisioningSession {
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
            DSTeamsCommand.self,
            DSAnisetteCommand.self,
        ]
    )
}
