import XUtils
import Foundation
import XKit
import ArgumentParser
import Dependencies

struct DSAnisetteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "anisette",
        abstract: "Test out Anisette data"
    )

    func run() async throws {
        @Dependency(\.anisetteDataProvider) var provider
        let res = try await provider.fetchAnisetteData()
        for (key, value) in res.dictionary.sorted(by: { $0.key < $1.key }) {
            d.out.print("\(key): \(value)")
        }
    }
}

struct DSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ds",
        abstract: "Interact with Apple Developer Services",
        subcommands: [
            DSTeamsCommand.self,
            DSCertificatesCommand.self,
            DSIdentifiersCommand.self,
            DSDevicesCommand.self,
            DSProfilesCommand.self,
            DSAnisetteCommand.self,
        ]
    )
}
