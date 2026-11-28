// Adapted from SwiftBuild/BuildConfig.swift: mutable Xcode PIF support and lossless JSON fields.

import Foundation

extension XPIF {
    /// A build configuration, which is a named collection of build settings.
    public struct BuildConfig: Sendable, Hashable, Identifiable {
        public let id: GUID
        public var name: String
        public var settings: BuildSettings
        public var additionalFields: [String: JSONValue] = [:]
        var explicitDefaults: [String: JSONValue] = [:]
        public var baseConfigurationFileReference: GUID? = nil
        public var impartedBuildProperties: ImpartedBuildProperties

        public init(id: GUID, name: String, settings: BuildSettings, impartedBuildSettings: BuildSettings = .init()) {
            precondition(!name.isEmpty)
            self.id = id
            self.name = name
            self.settings = settings
            self.impartedBuildProperties = ImpartedBuildProperties(settings: impartedBuildSettings)
        }
    }
}

extension XPIF.BuildConfig: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(XPIF.GUID.self, forKey: .guid)
        self.name = try container.decode(String.self, forKey: .name)
        self.settings = try container.decode(XPIF.BuildSettings.self, forKey: .buildSettings)
        self.impartedBuildProperties = try container.decodeIfPresent(XPIF.ImpartedBuildProperties.self, forKey: .impartedBuildProperties) ?? .init(settings: .init())
        self.baseConfigurationFileReference = try container.decodeIfPresent(XPIF.GUID.self, forKey: .baseConfigurationFileReference)
        self.additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        self.explicitDefaults = try decodeExplicitDefaults(from: decoder, defaults: ["impartedBuildProperties": .object(["buildSettings": .object([:])])])
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExplicitDefaults(explicitDefaults, to: encoder)
        try encodeAdditionalFields(self.additionalFields, to: encoder, excluding: CodingKeys.self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .guid)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .buildSettings)
        if !impartedBuildProperties.settings.values.isEmpty || !impartedBuildProperties.additionalFields.isEmpty {
            try container.encode(impartedBuildProperties, forKey: .impartedBuildProperties)
        }
        try container.encodeIfPresent(baseConfigurationFileReference, forKey: .baseConfigurationFileReference)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case guid
        case name
        case buildSettings
        case impartedBuildProperties
        case baseConfigurationFileReference
    }
}

