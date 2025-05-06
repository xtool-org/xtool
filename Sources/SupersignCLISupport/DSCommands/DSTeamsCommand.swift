import Foundation
import ArgumentParser
import XKit

struct DSTeamsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teams",
        abstract: "Interact with development teams",
        subcommands: [
            DSTeamsListCommand.self
        ],
        defaultSubcommand: DSTeamsListCommand.self
    )
}

struct DSTeamsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List teams"
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
