import Foundation

extension DarwinSDK {
    public func buildMetadata(for triple: String) throws -> [String: String] {
        let root = try sdkRoot(for: triple)
        let settings = try Self.sdkSettings(root)
        let platform = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let platformInfo = try Self.metadataPlist(platform.appendingPathComponent("Info.plist"))
        let additional = platformInfo["AdditionalInfo"] as? [String: Any] ?? [:]
        let defaults = settings["DefaultProperties"] as? [String: Any] ?? [:]
        let platformDefaults = platformInfo["DefaultProperties"] as? [String: Any] ?? [:]
        let systemVersionURL = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        let systemVersion = FileManager.default.fileExists(atPath: systemVersionURL.path)
            ? try Self.metadataPlist(systemVersionURL) : [:]
        let xcode = try Self.metadataPlist(bundle.appendingPathComponent("xcode-version.plist"))

        // Platform Info.plist contains Xcode build-setting templates, not necessarily recorded values.
        func recorded(_ value: Any?) -> String? {
            guard let string = value as? String, !string.contains("$(") else { return nil }
            return string
        }

        func required(_ value: Any?, key: String) throws -> String {
            guard let value = recorded(value), !value.isEmpty || key == "DTPlatformBuild" else {
                throw StringError("The Darwin SDK is missing build metadata '\(key)' for '\(triple)'. Rebuild the SDK.")
            }
            return value
        }

        let sdkBuild = recorded(settings["ProductBuildVersion"]) ?? recorded(systemVersion["ProductBuildVersion"])
            ?? recorded(additional["DTSDKBuild"])
        var metadata = try [
            "DTSDKName": required(recorded(settings["CanonicalName"]) ?? recorded(additional["DTSDKName"]), key: "DTSDKName"),
            "DTSDKBuild": required(sdkBuild, key: "DTSDKBuild"),
            "DTPlatformName": required(recorded(additional["DTPlatformName"]) ?? defaults["PLATFORM_NAME"], key: "DTPlatformName"),
            "DTPlatformVersion": required(recorded(settings["Version"]) ?? additional["DTPlatformVersion"], key: "DTPlatformVersion"),
            "DTPlatformBuild": required(recorded(additional["DTPlatformBuild"]) ?? sdkBuild, key: "DTPlatformBuild"),
            "DTXcodeBuild": required(recorded(xcode["ProductBuildVersion"]) ?? additional["DTXcodeBuild"], key: "DTXcodeBuild"),
        ]
        if let version = xcode["CFBundleShortVersionString"] as? String {
            metadata["DTXcode"] = try Self.xcodeBuildVersion(version)
        } else {
            metadata["DTXcode"] = try required(additional["DTXcode"], key: "DTXcode")
        }
        if let compiler = recorded(additional["DTCompiler"]) ?? recorded(defaults["DEFAULT_COMPILER"])
            ?? recorded(platformDefaults["DEFAULT_COMPILER"]) {
            metadata["DTCompiler"] = compiler
        }
        return metadata
    }

    public func sdkVersion(for triple: String) throws -> String {
        let settings = try Self.sdkSettings(sdkRoot(for: triple))
        guard let version = settings["Version"] as? String else {
            throw StringError("The Darwin SDK is missing its version for '\(triple)'.")
        }
        if ApplePlatform(triple: triple) == .macCatalyst,
           let maps = settings["VersionMap"] as? [String: [String: String]],
           let catalystVersion = maps["macOS_iOSMac"]?[version] {
            return catalystVersion
        }
        return version
    }

    package func minimumDeploymentTarget(for triple: String) throws -> String? {
        try Self.minimumDeploymentTarget(for: triple, sdkRoot: sdkRoot(for: triple))
    }

    package static func minimumDeploymentTarget(for triple: String, sdkRoot: URL) throws -> String? {
        let settings = try sdkSettings(sdkRoot)
        let platform = ApplePlatform(triple: triple) ?? .iOS
        let target = platform == .macCatalyst ? "iosmac" : platform.supportedPlatform(triple: triple).lowercased()
        let targets = settings["SupportedTargets"] as? [String: [String: Any]]
        return targets?[target]?["MinimumDeploymentTarget"] as? String
    }

    package func macOSMinimum(forCatalyst deployment: String, triple: String) throws -> String? {
        try Self.macOSMinimum(forCatalyst: deployment, sdkRoot: sdkRoot(for: triple))
    }

    package static func macOSMinimum(forCatalyst deployment: String, sdkRoot: URL) throws -> String? {
        let settings = try sdkSettings(sdkRoot)
        let maps = settings["VersionMap"] as? [String: [String: String]]
        let mapping = maps?["iOSMac_macOS"] ?? [:]
        let available = mapping.keys.filter { $0.compare(deployment, options: .numeric) != .orderedDescending }
        let key = available.max { $0.compare($1, options: .numeric) == .orderedAscending }
        return key.flatMap { mapping[$0] }
    }

    private static func sdkSettings(_ root: URL) throws -> [String: Any] {
        let json = root.appendingPathComponent("SDKSettings.json")
        if FileManager.default.fileExists(atPath: json.path) {
            let data = try Data(contentsOf: json)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StringError("Invalid SDK settings at '\(json.path)'")
            }
            return decoded
        } else {
            return try Self.metadataPlist(root.appendingPathComponent("SDKSettings.plist"))
        }
    }

    private static func metadataPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StringError("Invalid SDK build metadata at '\(url.path)'")
        }
        return plist
    }

    static func xcodeBuildVersion(_ version: String) throws -> String {
        let pieces = version.split(separator: ".").map(String.init)
        guard (2...3).contains(pieces.count), let major = Int(pieces[0]), let minor = Int(pieces[1]),
              let patch = pieces.count == 3 ? Int(pieces[2]) : 0,
              major >= 0, minor >= 0, minor < 10, patch >= 0, patch < 10 else {
            throw StringError("Unsupported Xcode version in SDK metadata: '\(version)'")
        }
        return String(format: "%04d", major * 100 + minor * 10 + patch)
    }
}
