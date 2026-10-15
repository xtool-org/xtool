import Foundation

/// Platforms supported by the SwiftPM app packer.
public enum AppPlatform: String, Codable, CaseIterable, Sendable {
    case iOS = "ios"
    case watchOS = "watchos"

    public init(triple: String) {
        let components = triple.split(separator: "-")
        self = components.count >= 3 && components[2].hasPrefix("watchos") ? .watchOS : .iOS
    }

    public var defaultTriple: String {
        switch self {
        case .iOS: "arm64-apple-ios"
        case .watchOS: "arm64_32-apple-watchos"
        }
    }

    var packagePlatform: String {
        switch self {
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        }
    }

    var minimumVersion: String {
        switch self {
        case .iOS: "13.0"
        // Keep the initial support range to watchOS 9 or later.
        case .watchOS: "9.0"
        }
    }

    public func sdkName(simulator: Bool) -> String {
        switch self {
        case .iOS: simulator ? "iPhoneSimulator" : "iPhoneOS"
        case .watchOS: simulator ? "WatchSimulator" : "WatchOS"
        }
    }

    func appInfoPlist() -> [String: any Sendable] {
        switch self {
        case .iOS:
            return [
                "UIDeviceFamily": [1, 2],
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "UILaunchScreen": [:] as [String: any Sendable],
            ]
        case .watchOS:
            return [
                "UIDeviceFamily": [4],
                "WKApplication": true,
                "WKWatchOnly": true,
            ]
        }
    }
}
