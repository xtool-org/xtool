import Foundation
import XUtils
import Subprocess
import Superutils

public struct DarwinSDK {
    public enum Flavor {
        // can't be updated in place
        case slim
        // can be updated in place, includes a whole copy of Xcode.app
        case normal
        // from before the slim/normal split existed (version "develop")
        case legacy
    }

    public let bundle: URL
    public let version: String
    public let flavor: Flavor

    static func swiftPMDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if let configurationDirectory = environment["XDG_CONFIG_HOME"] {
            guard (configurationDirectory as NSString).isAbsolutePath else {
                throw StringError("XDG_CONFIG_HOME must be an absolute path: '\(configurationDirectory)'")
            }
            return URL(fileURLWithPath: configurationDirectory, isDirectory: true)
                .appendingPathComponent("swiftpm", isDirectory: true)
        } else {
            return homeDirectory.appendingPathComponent(".swiftpm", isDirectory: true)
        }
    }

    private static var swiftSDKsDirectory: URL {
        get throws {
            try swiftPMDirectory().appendingPathComponent("swift-sdks", isDirectory: true)
        }
    }

    public init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ["darwin.xtoolsdk", "darwin.artifactbundle"].contains(bundle.lastPathComponent) {
            self.version = "develop"
        } else {
            return nil
        }

        if version == "develop" {
            self.flavor = .legacy
        } else if bundle.appendingPathComponent("Xcode.app").dirExists {
            self.flavor = .normal
        } else {
            self.flavor = .slim
        }
    }

    public static func install(from path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard DarwinSDK(bundle: url) != nil else { throw StringError("Invalid Darwin SDK at '\(path)'")}

        try await addHostClangResourceDir(to: url)

        let sdksDirectory = try swiftSDKsDirectory
        try FileManager.default.createDirectory(
            at: sdksDirectory,
            withIntermediateDirectories: true
        )
        let destination = sdksDirectory.appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        try await movePreservingHardLinks(from: url, to: destination)
    }

    private static func copyPreservingHardLinks(from source: URL, to destination: URL) async throws {
        try await Subprocess.run(
            .name("cp"),
            arguments: ["-a", source.path, destination.path],
            output: .discarded
        )
        .checkSuccess()
    }

    private static func movePreservingHardLinks(from source: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        let destinationAttributes = try fileManager.attributesOfItem(
            atPath: destination.deletingLastPathComponent().path
        )
        let sourceSystem = sourceAttributes[.systemNumber] as? NSNumber
        let destinationSystem = destinationAttributes[.systemNumber] as? NSNumber

        if let sourceSystem, let destinationSystem, sourceSystem == destinationSystem {
            try fileManager.moveItem(at: source, to: destination)
        } else {
            try await copyPreservingHardLinks(from: source, to: destination)
            try fileManager.removeItem(at: source)
        }
    }

    private static func addHostClangResourceDir(to sdk: URL) async throws {
        let clangURL = try await ToolRegistry.locate("clang")
        let process = try await Subprocess.run(
            .path(FilePath(clangURL.path)),
            arguments: ["-print-resource-dir"],
            output: .string(limit: .max)
        ).checkSuccess()
        let output = process.standardOutput ?? ""
        let hostClangResources = URL(filePath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        let hostInclude = hostClangResources.appending(path: "include")
        let sdkInclude = sdk.appending(path: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include")
        try await FileManager.default.copyItem(at: hostInclude, to: sdkInclude, preserveOwner: false)
    }

    public static func current() throws -> DarwinSDK? {
        let bundle = try swiftSDKsDirectory.appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        guard bundle.dirExists else { return nil }
        return DarwinSDK(bundle: bundle)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }
}
