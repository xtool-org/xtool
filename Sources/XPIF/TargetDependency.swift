// Adapted from SwiftBuild/TargetDependency.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    /// Represents a dependency on another target (identified by its PIF ID).
    public struct TargetDependency: Sendable, Hashable {
        public var additionalFields: [String: JSONValue] = [:]
        var explicitDefaults: [String: JSONValue] = [:]
        /// Identifier of depended-upon target.
        public var targetId: GUID
        /// The platform filters for this target dependency.
        public var platformFilters: Set<PlatformFilter>

        public init(targetId: XPIF.GUID, platformFilters: Set<XPIF.PlatformFilter> = []) {
            self.targetId = targetId
            self.platformFilters = platformFilters
        }
    }
}

extension XPIF.TargetDependency: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetId = try container.decode(XPIF.GUID.self, forKey: .guid)
        self.platformFilters = try container.decodeIfPresent(Set<XPIF.PlatformFilter>.self, forKey: .platformFilters) ?? []
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["platformFilters": .array([])])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.targetId, forKey: .guid)
        if !platformFilters.isEmpty { try container.encode(platformFilters.sorted(), forKey: .platformFilters) }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case guid
        case platformFilters
    }
}
