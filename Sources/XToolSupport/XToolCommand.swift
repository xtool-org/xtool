import Foundation
import XKit
import ArgumentParser

public enum XTool {
    public static func run(arguments: [String]? = nil) async throws {
        await XToolCommand.cancellableMain(arguments)
    }
}

struct XToolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xtool",
        abstract: "Cross-platform Xcode replacement",
        version: XTool.version?.description ?? "unknown",
        groupedSubcommands: [
            CommandGroup(
                name: "Configuration",
                subcommands: [
                    SetupCommand.self,
                    AuthCommand.self,
                    SDKCommand.self,
                ]
            ),
            CommandGroup(
                name: "Development",
                subcommands: [
                    NewCommand.self,
                    DevCommand.self,
                    DSCommand.self,
                ]
            ),
            CommandGroup(
                name: "Device",
                subcommands: [
                    DevicesCommand.self,
                    InstallCommand.self,
                    UninstallCommand.self,
                    LaunchCommand.self,
                ]
            )
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
                var command = try self.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch where error is CancellationError || Task.isCancelled {
                print("Cancelled.")
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
