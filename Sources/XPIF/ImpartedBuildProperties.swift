// Adapted from SwiftBuild/ImpartedBuildProperties.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    public struct ImpartedBuildProperties: Sendable, Hashable {
        public var additionalFields: [String: JSONValue] = [:]
        public var settings: BuildSettings

        public init(settings: BuildSettings) {
            self.settings = settings
        }
    }
}

extension XPIF.ImpartedBuildProperties: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.settings = try container.decode(XPIF.BuildSettings.self, forKey: .buildSettings)
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settings, forKey: .buildSettings)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case buildSettings
    }
}
