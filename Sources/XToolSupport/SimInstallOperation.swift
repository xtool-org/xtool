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
            let xLoadPath = if let xLoadLibrary {
                URL(filePath: xLoadLibrary)
            } else {
                try await getXLoad(platform: "iphonesimulator")
            }

            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            guard let temporaryDirectoryPath = FilePath(tmp) else {
                throw Console.Error("Bad temporaryDirectory path")
            }

            let buildDirectory = temporaryDirectoryPath.appending("build")
            try FileManager.default.createDirectory(at: URL(filePath: buildDirectory)!, withIntermediateDirectories: true)

            let outDirectory = temporaryDirectoryPath.appending("out")
            try FileManager.default.createDirectory(at: URL(filePath: outDirectory)!, withIntermediateDirectories: true)

            watchTask = Task {
                do {
                    try await watch(buildDirectory: buildDirectory, outDirectory: outDirectory)
                } catch {
                    print("Error: watch task failed: \(error)")
                }
            }

            envVars = [
                "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": xLoadPath.path,
                "SIMCTL_CHILD_XLOAD_WATCH_DIR": outDirectory.string,
                "SIMCTL_CHILD_XLOAD_INTERCEPT": "1",
            ]
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
            output: .standardOutput,
            error: .standardError,
        )
        .checkSuccess()

        watchTask?.cancel()
        try await watchTask?.value
    }

    private func watch(
        buildDirectory: FilePath,
        outDirectory: FilePath,
    ) async throws {
        let settings = try await operation.buildSettings()
        let workspace = try await SwiftWorkspace(
            buildDirectory: buildDirectory,
            outDirectory: outDirectory,
            buildSettings: settings,
        )

        @Dependency(\.fileSystemMonitor) var fileSystemMonitor
        let events = try await fileSystemMonitor.watch(FilePath(FileManager.default.currentDirectoryPath))

        for await event in events {
            do {
                try await workspace.fileDidChange(event.file)
            } catch {
                print("Reload failed: \(error)")
            }
        }
    }

    private func getXLoad(platform: String) async throws -> URL {
        let version = "0.3.0"
        let remote = URL(string: "https://github.com/xtool-org/xload/releases/download/v\(version)/libXLoad.\(platform).dylib")!

        @Dependency(\.httpClient) var httpClient
        @Dependency(\.persistentDirectory) var persistentDirectory

        let platformDir = persistentDirectory.appending(path: "xload/\(platform)")
        let versionDir = platformDir.appending(path: version)
        let local = versionDir.appending(path: "libXLoad.dylib")
        if local.exists { return local }

        print("Downloading xload...")

        try? FileManager.default.removeItem(at: platformDir)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)

        let data = try await httpClient.makeRequest(HTTPRequest(url: remote))
        guard data.response.status.kind == .successful else {
            throw StringError("Failed to download xload: got HTTP \(data.response.status)")
        }
        try data.body.write(to: local)

        return local
    }
}
#endif
