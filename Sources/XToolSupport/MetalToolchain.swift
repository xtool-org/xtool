import Foundation
import Subprocess
import Dependencies
import XUtils
import ArgumentParser

struct MetalToolchainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metal-toolchain",
        abstract: "Manage the Metal toolchain on Linux",
        subcommands: [
            MetalToolchainInstallCommand.self,
            MetalToolchainUninstallCommand.self,
            MetalToolchainStatusCommand.self,
        ],
    )
}

struct MetalToolchainInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Metal toolchain",
    )

    @Argument(
        help: """
        Path to Metal installer exe: get it from https://developer.apple.com/download/all/?q=metal%20developer%20tools%20for%20windows
        """,
        completion: .file(extensions: ["exe"]),
    )
    var installerPath: String

    func run() async throws {
        #if os(macOS)
        d.out.print("This command is not supported on macOS, use `xcodebuild -downloadComponent metalToolchain`")
        #else
        try await MetalToolchainManager.shared.install(installerPath: installerPath)
        #endif
    }
}

struct MetalToolchainUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall the Metal toolchain",
    )

    func run() async throws {
        #if os(macOS)
        d.out.print("This command is not supported on macOS, use `xcodebuild -deleteComponent metalToolchain`")
        #else
        if try MetalToolchainManager.shared.uninstall() {
            d.out.print("Uninstalled Metal toolchain")
        } else {
            d.out.print("Metal toolchain is not installed")
        }
        #endif
    }
}

struct MetalToolchainStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether the Metal toolchain is installed",
    )

    func run() async throws {
        #if os(macOS)
        d.out.print("This command is not supported on macOS, use `xcodebuild -showComponent metalToolchain`")
        #else
        let manager = MetalToolchainManager.shared
        guard manager.isInstalled else {
            d.out.print("Metal toolchain status: not installed")
            return
        }
        d.out.print("""
        Metal toolchain status: installed
        Path: \(manager.toolsDirectory.path)
        """)
        let version = try await manager.metalVersion()
        d.out.print("Version: \(version)")
        #endif
    }
}

struct MetalToolchainManager {
    static let shared = MetalToolchainManager()

    private init() {}

    #if os(macOS)
    func metalCommand(
        _ arguments: [String],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        skipInstallCheck: Bool = false,
    ) async throws -> Subprocess.Configuration {
        // SwiftBuild needs some help finding Metal: it's installed via a cryptex
        // on macOS, which `xcrun -f` can help us locate. If the Metal toolchain
        // isn't installed, this points to a stub in XcodeDefault.xctoolchain,
        // which exits with an error instructing to install the toolchain.
        try await Subprocess.Configuration.init(
            executable: .path(MetalLocator.shared.path()),
            arguments: Arguments(arguments),
            environment: environment,
            workingDirectory: workingDirectory,
            platformOptions: .withGracefulShutDown,
        )
    }

    private actor MetalLocator {
        static let shared = MetalLocator()
        private init() {}

        // we don't cache failures, so that if the user installs the
        // toolchain later then we can retry successfully
        private var cachedPath: FilePath?

        func path() async throws -> FilePath {
            if let cachedPath { return cachedPath }
            // this is re-entrant but that's okay
            let found = try await Subprocess.run(
                .path("/usr/bin/xcrun"),
                arguments: ["-f", "metal"],
                output: .string(limit: .max),
            )
            .checkSuccess()
            .standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            let foundPath = FilePath(found)
            cachedPath = foundPath
            return foundPath
        }
    }
    #else
    func metalCommand(
        _ arguments: [String],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
        skipInstallCheck: Bool = false,
    ) async throws -> Subprocess.Configuration {
        guard skipInstallCheck || isInstalled else {
            throw Console.Error("""
            Metal toolchain was requested but is not installed. Set it up with
              xtool metal-toolchain install
            """)
        }
        return try await wineCommand(
            [metalBin.path] + arguments,
            environment: environment,
            workingDirectory: workingDirectory,
        )
    }

    private var directory: URL {
        d.persistentDirectory.appending(path: "metal")
    }

    private var installMarker: URL {
        directory.appending(path: "installed")
    }

    private var winePrefix: URL {
        directory.appending(path: "wine")
    }

    var toolsDirectory: URL {
        winePrefix.appending(path: "drive_c/Program Files/Metal Developer Tools")
    }

    private var metalBin: URL {
        toolsDirectory.appending(path: "bin/metal.exe")
    }

    fileprivate var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installMarker.path)
    }

    private func wineCommand(
        _ arguments: [String],
        environment: Environment = .inherit,
        workingDirectory: FilePath? = nil,
    ) async throws -> Subprocess.Configuration {
        let winePath: FilePath
        do {
            winePath = try await Executable.name("wine").resolveExecutablePath(in: environment)
        } catch let error where error.code == .executableNotFound {
            throw Console.Error("xtool could not locate Wine. Please install it first.")
        }
        return Subprocess.Configuration(
            executable: .path(winePath),
            arguments: Arguments(arguments),
            environment: environment.updating([
                "WINEPREFIX": winePrefix.path,
            ]),
            workingDirectory: workingDirectory,
            platformOptions: .withGracefulShutDown,
        )
    }

    fileprivate func metalVersion(skipInstallCheck: Bool = false) async throws -> String {
        let out = try await Subprocess.run(
            metalCommand(["--version"], skipInstallCheck: skipInstallCheck),
            output: .string(limit: .max),
        )
        .checkSuccess()
        .standardOutput
        guard out.hasPrefix("Apple metal version") else {
            throw Console.Error("metal --version failed")
        }
        return String(out.split(separator: "\n")[0])
    }

    fileprivate func install(installerPath: String) async throws {
        guard FileManager.default.fileExists(atPath: installerPath) else {
            throw Console.Error("Installer not found at '\(installerPath)': no such file or directory")
        }
        try uninstall()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        d.out.print("Initializing Wine")
        try await Subprocess.run(
            wineCommand([#"C:\Windows\System32\cmd.exe"#, "/c", "exit", "0"]),
            output: .discarded,
        )
        .checkSuccess()
        d.out.print("Running Metal installer. This might take a few minutes.")
        try await Subprocess.run(
            wineCommand([installerPath, "/S"]),
            output: .discarded,
        )
        .checkSuccess()
        d.out.print("Metal installer completed")
        let version = try await metalVersion(skipInstallCheck: true)
        try Data().write(to: installMarker)
        d.out.print("Installed \(version)")
    }

    /// Returns true if there was something to uninstall
    @discardableResult
    fileprivate func uninstall() throws -> Bool {
        try? FileManager.default.removeItem(at: installMarker)
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            return false
        }
        return true
    }
    #endif
}
