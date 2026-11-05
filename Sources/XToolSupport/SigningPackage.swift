import Foundation
import Dependencies
import XKit
import XUtils

/// Owns the disposable copy used for signing. The caller's input is never modified.
struct SigningPackage: ~Copyable {
    private let directory: TemporaryDirectory
    let app: URL
    let platform: SigningPlatform

    init(input: URL, output: URL, platform requestedPlatform: SigningPlatform?) async throws {
        let input = input.standardizedFileURL.resolvingSymlinksInPath()
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        try Self.validateOutput(output)
        guard output != input, !output.path.hasPrefix(input.path + "/") else {
            throw PackageError("Output must be outside the input app.")
        }

        let directory = try TemporaryDirectory(name: "signing")
        let payload = directory.url.appendingPathComponent("Payload")
        switch input.pathExtension.lowercased() {
        case "app":
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: input, to: payload.appendingPathComponent(input.lastPathComponent))
        case "ipa":
            @Dependency(\.zipCompressor) var compressor
            try await compressor.decompress(file: input, in: directory.url, progress: { _ in })
        default:
            throw PackageError("Input must be an .app directory or .ipa archive.")
        }
        try Self.validateSymlinks(in: directory.url)

        let apps = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw PackageError("Expected exactly one app in Payload.")
        }
        guard app.resolvingSymlinksInPath().path.hasPrefix(payload.path + "/") else {
            throw PackageError("The app must be contained in Payload.")
        }
        let info = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty,
              let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/")
        else { throw PackageError("The app needs a valid bundle identifier and executable in Info.plist.") }
        let executableURL = app.appendingPathComponent(executable).resolvingSymlinksInPath()
        guard executableURL.path.hasPrefix(app.path + "/"), FileManager.default.fileExists(atPath: executableURL.path) else {
            throw PackageError("The app executable is missing or outside the app.")
        }
        self.platform = try Self.detectPlatform(plist: plist, requested: requestedPlatform)
        self.app = app
        self.directory = directory
    }

    private static func detectPlatform(plist: [String: Any], requested: SigningPlatform?) throws -> SigningPlatform {
        var platformMetadata: SigningPlatform?
        if let value = plist["CFBundleSupportedPlatforms"] {
            guard let platforms = value as? [String], !platforms.isEmpty else {
                throw PackageError("Invalid CFBundleSupportedPlatforms metadata.")
            }
            switch platforms {
            case ["AppleTVOS"]: platformMetadata = .tvOS
            case ["iPhoneOS"]: platformMetadata = .iOS
            default: throw PackageError("Only iOS and tvOS device apps can be signed.")
            }
        }
        var familyMetadata: SigningPlatform?
        if let value = plist["UIDeviceFamily"] {
            guard let families = value as? [Int], !families.isEmpty else {
                throw PackageError("Invalid UIDeviceFamily metadata.")
            }
            if families == [3] {
                familyMetadata = .tvOS
            } else if families.allSatisfy({ [1, 2].contains($0) }) {
                familyMetadata = .iOS
            } else {
                throw PackageError("Unsupported device family.")
            }
        }
        if let platformMetadata, let familyMetadata, platformMetadata != familyMetadata {
            throw PackageError("The app's platform and device family do not agree.")
        }
        let detected = platformMetadata ?? familyMetadata
        if let detected, let requested, detected != requested {
            throw PackageError("The requested platform does not match the app.")
        }
        guard let platform = detected ?? requested else {
            throw PackageError("Cannot determine the platform. Specify --platform ios or --platform tvos.")
        }
        return platform
    }

    private static func validateSymlinks(in directory: URL) throws {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { throw PackageError("Cannot inspect the staged app.") }
        let root = directory.resolvingSymlinksInPath().path
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = entry.resolvingSymlinksInPath().path
                guard target == root || target.hasPrefix(root + "/") else {
                    throw PackageError("App symlinks must stay inside the staged copy: \(entry.lastPathComponent)")
                }
            }
        }
    }

    private static func validateOutput(_ output: URL) throws {
        guard ["app", "ipa"].contains(output.pathExtension.lowercased()) else {
            throw PackageError("Output must have an .app or .ipa extension.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw PackageError("Output already exists: \(output.path)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PackageError("The output's parent directory must exist.")
        }
    }

    borrowing func export(to output: URL) async throws {
        try Self.validateOutput(output)
        let artifact: URL
        if output.pathExtension.lowercased() == "app" {
            artifact = app
        } else {
            @Dependency(\.zipCompressor) var compressor
            artifact = try await compressor.compress(directory: app.deletingLastPathComponent(), progress: { _ in })
        }
        // moveItem refuses to replace an existing destination, including one created during signing.
        try FileManager.default.moveItem(at: artifact, to: output)
    }

    struct PackageError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}
