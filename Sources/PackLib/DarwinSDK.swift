import Foundation
import XUtils
import Subprocess
import Superutils

public struct DarwinSDK {
    package struct TemporaryBundle: ~Copyable {
        package let url: URL

        fileprivate init(url: URL) {
            self.url = url
        }

        package consuming func install() async throws {
            guard DarwinSDK(bundle: url) != nil else {
                throw StringError("Invalid Darwin SDK at '\(url.path)'")
            }

            try await DarwinSDK.addHostClangResourceDir(to: url)

            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("darwin.artifactbundle", isDirectory: true)
            try FileManager.default.moveItem(at: url, to: destination)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

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

    private static func swiftSDKsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        try swiftPMDirectory(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("swift-sdks", isDirectory: true)
    }

    public init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ["darwin.xtoolsdk", "darwin.artifactbundle", "darwin.artifactbundle.tmp"].contains(bundle.lastPathComponent) {
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

    package static func prepareTemporaryBundle(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> TemporaryBundle {
        let sdksDirectory = try swiftSDKsDirectory(environment: environment, homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: sdksDirectory, withIntermediateDirectories: true)
        let bundle = sdksDirectory.appendingPathComponent("darwin.artifactbundle.tmp", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.removeItem(at: bundle)
        }
        return TemporaryBundle(url: bundle)
    }

    private static func addHostClangResourceDir(to sdk: URL) async throws {
        struct SwiftTargetInfo: Decodable {
            struct Paths: Decodable {
                let runtimeResourcePath: String
            }
            let paths: Paths
        }

        let process = try await Subprocess.run(
            .path(try await BuildSettings.swiftcURL()),
            arguments: ["-print-target-info"],
            output: .data(limit: .max)
        ).checkSuccess()
        let targetInfo = try JSONDecoder().decode(
            SwiftTargetInfo.self,
            from: process.standardOutput
        )
        let hostClangResources = URL(filePath: targetInfo.paths.runtimeResourcePath).appending(path: "clang")
        let hostInclude = hostClangResources.appending(path: "include")
        let sdkInclude = sdk.appending(path: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include")
        try await FileManager.default.copyItem(at: hostInclude, to: sdkInclude, preserveOwner: false)
    }

    public static func current() throws -> DarwinSDK? {
        let bundle = try swiftSDKsDirectory().appendingPathComponent("darwin.artifactbundle", isDirectory: true)
        guard bundle.dirExists else { return nil }
        return DarwinSDK(bundle: bundle)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }
}
