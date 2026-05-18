#if os(macOS)
import Subprocess
import PackLib
import Foundation
import XUtils
import Dependencies
import XKit

struct SimInstallOperation {
    var operation: PackOperation
    var plan: Plan
    var path: URL

    var watch = false
    var xLoadLibrary: String?

    // TODO: allow customizing this
    var simulator = "booted"

    func run() async throws {
        try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["simctl", "install", simulator, path.path],
            output: .discarded
        )
        .checkSuccess()

        print("Installed to simulator")

        let tmp = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "xtool/.xload")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let watchTask: Task<Void, Error>?
        let envVars: [Environment.Key: String?]
        if watch {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard let temporaryDirectoryPath = FilePath(tmp) else {
                throw Console.Error("Bad temporaryDirectory path")
            }

            let hotReloader = try await HotReloader(
                configuration: .swiftPM(settings: operation.buildSettings()),
                scratchDirectory: temporaryDirectoryPath,
                xLoadLibrary: xLoadLibrary
            )

            watchTask = Task {
                do {
                    try await hotReloader.watch()
                } catch {
                    print("Error: watch task failed: \(error)")
                }
            }

            envVars = hotReloader.subprocessEnvironment()
        } else {
            watchTask = nil
            envVars = [:]
        }

        try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: [
                "simctl", "launch",
                "--console-pty",
                simulator, plan.app.bundleID,
            ],
            environment: .inherit.updating(envVars),
            platformOptions: .withGracefulShutDown,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()

        watchTask?.cancel()
        try await watchTask?.value
    }
}
#endif
