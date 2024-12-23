import Foundation
import Supersign
import Version
import ArgumentParser
import Dependencies

struct DevSDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "Manage the Darwin Swift SDK",
        subcommands: [
            DevSDKInstallCommand.self,
            DevSDKRemoveCommand.self,
        ],
        defaultSubcommand: DevSDKInstallCommand.self
    )
}

struct DevSDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Darwin Swift SDK"
    )

    func run() async throws {
        try await InstallSDKOperation().run()
    }
}

struct DevSDKRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the Darwin Swift SDK"
    )

    func run() async throws {
        guard let sdk = try DarwinSDK.current() else {
            throw Console.Error("Cannot remove SDK: no Darwin SDK installed")
        }
        try FileManager.default.removeItem(at: sdk.bundle)
        print("Uninstalled SDK")
    }
}

struct DarwinSDKVersions: Decodable {
    private static let url = URL(string: """
    https://raw.githubusercontent.com/kabiroberai/swift-sdk-darwin/refs/heads/main/versions.json
    """)!

    private static let decoder = JSONDecoder()

    struct Metadata: Decodable {
        var arm64Checksum: String
        var x64Checksum: String
        var compilerRange: [String]

        func checksum(for arch: SDKArch) -> String {
            switch arch {
            case .arm64: return arm64Checksum
            case .x86_64: return x64Checksum
            }
        }

        var versionRange: Range<Version> {
            get throws {
                guard compilerRange.count == 2,
                      let lower = Version(tolerant: compilerRange[0]),
                      let upper = Version(tolerant: compilerRange[1]) else {
                    throw Console.Error("Could not parse SDK metadata list. You may need to update Supersign.")
                }
                return lower..<upper
            }
        }
    }
    var current: String
    var metadata: [String: Metadata]

    static func all() async throws -> DarwinSDKVersions {
        @Dependency(\.httpClient) var httpClient
        let data = try await httpClient.makeRequest(HTTPRequest(url: url)).body
        return try decoder.decode(self, from: data)
    }
}

struct DarwinSDK {
    private static let sdksDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".swiftpm/swift-sdks")
        .resolvingSymlinksInPath()

    let bundle: URL
    let version: String

    init?(bundle: URL) {
        self.bundle = bundle
        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if bundle.lastPathComponent == "darwin.artifactbundle" {
            self.version = "unknown"
        } else {
            return nil
        }
    }

    static func current() throws -> DarwinSDK? {
        let sdks = (try? FileManager.default.contentsOfDirectory(at: sdksDir, includingPropertiesForKeys: nil)) ?? []
        let darwinSDKs = sdks.compactMap { DarwinSDK(bundle: $0) }
        switch darwinSDKs.count {
        case 0:
            return nil
        case 1:
            return darwinSDKs[0]
        default:
            throw Console.Error("""
            You have multiple copies of the Darwin SDK installed. Please delete all but one to continue.
            \(darwinSDKs.map { "- \($0.bundle.path) (version '\($0.version)')" }.joined(separator: "\n"))
            """)
        }
    }
}

enum SDKArch {
    case arm64
    case x86_64

    var releaseName: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "x86_64"
        }
    }

    static var current: SDKArch {
        get throws {
            #if arch(arm64)
            return .arm64
            #elseif arch(x86_64)
            return .x86_64
            #else
            throw Console.Error("Unsupported architecture: the Swift SDK supports aarch64 and x86_64.")
            #endif
        }
    }
}

private enum SwiftVersion {}
extension SwiftVersion {
    static func current() async throws -> Version {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let swift = Process()
        swift.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        swift.arguments = ["swift", "--version"]
        swift.standardOutput = outPipe
        swift.standardError = errPipe
        try swift.run()
        async let outputTask = outPipe.fileHandleForReading.readToEnd()
        await swift.waitForExit()
        guard swift.terminationStatus == 0 else {
            throw Console.Error("Failed to obtain Swift version")
        }
        let outputData = try await outputTask
        var output = String(decoding: outputData ?? Data(), as: UTF8.self)[...]
        if output.hasPrefix("Apple ") {
            output = output.dropFirst("Apple ".count)
        }
        guard output.hasPrefix("Swift version ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output.dropFirst("Swift version ".count)
        guard let space = output.firstIndex(of: " ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output[..<space]
        guard let version = Version(tolerant: output) else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        return version
    }
}

struct InstallSDKOperation {
    func run() async throws {
        #if os(macOS)
        print("Skipping SDK install; the iOS SDK ships with Xcode on macOS")
        #else
        let arch = try SDKArch.current

        let list = try await DarwinSDKVersions.all()
        guard let item = list.metadata[list.current] else {
            throw Console.Error("""
            Couldn't find SDK metadata for '\(list.current)'. You may need to update Supersign.
            """)
        }
        let acceptedRange = try item.versionRange
        let swiftVersion = try await SwiftVersion.current()

        guard acceptedRange.contains(swiftVersion) else {
            throw Console.Error("""
            You currently have Swift version \(swiftVersion) installed. \
            The Darwin Swift SDK currently requires Swift ≥\(acceptedRange.lowerBound), \
            <\(acceptedRange.upperBound).
            """)
        }

        if let sdk = try DarwinSDK.current() {
            let installed = sdk.version
            if list.current != installed {
                print("Installed Darwin SDK version is '\(installed)' but latest is '\(list.current)'. Updating...")
                try FileManager.default.removeItem(at: sdk.bundle)
            } else {
                print("Darwin SDK is up to date.")
                return
            }
        } else {
            print("Darwin Swift SDK not found on disk. Installing...")
        }

        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        install.arguments = [
            "swift", "sdk", "install",
            """
            https://github.com/kabiroberai/swift-sdk-darwin/releases/download/\(list.current)/\
            darwin-linux-\(arch.releaseName).artifactbundle.zip
            """,
            "--checksum", item.checksum(for: arch)
        ]
        try install.run()
        await install.waitForExit()
        guard install.terminationStatus == 0 else {
            throw Console.Error("Failed to install SDK")
        }
        #endif
    }
}
