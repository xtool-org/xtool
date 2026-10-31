import Foundation

public struct DeviceInfo: Codable, Sendable {
    public static let xcodeVersionKey = "X-Xcode-Version"
    public static let xcodeVersion = "26.5 (17F42)"

    public static let deviceIDKey = "X-Mme-Device-Id"
    public let deviceID: String

    public static let clientInfoKey = "X-MMe-Client-Info"
    public let clientInfo: String

    public let akdUserAgent: String

    public var dictionary: [String: String] {
        [
            Self.clientInfoKey: clientInfo,
            Self.deviceIDKey: deviceID,
        ]
    }
}
