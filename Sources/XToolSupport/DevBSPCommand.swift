import XCLIUtils
import ArgumentParser
import XUtils
import Dependencies

struct DevBSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-server",
        abstract: "Run build server",
    )

    @Option
    var triple: String?

    func run() async throws {
        let transport = BSPCommandTransport()
        // Only BSP frames may be written to the client's stdout.
        try await withDependencies {
            let output = $0.out
            $0.out = CommandOutput { data, _, flush in output.write(data, .stderr, flush) }
        } operation: {
            let server = XToolBuildServer(
                triple: triple ?? PackOperation.defaultTriple,
                connectionToClient: transport.connection,
                exitHandler: { _ in transport.connection.close() }
            )
            defer { await server.close() }
            try await transport.run(receiveHandler: server)
        }
    }
}
