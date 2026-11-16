// Adapted from SwiftBuild/SandboxingOverride.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public enum SandboxingOverride: String, Sendable, Codable {
        case forceDisabled
        case forceEnabled
        case basedOnBuildSetting

    }
}
