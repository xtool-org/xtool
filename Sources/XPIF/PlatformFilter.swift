// Adapted from SwiftBuild/PlatformFilter.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public struct PlatformFilter: Hashable, Sendable, Comparable {
        public var additionalFields: [String: JSONValue] = [:]
        public var platform: String
        public var environment: String

        public init(platform: String, environment: String = "") {
            self.platform = platform
            self.environment = environment
        }

        public static func < (lhs: XPIF.PlatformFilter, rhs: XPIF.PlatformFilter) -> Bool {
            return (lhs.platform, lhs.environment) < (rhs.platform, rhs.environment)
        }
    }
}

extension XPIF.PlatformFilter: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = try container.decode(String.self, forKey: .platform)
        self.environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? ""
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.platform, forKey: .platform)
        if !self.environment.isEmpty {
            try container.encode(self.environment, forKey: .environment)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case platform
        case environment
    }
}
