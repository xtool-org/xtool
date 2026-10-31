import Foundation
import XUtils
import Subprocess

/// The platform SDK that a build links against, with the details that Xcode
/// records in the binary (LC_BUILD_VERSION) and in each bundle's Info.plist.
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

        /// The name used by `xcrun --sdk` and `DTPlatformName`
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
    /// For example "iphoneos27.1"
    public let canonicalName: String
    /// For example "23B5044"
    public let build: String?
    /// The version of the Xcode that the SDK belongs to, for example "27.1"
    public let xcodeVersion: String?
    /// For example "27A9275"
    public let xcodeBuild: String?

    init(platform: Platform, sdk: URL, xcodeVersionPlist: URL?) throws {
        struct Settings: Decodable {
            enum CodingKeys: String, CodingKey {
                case version = "Version"
                case canonicalName = "CanonicalName"
            }
            let version: String
            let canonicalName: String
        }
        let settingsURL = sdk.appendingPathComponent("SDKSettings.json")
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))

        self.platform = platform
        self.version = settings.version
        self.canonicalName = settings.canonicalName
        self.build = Self.plistString(
            "ProductBuildVersion",
            at: sdk.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        )
        // Xcode's Info.plist names the build of the Xcode that built Xcode;
        // version.plist names this one
        self.xcodeVersion = xcodeVersionPlist.flatMap { Self.plistString("CFBundleShortVersionString", at: $0) }
        self.xcodeBuild = xcodeVersionPlist.flatMap { Self.plistString("ProductBuildVersion", at: $0) }
    }

    public static func current(triple: String) async throws -> PlatformSDK {
        let platform = Platform(triple: triple)
        #if os(macOS)
        let sdkPath = try await xcrun(["--sdk", platform.identifier, "--show-sdk-path"])
        let developerDir = try await run(.path("/usr/bin/xcode-select"), ["-p"])
        return try PlatformSDK(
            platform: platform,
            sdk: URL(fileURLWithPath: sdkPath, isDirectory: true),
            xcodeVersionPlist: URL(fileURLWithPath: developerDir, isDirectory: true)
                .deletingLastPathComponent()
                .appendingPathComponent("version.plist")
        )
        #else
        let darwinSDK = try DarwinSDK.current()
            .orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
        let sdk = darwinSDK.bundle
            .appendingPathComponent("Developer/Platforms/\(platform.name).platform/Developer/SDKs", isDirectory: true)
            .appendingPathComponent("\(platform.name).sdk", isDirectory: true)
        // only the normal flavor has a copy of Xcode.app
        let versionPlist = darwinSDK.bundle.appendingPathComponent("Xcode.app/Contents/version.plist")
        return try PlatformSDK(
            platform: platform,
            sdk: sdk,
            xcodeVersionPlist: FileManager.default.fileExists(atPath: versionPlist.path) ? versionPlist : nil
        )
        #endif
    }

    /// The keys that Xcode adds to the Info.plist of every bundle it builds.
    /// App Store Connect checks some of them.
    public var infoPlistKeys: [String: any Sendable] {
        var keys: [String: any Sendable] = [
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
            "DTPlatformName": platform.identifier,
            "DTPlatformVersion": version,
            "DTSDKName": canonicalName,
        ]
        if let build {
            keys["DTPlatformBuild"] = build
            keys["DTSDKBuild"] = build
        }
        if let xcodeVersion, let code = Self.xcodeVersionCode(xcodeVersion) {
            keys["DTXcode"] = code
        }
        if let xcodeBuild {
            keys["DTXcodeBuild"] = xcodeBuild
        }
        #if os(macOS)
        if let machineBuild = Self.plistString(
            "ProductBuildVersion",
            at: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        ) {
            keys["BuildMachineOSBuild"] = machineBuild
        }
        #endif
        return keys
    }

    /// Formats a version the way `DTXcode` does: 26.6 is 2660, 26.0.1 is 2601.
    static func xcodeVersionCode(_ version: String) -> String? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, let major = parts[0] else { return nil }
        var rest: [Int] = []
        for part in parts.dropFirst() {
            guard let part, (0...9).contains(part) else { return nil }
            rest.append(part)
        }
        rest += Array(repeating: 0, count: 2 - rest.count)
        return String(format: "%02d", major) + rest.map(String.init).joined()
    }

    private static func plistString(_ key: String, at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }

    #if os(macOS)
    private static func xcrun(_ arguments: [String]) async throws -> String {
        try await run(.path("/usr/bin/xcrun"), arguments)
    }

    private static func run(_ executable: Executable, _ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            executable,
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
