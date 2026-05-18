#if os(macOS)

import Subprocess
import PackLib
import Foundation
import XUtils
import Dependencies
import XKit

actor HotReloader {
    var configuration: BuildServerConfiguration
    var scratchDirectory: FilePath
    var xLoadLibrary: String?

    private let scratchTemporaryDirectory: TemporaryDirectory?
    private let xLoadPath: String
    private let buildDirectory: FilePath
    private let outDirectory: FilePath

    init(
        configuration: BuildServerConfiguration,
        scratchDirectory: FilePath? = nil,
        xLoadLibrary: String? = nil,
    ) async throws {
        self.configuration = configuration

        if let scratchDirectory {
            self.scratchDirectory = FilePath(URL(filePath: scratchDirectory.string).absoluteURL.path)
            self.scratchTemporaryDirectory = nil
        } else {
            let scratchTemporaryDirectory = try TemporaryDirectory(name: "scratch")
            self.scratchDirectory = FilePath(scratchTemporaryDirectory.url.path)
            self.scratchTemporaryDirectory = consume scratchTemporaryDirectory
        }

        self.xLoadLibrary = xLoadLibrary

        xLoadPath = if let xLoadLibrary {
            URL(filePath: xLoadLibrary).absoluteURL.path
        } else {
            try await Self.getXLoad(platform: "iphonesimulator").path
        }

        buildDirectory = self.scratchDirectory.appending("build")
        try FileManager.default.createDirectory(at: URL(filePath: buildDirectory)!, withIntermediateDirectories: true)

        outDirectory = self.scratchDirectory.appending("out")
        try FileManager.default.createDirectory(at: URL(filePath: outDirectory)!, withIntermediateDirectories: true)
    }

    nonisolated func environment(prefix: String = "SIMCTL_CHILD_") -> [String: String] {
        [
            "\(prefix)DYLD_INSERT_LIBRARIES": xLoadPath,
            "\(prefix)XLOAD_WATCH_DIR": outDirectory.string,
            "\(prefix)XLOAD_INTERCEPT": "1",
        ]
    }

    nonisolated func subprocessEnvironment(prefix: String = "SIMCTL_CHILD_") -> [Environment.Key: String] {
        Dictionary(uniqueKeysWithValues: environment(prefix: prefix).map {
            (Environment.Key(rawValue: $0)!, $1)
        })
    }

    func watch() async throws {
        let workspace = try await SwiftWorkspace(
            configuration: configuration,
            buildDirectory: buildDirectory,
            outDirectory: outDirectory,
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

    private static func getXLoad(platform: String) async throws -> URL {
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
