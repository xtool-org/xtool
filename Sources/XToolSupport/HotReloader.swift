#if os(macOS)

import Foundation
import Dependencies
import FileSystemMonitoring
import Subprocess
import XCLIUtils
import XKit
import XUtils

/// Recompiles Swift files as they're edited and hands the results to xload,
/// which interposes the new implementations into the running app.
///
/// The app must be built with `BuildCoordinator(hotReloadable: true)`.
actor HotReloader {
    private struct WatchedFile {
        var source: BuildCoordinator.SourceFile
        var modificationDate: Date?
    }

    private let coordinator: BuildCoordinator
    private let xloadPath: String
    private let stagingDirectory: URL
    private let outputDirectory: URL

    /// Keyed by canonical path.
    private var files: [String: WatchedFile]
    private var commands: [String: BuildCoordinator.RecompileCommand] = [:]
    /// The latest dylib for each file, keyed by canonical path.
    private var dylibs: [String: URL] = [:]
    private var counter = 0

    init(coordinator: BuildCoordinator, xloadPath: String? = nil) async throws {
        self.coordinator = coordinator

        self.xloadPath = if let xloadPath {
            URL(filePath: xloadPath).absoluteURL.path
        } else {
            try await Self.fetchXLoad(platform: "iphonesimulator").path
        }

        let scratch = URL(filePath: "xtool/.xtool-tmp/HotReload").absoluteURL
        try? FileManager.default.removeItem(at: scratch)
        stagingDirectory = scratch.appending(path: "Staging")
        outputDirectory = scratch.appending(path: "Products")
        for directory in [stagingDirectory, outputDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var files: [String: WatchedFile] = [:]
        for source in try await coordinator.sourceFiles() where source.language == .swift {
            // if a file belongs to multiple targets, arbitrarily pick the first
            guard let path = Self.canonicalPath(source.path), files[path] == nil else { continue }
            files[path] = WatchedFile(source: source, modificationDate: Self.modificationDate(path))
        }
        self.files = files
    }

    /// Environment variables to pass to `simctl launch` to enable hot reloading.
    nonisolated var launchEnvironment: [Environment.Key: String] {
        [
            "SIMCTL_CHILD_DYLD_INSERT_LIBRARIES": xloadPath,
            "SIMCTL_CHILD_XLOAD_WATCH_DIR": outputDirectory.path,
            "SIMCTL_CHILD_XLOAD_INTERCEPT": "1",
        ]
    }

    /// Watches for changes until cancelled.
    func watch() async throws {
        // TODO: handle files being added or removed
        let events = try await d.fileSystemMonitor.watch(FilePath(FileManager.default.currentDirectoryPath))
        d.out.print("Watching for changes...")
        for await event in events {
            guard let path = Self.canonicalPath(event.file.string), let file = files[path] else { continue }
            // a single save often produces multiple events
            let modificationDate = Self.modificationDate(path)
            guard modificationDate != file.modificationDate else { continue }
            files[path]?.modificationDate = modificationDate

            do {
                try await reload(path: path, source: file.source)
            } catch is CancellationError {
                break
            } catch {
                d.out.print("Failed to reload \(URL(filePath: path).lastPathComponent): \(error)")
            }
        }
    }

    private func reload(path: String, source: BuildCoordinator.SourceFile) async throws {
        counter += 1

        let url = URL(filePath: path)
        d.out.print("[Reload #\(counter)] Updating \(url.lastPathComponent)")
        let start = ContinuousClock.now

        let command = try await recompileCommand(path: path, source: source)
        try await Subprocess.run(
            .path(FilePath(command.commandLine[0])),
            arguments: Arguments(Array(command.commandLine.dropFirst())),
            output: .xtoolOutput(),
            error: .xtoolError(),
        )
        .checkSuccess()
        try MachOSymbolExporter.exportHiddenSwiftSymbols(in: URL(filePath: command.objectFile))

        let dylibName = "lib\(url.deletingPathExtension().lastPathComponent).\(counter).dylib"
        let stagedDylib = stagingDirectory.appending(path: dylibName)
        try await Subprocess.run(
            .path(swiftc(for: source)),
            arguments: [
                command.objectFile,
                "-emit-library",
                "-sdk", command.sdk,
                "-target", command.target,
                // resolve references to the rest of the app at load time
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                "-o", stagedDylib.path,
            ],
            output: .xtoolOutput(),
            error: .xtoolError(),
        )
        .checkSuccess()

        let elapsed = (ContinuousClock.now - start)
            .formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        d.out.print("[Reload #\(counter)] Built in \(elapsed)")

        // xload loads new dylibs as soon as they appear, so they have to show up atomically
        let dylib = outputDirectory.appending(path: dylibName)
        try FileManager.default.moveItem(at: stagedDylib, to: dylib)
        // Loaded dylibs stay mapped, so the previous version is no longer needed. If xload
        // hasn't loaded it yet, it's superseded by this one anyway.
        if let previous = dylibs.updateValue(dylib, forKey: path) {
            try? FileManager.default.removeItem(at: previous)
        }
    }

    private func recompileCommand(
        path: String,
        source: BuildCoordinator.SourceFile
    ) async throws -> BuildCoordinator.RecompileCommand {
        if let cached = commands[path] { return cached }
        let command = try await coordinator.recompileCommand(for: source)
        commands[path] = command
        return command
    }

    private func swiftc(for source: BuildCoordinator.SourceFile) async throws -> FilePath {
        if let toolchain = source.toolchain {
            let swiftc = FilePath(toolchain).appending("usr/bin/swiftc")
            if FileManager.default.isExecutableFile(atPath: swiftc.string) { return swiftc }
        }
        return try await d.toolchain.swiftTool.removingLastComponent().appending("swiftc")
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func modificationDate(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func fetchXLoad(platform: String) async throws -> URL {
        let version = "0.4.1"
        let platformDirectory = d.persistentDirectory.appending(path: "xload/\(platform)")
        let local = platformDirectory.appending(path: "\(version)/libXLoad.dylib")
        if FileManager.default.fileExists(atPath: local.path) { return local }

        d.out.print("Downloading xload...")
        let remote = URL(
            string: "https://github.com/xtool-org/xload/releases/download/v\(version)/libXLoad.\(platform).dylib"
        )!
        let (_, body) = try await d.httpClient.makeRequest(HTTPRequest(url: remote))

        // clear out old versions
        try? FileManager.default.removeItem(at: platformDirectory)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: local, options: .atomic)
        return local
    }
}

#endif
