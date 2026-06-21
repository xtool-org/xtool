import Foundation
import ArgumentParser
import PackLib
import XUtils
import Subprocess

struct HotReloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hot-reload",
        abstract: "Run an app with support for hot reloading",
    )

    @Flag(
        help: "Use the SwiftPM build system to determine compile commands"
    ) var swiftpm = false

    @Option(
        help: .init(
            "Use the specified Build Server to determine compile commands",
            discussion: """
            The file at the specified path should correspond to the BSP \
            Connection Details specification. See:
            
            https://build-server-protocol.github.io/docs/overview/server-discovery
            """,
        )
    ) var buildServerPath: String?

    @Option(
        help: "The directory in which to store scratch files"
    ) var scratchDirectory: String?

    @Option(
        help: "String to prepend to all env var names"
    ) var envPrefix: String = ""

    @Option(
        help: .hidden
    ) var xloadLibrary: String?

    @Argument(
        help: .init(
            "The command to run with hot reloading",
            discussion: """
            xtool spawns the provided process with env vars set to enable hot reloading.
            """
        )
    ) var command: [String]

    func run() async throws {
        let configuration: BuildServerConfiguration
        switch (swiftpm, buildServerPath) {
        case (true, _?):
            throw ValidationError("Both --swiftpm or --build-server-path were provided; please only provide one.")
        case (true, nil):
            configuration = try await .swiftPM(settings: BuildSettings(configuration: .debug, triple: "arm64-apple-ios-simulator"))
        case (false, let serverPath?):
            configuration = try await .external(definition: URL(filePath: serverPath))
        case (false, nil):
            if let discovered = try await BuildServerConfiguration.discover(in: URL(filePath: ".")) {
                configuration = discovered
            } else {
                throw ValidationError("Could not guess build system. Please specify one with --swiftpm or --build-server-path")
            }
        }

        let reloader = try await HotReloader(
            configuration: configuration,
            scratchDirectory: scratchDirectory.map { FilePath($0) },
            xLoadLibrary: xloadLibrary
        )

        let watchTask = Task {
            do {
                try await reloader.watch()
            } catch {
                print("Error: watcher failed: \(error)")
            }
        }

        var arguments = command
        let executable = arguments.removeFirst()

        try await Subprocess.run(
            .name(executable),
            arguments: Arguments(arguments),
            environment: .inherit.updating(reloader.subprocessEnvironment(prefix: envPrefix)),
            platformOptions: .withGracefulShutDown,
            output: .standardOutput,
            error: .standardError,
        )
        .checkSuccess()

        watchTask.cancel()
        await watchTask.value
    }
}
