import Foundation

public struct DeviceInfo: Codable, Sendable {
    public static let xcodeVersionKey = "X-Xcode-Version"
    public static let xcodeVersion = "26.5 (17F42)"
    /// The fallback when the Anisette provider doesn't name a user agent.
    public static let akdUserAgent = "akd/1.0 CFNetwork/808.1.4"

    public static let deviceIDKey = "X-Mme-Device-Id"
    public let deviceID: String

    public static let clientInfoKey = "X-MMe-Client-Info"
    public let clientInfo: String

    /// The `User-Agent` that goes with `clientInfo`. GSA's edge answers 503 when the two disagree.
    public var userAgent: String = Self.akdUserAgent

    public var dictionary: [String: String] {
        [
            Self.clientInfoKey: clientInfo,
            Self.deviceIDKey: deviceID,
        ]
    }
}
