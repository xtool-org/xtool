import Foundation

package enum ApplePlatform: String, CaseIterable, Sendable {
    case iOS
    case tvOS
    case macOS
    case macCatalyst

    package init?(triple: String) {
        let components = triple.split(separator: "-")
        guard components.count >= 3, components[1] == "apple" else { return nil }
        let os = components[2].prefix { !$0.isNumber }
        switch os {
        case "ios": self = components.contains("macabi") ? .macCatalyst : .iOS
        case "tvos": self = .tvOS
        case "macos", "macosx": self = .macOS
        default: return nil
        }
    }

    package var usesContentsDirectory: Bool {
        self == .macOS || self == .macCatalyst
    }

    package var packagePlatformName: String {
        rawValue.lowercased()
    }

    package var minimumDeploymentTarget: String {
        self == .macOS ? "10.15" : "13.0"
    }

    package func effectiveDeploymentTarget(
        platforms: [String: String], swiftVersion: SwiftVersion, sdkMinimum: String?, tripleMinimum: String? = nil
    ) -> String {
        let declared = platforms[packagePlatformName] ?? (self == .macCatalyst ? platforms["ios"] : nil)
        // Match PackageModel.Platform.oldestSupportedVersion in SwiftPM 6.4.
        let toolchainMinimum = swiftVersion >= SwiftVersion(6, 4)
            ? (self == .macOS ? "12.0" : "15.0") : minimumDeploymentTarget
        return [declared, toolchainMinimum, sdkMinimum, tripleMinimum].compactMap { $0 }.max {
            $0.compare($1, options: .numeric) == .orderedAscending
        } ?? toolchainMinimum
    }

    package func supportedPlatform(triple: String) -> String {
        let simulator = triple.split(separator: "-").contains("simulator")
        switch self {
        case .iOS: return simulator ? "iPhoneSimulator" : "iPhoneOS"
        case .tvOS: return simulator ? "AppleTVSimulator" : "AppleTVOS"
        case .macOS, .macCatalyst: return "MacOSX"
        }
    }

    package func buildProductsPlatform(triple: String) -> String {
        if self == .macCatalyst { return "maccatalyst" }
        return supportedPlatform(triple: triple).lowercased()
    }

    package func linkerPlatform(triple: String) -> String {
        let simulator = triple.split(separator: "-").contains("simulator")
        switch self {
        case .iOS: return simulator ? "ios-sim" : "ios"
        case .tvOS: return simulator ? "tvos-sim" : "tvos"
        case .macOS: return "macos"
        case .macCatalyst: return "mac-catalyst"
        }
    }

    package func contentsDirectory(in bundle: URL) -> URL {
        usesContentsDirectory ? bundle.appendingPathComponent("Contents", isDirectory: true) : bundle
    }

    package func resourcesDirectory(in bundle: URL) -> URL {
        let contents = contentsDirectory(in: bundle)
        return usesContentsDirectory ? contents.appendingPathComponent("Resources", isDirectory: true) : contents
    }

    package func executableDirectory(in bundle: URL) -> URL {
        let contents = contentsDirectory(in: bundle)
        return usesContentsDirectory ? contents.appendingPathComponent("MacOS", isDirectory: true) : contents
    }

    package func additionalSDKOptions(sdkRoot: URL) -> [String] {
        guard self == .macCatalyst else { return [] }
        let support = sdkRoot.appendingPathComponent("System/iOSSupport")
        let frameworks = support.appendingPathComponent("System/Library/Frameworks").path
        return [
            "-Xswiftc", "-Fsystem", "-Xswiftc", frameworks,
            "-Xcc", "-isystem", "-Xcc", support.appendingPathComponent("usr/include").path,
            "-Xcc", "-iframework", "-Xcc", frameworks,
            "-Xlinker", "-F\(frameworks)",
            "-Xlinker", "-L\(support.appendingPathComponent("usr/lib").path)",
        ]
    }
}
