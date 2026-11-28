import ArgumentParser
import Foundation
import XCLIUtils
import XUtils

struct EmulateToolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_emulate",
        abstract: "Emulate a build tool",
        shouldDisplay: false,
    )

    @Argument(help: "The name of the tool to emulate")
    var toolName: String

    @Argument(
        parsing: .captureForPassthrough,
        help: "The arguments to pass to the emulated tool",
    )
    var arguments: [String] = []

    func run() async throws {
        let result = try await d.emulatedTools.execute(
            commandLine: [toolName] + arguments,
            workingDirectory: nil,
            environment: ProcessInfo.processInfo.environment,
        )
        let status: EmulatedToolExitStatus
        switch result {
        case .deferred:
            throw Console.Error("Unable to emulate tool \(toolName)")
        case .result(let exitStatus, let stdout, let stderr):
            d.out.write(stdout, .stdout, true)
            d.out.write(stderr, .stderr, true)
            status = exitStatus
        }
        switch status {
        case .exit(0):
            break
        case .exit(let code):
            throw ExitCode(code)
        case .uncaughtSignal(let signal):
            throw Console.Error("Tool \(toolName) terminated with signal \(signal)")
        }
    }
}
