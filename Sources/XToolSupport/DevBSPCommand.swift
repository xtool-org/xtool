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

    @Option(help: "Target triple; overrides xtool.yml target, otherwise defaults to arm64-apple-ios")
    var triple: String?

    func run() async throws {
        guard try await SwiftVersion.current.supportsSwiftBuild else {
            throw Console.Error("`xtool dev build-server` requires Swift 6.4 or later")
        }
        let request = try await DevBuildRequest.load(cliTriple: triple)
        let (settings, _) = try await EditorTarget.buildSettings(request: request)
        try await Subprocess.run(
            settings.buildServerInvocation(),
            input: .currentStandardInput,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }
}
