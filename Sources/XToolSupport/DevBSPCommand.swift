import ArgumentParser
import Foundation
import XKit
import PackLib
import Subprocess

struct DevBSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-server",
        abstract: "Run build server",
    )

    @Option
    var triple: String?

    func run() async throws {
        guard try await SwiftVersion.current.supportsSwiftBuild else {
            throw Console.Error("`xtool dev build-server` requires Swift 6.4 or later")
        }
        let settings = try await BuildSettings(
            configuration: .debug,
            triple: triple ?? PackOperation.defaultTriple
        )
        try await Subprocess.run(
            settings.buildServerInvocation(),
            input: .standardInput,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }
}
