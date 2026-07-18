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
