import Foundation
import XUtils
import Subprocess

/// The platform SDK that a build links against
public struct PlatformSDK: Sendable {
    public enum Platform: Sendable {
        case iPhoneOS
        case iPhoneSimulator

        public init(triple: String) {
            self = triple.contains("simulator") ? .iPhoneSimulator : .iPhoneOS
        }

        public var name: String {
            switch self {
            case .iPhoneOS: "iPhoneOS"
            case .iPhoneSimulator: "iPhoneSimulator"
            }
        }

        /// The name used by `xcrun --sdk`
        public var identifier: String {
            name.lowercased()
        }

        /// The name used by the linker's `-platform_version`
        public var linkerName: String {
            switch self {
            case .iPhoneOS: "ios"
            case .iPhoneSimulator: "ios-simulator"
            }
        }
    }

    public let platform: Platform
    /// For example "27.1"
    public let version: String

    init(platform: Platform, sdk: URL) throws {
        struct Settings: Decodable {
            enum CodingKeys: String, CodingKey {
                case version = "Version"
            }
            let version: String
        }
        let settingsURL = sdk.appendingPathComponent("SDKSettings.json")
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))

        self.platform = platform
        self.version = settings.version
    }

    public static func current(triple: String) async throws -> PlatformSDK {
        let platform = Platform(triple: triple)
        #if os(macOS)
        let result = try await Subprocess.run(
            .path("/usr/bin/xcrun"),
            arguments: ["--sdk", platform.identifier, "--show-sdk-path"],
            output: .string(limit: .max)
        ).checkSuccess()
        let sdkPath = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return try PlatformSDK(platform: platform, sdk: URL(fileURLWithPath: sdkPath, isDirectory: true))
        #else
        let darwinSDK = try DarwinSDK.current()
            .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
        let sdk = darwinSDK.bundle
            .appendingPathComponent("Developer/Platforms/\(platform.name).platform/Developer/SDKs", isDirectory: true)
            .appendingPathComponent("\(platform.name).sdk", isDirectory: true)
        return try PlatformSDK(platform: platform, sdk: sdk)
        #endif
    }
}
