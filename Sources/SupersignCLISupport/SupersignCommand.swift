import Foundation
import Supersign
import ArgumentParser

public enum SupersignCLI {
    public struct Configuration: Sendable {
        public let superchargeApp: URL?
        public let storage: KeyValueStorage

        public init(
            superchargeApp: URL?,
            storage: KeyValueStorage
        ) {
            self.superchargeApp = superchargeApp
            self.storage = storage
        }
    }

    private static nonisolated(unsafe) var _config: Configuration!
    static var config: Configuration { _config }

    public static func run(configuration: Configuration, arguments: [String]? = nil) async throws {
        _config = configuration
        await SupersignCommand.cancellableMain(arguments)
    }
}

struct SupersignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersign",
        abstract: "The Supersign command line tool",
        subcommands: [
            AuthCommand.self,
            DSCommand.self,
            DevicesCommand.self,
            InstallCommand.self,
            UninstallCommand.self,
            DevCommand.self,
            // no Supercharge support... yet...
            // SuperchargeCommand.self,
            RunCommand.self,
        ]
    )
}

extension ParsableCommand {
    fileprivate static func cancellableMain(_ arguments: [String]? = nil) async {
        let (canStart, cont) = AsyncStream.makeStream(of: Never.self)
        let task = Task {
            for await _ in canStart {}
            guard !Task.isCancelled else { return }
            do {
                var command = try self.parseAsRoot()
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch is CancellationError {
                self.exit()
            } catch {
                self.exit(withError: error)
            }
        }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler { task.cancel() }
        source.resume()

        cont.finish()

        await task.value
    }
}
