import Foundation
import XUtils
import Subprocess
import Superutils

public struct DarwinSDK: Sendable {
    package struct TemporaryBundle: ~Copyable {
        package let url: URL

        fileprivate init(url: URL) {
            self.url = url
        }

        package consuming func install() async throws {
            guard DarwinSDK(bundle: url) != nil else {
                throw StringError("Invalid Darwin SDK at '\(url.path)'")
            }

            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("darwin.xtoolsdk", isDirectory: true)
            try FileManager.default.moveItem(at: url, to: destination)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public enum Flavor: Sendable {
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

    package var developerDirectory: URL {
        bundle.appendingPathComponent("Xcode.app/Contents/Developer", isDirectory: true)
    }

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
        } else if [
            "darwin.xtoolsdk", "darwin.xtoolsdk.tmp", "darwin.artifactbundle", "darwin.artifactbundle.tmp",
        ].contains(bundle.lastPathComponent) {
            self.version = "develop"
        } else {
            return nil
        }

        let xcodeApp = bundle.appendingPathComponent("Xcode.app", isDirectory: true)
        let slimMarker = bundle.appendingPathComponent("slim-marker", isDirectory: false).path

        if version == "develop" {
            self.flavor = .legacy
        } else if xcodeApp.dirExists && !FileManager.default.fileExists(atPath: slimMarker) {
            self.flavor = .normal
        } else {
            self.flavor = .slim
        }
    }

    package static func prepareTemporaryBundle() throws -> TemporaryBundle {
        let directory = d.persistentDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundle = directory.appendingPathComponent("darwin.xtoolsdk.tmp", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.removeItem(at: bundle)
        }
        return TemporaryBundle(url: bundle)
    }

    public static func current() throws -> DarwinSDK? {
        try current(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func current(
        environment: [String: String],
        homeDirectory: URL
    ) throws -> DarwinSDK? {
        let bundle = d.persistentDirectory.appendingPathComponent("darwin.xtoolsdk", isDirectory: true)
        if !bundle.dirExists {
            let legacyBundle = try swiftSDKsDirectory(environment: environment, homeDirectory: homeDirectory)
                .appendingPathComponent("darwin.artifactbundle", isDirectory: true)
            guard legacyBundle.dirExists else { return nil }
            try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: legacyBundle, to: bundle)
        }
        return DarwinSDK(bundle: bundle)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }
}
