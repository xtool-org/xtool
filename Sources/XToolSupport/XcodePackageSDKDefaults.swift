import Foundation
import XUtils
import XPIF

/// Xcode supplies platform version mappings and device families to libSwiftPM.
struct XcodePackageSDKDefaults {
    var versionMaps: [String: [String: String]] = [:]
    var deviceFamilies: Set<Int> = []

    private static let alignedPlatforms: [(String, XPIF.BuildSettings.Platform, XPIF.BuildSettings.SingleValueSetting)] = [
        ("tvOS", .tvOS, .TVOS_DEPLOYMENT_TARGET),
        ("watchOS", .watchOS, .WATCHOS_DEPLOYMENT_TARGET),
        ("xrOS", .xrOS, .XROS_DEPLOYMENT_TARGET),
    ]

    static func load() async throws -> Self {
        let developerDirectory: URL?
        #if os(macOS)
        let resourcePath = try await d.toolchain.runtimeResourcePath
        // <Developer>/Toolchains/<toolchain>/usr/lib/swift
        developerDirectory = URL(filePath: resourcePath.string)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        #else
        developerDirectory = try DarwinSDK.current()?.developerDirectory
        #endif
        guard let developerDirectory else { return Self() }
        let platforms = try FileManager.default.contentsOfDirectory(
            at: developerDirectory.appending(path: "Platforms"),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "platform" }
        var result = Self()
        for platform in platforms {
            let sdksURL = platform.appending(path: "Developer/SDKs")
            let sdks = (try? FileManager.default.contentsOfDirectory(at: sdksURL, includingPropertiesForKeys: nil)) ?? []
            for sdk in sdks where sdk.pathExtension == "sdk" {
                guard let data = try? Data(contentsOf: sdk.appending(path: "SDKSettings.plist")),
                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let targets = plist["SupportedTargets"] as? [String: [String: Any]] else { continue }
                for (name, versions) in plist["VersionMap"] as? [String: [String: String]] ?? [:] {
                    result.versionMaps[name] = versions
                }
                for target in targets.values {
                    for family in target["DeviceFamilies"] as? [[String: String]] ?? [] {
                        if let value = family["Identifier"].flatMap(Int.init) { result.deviceFamilies.insert(value) }
                    }
                }
            }
        }
        return result
    }

    func apply(to settings: inout XPIF.BuildSettings) {
        if let iOS = settings[.IPHONEOS_DEPLOYMENT_TARGET] {
            for (family, platform, setting) in Self.alignedPlatforms {
                // SwiftPM emits this key even for empty options, but only for declared platforms.
                guard settings[.SPECIALIZATION_SDK_OPTIONS, platform] == nil,
                      let versions = versionMaps["iOS_\(family)"],
                      let version = versions.keys.filter({ $0.compare(iOS, options: .numeric) != .orderedDescending })
                        .max(by: { $0.compare($1, options: .numeric) == .orderedAscending }),
                      let mapped = versions[version], let current = settings[setting],
                      mapped.compare(current, options: .numeric) != .orderedAscending else { continue }
                settings[setting] = mapped
            }
        }
        if !deviceFamilies.isEmpty {
            settings[single: "TARGETED_DEVICE_FAMILY"] = deviceFamilies.sorted().map(String.init).joined(separator: ",")
        }
    }
}
