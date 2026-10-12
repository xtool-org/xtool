import Foundation
import Dependencies
import XUtils

/// The identity of an `.ipa`, as read from its `Info.plist`.
public struct IPAInfo: Hashable, Sendable {
    /// `CFBundleIdentifier`
    public var bundleID: String
    /// `CFBundleShortVersionString`
    public var version: String
    /// `CFBundleVersion`
    public var build: String
    /// The App Store Connect platform (`IOS`, `MAC_OS`, `TV_OS`, `VISION_OS`) the build targets.
    public var platform: String
}

/// A problem found by the local pre-flight checks.
public struct IPAFinding: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        /// App Store Connect is expected to reject the build.
        case error
        /// App Store Connect may reject the build, or the build may be degraded.
        case warning
    }

    public var severity: Severity
    public var message: String

    public var description: String { "\(severity.rawValue): \(message)" }
}

/// The result of ``IPAInspector/inspect(ipa:)``.
public struct IPAReport: Sendable {
    /// `nil` if the identifying keys could not be read, in which case `findings` explains why.
    public var info: IPAInfo?
    public var findings: [IPAFinding]

    public var errors: [IPAFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [IPAFinding] { findings.filter { $0.severity == .warning } }
}

/// Reads an `.ipa` and checks, without any network access, the things that
/// App Store Connect is known to reject builds for.
///
/// Apple doesn't expose a validation endpoint, so these checks are the only quick feedback
/// available before the (slow) server-side processing.
public struct IPAInspector: Sendable {
    @Dependency(\.zipCompressor) private var compressor

    public init() {}

    /// Keys that Xcode stamps into the `Info.plist` and that App Store Connect checks.
    static let xcodeStampedKeys = [
        "BuildMachineOSBuild",
        "DTCompiler",
        "DTPlatformBuild",
        "DTPlatformName",
        "DTPlatformVersion",
        "DTSDKBuild",
        "DTSDKName",
        "DTXcode",
        "DTXcodeBuild",
    ]

    public func inspect(ipa: URL) async throws -> IPAReport {
        // `ZIPCompressor` can only unpack the whole archive, not a few members of it.
        let tmp = try TemporaryDirectory(name: "ipa-inspect")
        try await compressor.decompress(file: ipa, in: tmp.url, progress: { _ in })
        return Self.inspect(extracted: tmp.url)
    }

    /// Inspect an `.ipa` that was unzipped into `root`.
    static func inspect(extracted root: URL) -> IPAReport {
        var findings: [IPAFinding] = []
        func error(_ message: String) { findings.append(.init(severity: .error, message: message)) }
        func warning(_ message: String) { findings.append(.init(severity: .warning, message: message)) }

        let fileManager = FileManager.default
        let payload = root.appendingPathComponent("Payload", isDirectory: true)
        let apps = ((try? fileManager.contentsOfDirectory(atPath: payload.path)) ?? [])
            .filter { $0.hasSuffix(".app") }
            .sorted()
        guard apps.count == 1, let appName = apps.first else {
            error(
                apps.isEmpty
                    ? "The archive has no Payload/<name>.app. Is it really an .ipa?"
                    : "Payload/ must contain exactly one .app, found \(apps.joined(separator: ", "))."
            )
            return IPAReport(info: nil, findings: findings)
        }
        let app = payload.appendingPathComponent(appName, isDirectory: true)

        guard let infoData = fileManager.contents(atPath: app.appendingPathComponent("Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        else {
            error("Payload/\(appName)/Info.plist is missing or is not a valid property list.")
            return IPAReport(info: nil, findings: findings)
        }

        var values: [String: String] = [:]
        for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = info[key] as? String, !value.isEmpty {
                values[key] = value
            } else {
                error("Info.plist has no \(key).")
            }
        }

        checkIcon(in: info, app: app, error: { error($0) })
        checkProfile(in: app, bundleID: values["CFBundleIdentifier"], error: { error($0) })

        let missing = xcodeStampedKeys.filter { info[$0] == nil }
        if !missing.isEmpty {
            warning(
                "Info.plist is missing keys that Xcode normally adds (\(missing.joined(separator: ", "))). "
                    + "App Store Connect may reject the build with \"Unsupported SDK or Xcode version\"."
            )
        }

        guard let bundleID = values["CFBundleIdentifier"],
              let version = values["CFBundleShortVersionString"],
              let build = values["CFBundleVersion"]
        else {
            return IPAReport(info: nil, findings: findings)
        }
        return IPAReport(
            info: IPAInfo(
                bundleID: bundleID,
                version: version,
                build: build,
                platform: platform(for: info)
            ),
            findings: findings
        )
    }

    private static func platform(for info: [String: Any]) -> String {
        let name = (info["CFBundleSupportedPlatforms"] as? [String])?.first ?? info["DTPlatformName"] as? String
        switch name?.lowercased() {
        case "macosx": return "MAC_OS"
        case "appletvos", "appletvsimulator": return "TV_OS"
        case "xros", "xrsimulator": return "VISION_OS"
        default: return "IOS"
        }
    }

    private static func checkIcon(in info: [String: Any], app: URL, error: (String) -> Void) {
        // since iOS 11 the icon must come from a compiled asset catalog, referenced by name
        let candidates = [info["CFBundleIcons"], info["CFBundleIcons~ipad"]]
        let hasIconName = info["CFBundleIconName"] is String || candidates.contains {
            let primary = ($0 as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            return primary?["CFBundleIconName"] is String
        }
        if !hasIconName {
            error("Info.plist has no CFBundleIconName: the app icon must come from an asset catalog.")
        }
        if !FileManager.default.fileExists(atPath: app.appendingPathComponent("Assets.car").path) {
            error("The app has no Assets.car: the asset catalog must be compiled for App Store Connect.")
        }
    }

    private static func checkProfile(in app: URL, bundleID: String?, error: (String) -> Void) {
        guard let data = FileManager.default.contents(atPath: app.appendingPathComponent("embedded.mobileprovision").path)
        else {
            error("The app has no embedded.mobileprovision: it must be signed with an App Store provisioning profile.")
            return
        }
        guard let profile = Self.profilePlist(from: data) else {
            error("embedded.mobileprovision could not be read.")
            return
        }

        if profile["ProvisionedDevices"] != nil || profile["ProvisionsAllDevices"] as? Bool == true {
            error(
                "embedded.mobileprovision is a development, ad-hoc or enterprise profile: "
                    + "App Store Connect requires an App Store distribution profile."
            )
        }

        let entitlements = profile["Entitlements"] as? [String: Any]
        if entitlements?["get-task-allow"] as? Bool == true {
            error("embedded.mobileprovision grants get-task-allow, which App Store Connect rejects.")
        }

        if let bundleID, let appID = entitlements?["application-identifier"] as? String {
            // "<team>.<bundle id>", or a wildcard such as "<team>.*" or "<team>.com.example.*"
            let identifier = appID.drop { $0 != "." }.dropFirst()
            let matches = identifier == bundleID[...]
                || (identifier.hasSuffix("*") && bundleID.hasPrefix(identifier.dropLast()))
            if !matches {
                error("embedded.mobileprovision is for \(identifier), not for the bundle ID \(bundleID).")
            }
        }
    }

    /// Extracts the property list from a `.mobileprovision`, which is a CMS envelope
    /// that contains the (unencrypted) XML plist.
    static func profilePlist(from data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        return try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
    }
}
