import Foundation
import Subprocess
import XUtils

public struct DarwinSDK {
    public let bundle: URL
    public let version: String

    public init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if ["darwin.xtoolsdk", "darwin.artifactbundle"].contains(bundle.lastPathComponent) {
            self.version = "unknown"
        } else {
            return nil
        }
    }

    public static func install(from path: String) async throws {
        // we can't just move into ~/.swiftpm/swift-sdks because the swiftpm directory
        // location depends on factors like $XDG_CONFIG_HOME. Rather than replicating
        // SwiftPM's logic, which may change, it's more reliable to directly invoke
        // `swift sdk install`. See: https://github.com/xtool-org/xtool/pull/40

        let url = URL(fileURLWithPath: path)
        guard DarwinSDK(bundle: url) != nil else { throw StringError("Invalid Darwin SDK at '\(path)'")}

        try await addHostClangResourceDir(to: url)

        try await Subprocess.run(
            .name("swift"),
            arguments: ["sdk", "install", url.path],
            output: .discarded
        )
        .checkSuccess()
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
        try FileManager.default.copyItem(at: hostInclude, to: sdkInclude)
    }

    public static func current() async throws -> DarwinSDK? {
        let outputString: String
        do {
            outputString = try await Subprocess.run(
                .name("swift"),
                arguments: ["sdk", "configure", "darwin", "arm64-apple-ios", "--show-configuration"],
                output: .string(limit: .max)
            )
            .checkSuccess()
            .standardOutput
            ?? ""
        } catch SubprocessFailure.exited {
            return nil
        }

        // should be something like
        // swiftResourcesPath: /home/user/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
        // swiftlint:disable:previous line_length
        let resourcesPathPrefix = "swiftResourcesPath: "

        guard let resourcesPath = outputString
            .split(separator: "\n")
            .first(where: { $0.hasPrefix(resourcesPathPrefix) })?
            .dropFirst(resourcesPathPrefix.count)
            else { return nil }

        var resourcesURL = URL(fileURLWithPath: String(resourcesPath))
        for _ in 0..<6 {
            resourcesURL = resourcesURL.deletingLastPathComponent()
        }

        return DarwinSDK(bundle: resourcesURL)
    }

    public func isUpToDate() -> Bool {
        true
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }
}
