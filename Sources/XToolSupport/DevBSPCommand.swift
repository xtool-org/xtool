import XCLIUtils
import ArgumentParser

struct DevBSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-server",
        abstract: "Run build server",
    )

    @Option
    var triple: String?

    func run() async throws {
        throw Console.Error("Stub")
    }
}
