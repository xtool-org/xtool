import Foundation

/// Build metadata of the Xcode and iOS SDK that a Darwin SDK was generated from.
///
/// App Store Connect rejects uploads whose `Info.plist` lacks the `DT*` keys that Xcode normally
/// stamps (`DTXcode`, `DTSDKBuild`, ...). The values live in files that the slim SDK flavor does not
/// retain (`version.plist`), so `xtool sdk install` records them in ``fileName`` at the root of the
/// Darwin SDK bundle and ``Packer`` reads them back when producing an app.
public struct SDKBuildInfo: Codable, Sendable, Equatable {
    /// Name of the file, relative to the Darwin SDK bundle root.
    public static let fileName = "xtool-sdk-info.json"

    /// `Xcode.app/Contents/version.plist` `CFBundleShortVersionString`, e.g. `26.5`.
    public var xcodeVersion: String?
    /// `Xcode.app/Contents/version.plist` `ProductBuildVersion`, e.g. `17F42`.
    public var xcodeBuild: String?
    /// `iPhoneOS.platform/version.plist` `ProductBuildVersion`, e.g. `23F73`.
    public var platformBuild: String?
    /// `iPhoneOS.sdk/SDKSettings.json` `Version`, e.g. `26.5`.
    public var platformVersion: String?
    /// `iPhoneOS.sdk/SDKSettings.json` `CanonicalName`, e.g. `iphoneos26.5`.
    public var sdkName: String?
    /// `iPhoneOS.sdk/System/Library/CoreServices/SystemVersion.plist` `ProductBuildVersion`, e.g. `23F73`.
    public var sdkBuild: String?

    public init(
        xcodeVersion: String? = nil,
        xcodeBuild: String? = nil,
        platformBuild: String? = nil,
        platformVersion: String? = nil,
        sdkName: String? = nil,
        sdkBuild: String? = nil
    ) {
        self.xcodeVersion = xcodeVersion
        self.xcodeBuild = xcodeBuild
        self.platformBuild = platformBuild
        self.platformVersion = platformVersion
        self.sdkName = sdkName
        self.sdkBuild = sdkBuild
    }

    // MARK: - Reading from an Xcode tree

    /// Gathers the metadata from an Xcode layout.
    ///
    /// - Parameters:
    ///   - xcodeContents: `Xcode.app/Contents` (only `version.plist` is read).
    ///   - developer: the `Developer` directory holding `Platforms/iPhoneOS.platform`.
    ///
    /// Anything that cannot be read is left `nil`.
    package static func collect(xcodeContents: URL, developer: URL) -> SDKBuildInfo {
        var info = SDKBuildInfo()

        let xcodePlist = plist(at: xcodeContents.appendingPathComponent("version.plist"))
        info.xcodeVersion = xcodePlist?["CFBundleShortVersionString"] as? String
        info.xcodeBuild = xcodePlist?["ProductBuildVersion"] as? String

        let platform = developer.appendingPathComponent("Platforms/iPhoneOS.platform")
        let platformPlist = plist(at: platform.appendingPathComponent("version.plist"))
        info.platformBuild = platformPlist?["ProductBuildVersion"] as? String

        if let sdk = iPhoneOSSDK(in: platform.appendingPathComponent("Developer/SDKs")) {
            if let data = try? Data(contentsOf: sdk.appendingPathComponent("SDKSettings.json")),
               let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                info.platformVersion = settings["Version"] as? String
                info.sdkName = settings["CanonicalName"] as? String
            }
            let systemVersion = sdk.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
            info.sdkBuild = plist(at: systemVersion)?["ProductBuildVersion"] as? String
        }

        return info
    }

    private static func plist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func iPhoneOSSDK(in sdks: URL) -> URL? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sdks.path)) ?? [])
        let versioned = names
            .filter { $0.hasPrefix("iPhoneOS") && $0.hasSuffix(".sdk") && $0 != "iPhoneOS.sdk" }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        if let name = versioned.last ?? names.first(where: { $0 == "iPhoneOS.sdk" }) {
            return sdks.appendingPathComponent(name)
        }
        return nil
    }

    // MARK: - Persistence

    package static func read(from bundle: URL) -> SDKBuildInfo? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(SDKBuildInfo.self, from: data)
    }

    package func write(to bundle: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: bundle.appendingPathComponent(Self.fileName))
    }

    // MARK: - Info.plist keys

    /// The values that are needed to build the `DT*` keys and are not known.
    public var missingFields: [String] {
        [
            ("xcodeVersion", xcodeVersion),
            ("xcodeBuild", xcodeBuild),
            ("platformVersion", platformVersion),
            ("sdkName", sdkName),
            ("sdkBuild", sdkBuild),
        ]
        .filter { $0.1?.isEmpty ?? true }
        .map(\.0)
    }

    /// Encodes an Xcode version the way `DTXcode` does: `MMmp`, e.g. `26.5` -> `2650`, `9.4.1` -> `0941`.
    package static func xcodeCode(forVersion version: String) -> String? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 } + [0, 0]
        guard numbers[0] < 100, numbers[1] < 10, numbers[2] < 10 else { return nil }
        return String(format: "%02d%d%d", numbers[0], numbers[1], numbers[2])
    }

    /// Value of `DTCompiler`, which Xcode takes from the default `GCC_VERSION` build setting.
    package static let compiler = "com.apple.compilers.llvm.clang.1_0"

    /// The Apple build keys for an iPhoneOS (device) build. Keys whose value is unknown are omitted.
    ///
    /// `DTPlatformBuild` falls back to the SDK build, which is identical in every observed Xcode IPA.
    ///
    /// - Parameter buildMachineOSBuild: value for `BuildMachineOSBuild`, the build of the macOS that ran
    ///   the build. There is no honest value on Linux, so the key is omitted unless one is given.
    package func infoPlistKeys(buildMachineOSBuild: String? = nil) -> [String: String] {
        var keys: [String: String] = [
            "DTCompiler": Self.compiler,
            "DTPlatformName": "iphoneos",
        ]
        func set(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { keys[key] = value }
        }
        set("DTXcode", xcodeVersion.flatMap(Self.xcodeCode(forVersion:)))
        set("DTXcodeBuild", xcodeBuild)
        set("DTPlatformVersion", platformVersion)
        set("DTPlatformBuild", platformBuild ?? sdkBuild)
        set("DTSDKName", sdkName)
        set("DTSDKBuild", sdkBuild)
        set("BuildMachineOSBuild", buildMachineOSBuild)
        return keys
    }
}
