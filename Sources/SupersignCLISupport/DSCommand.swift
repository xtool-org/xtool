import Foundation
import Supersign
import ArgumentParser
import DeveloperAPI
import OpenAPIRuntime
import Dependencies

struct DSTeamsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Developer Services teams"
    )

    func run() async throws {
        let token = try AuthToken.saved()

        guard case let .xcode(authData) = try token.authData() else {
            throw Console.Error("This command requires password-based authentication")
        }
        let client = DeveloperServicesClient(authData: authData)
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
        func startProvisioning(spim: Data, userID: UUID) async throws -> (RawADIProvisioningSession, Data) {
            print("spim: \(spim.base64EncodedString())")
            return (self, Data(base64Encoded: try await Console.prompt("cpim: "))!)
        }

        func endProvisioning(
            routingInfo: UInt64,
            ptm: Data,
            tk: Data
        ) async throws -> Data {
            print("""
            rinfo: \(routingInfo)
            ptm: \(ptm.base64EncodedString())
            tk: \(tk.base64EncodedString())
            """)
            return Data(base64Encoded: try await Console.prompt("pinfo: "))!
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
        let provider = withDependencies {
            $0.rawADIProvider = Provider()
        } operation: {
            ADIDataProvider()
        }
        let res = try await provider.fetchAnisetteData()
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
