// Adapted from SWBProtocol/ProvisioningSourceData.swift: Serializable -> Codable

import Foundation

extension XPIF {
    public enum ProvisioningStyle: Int, Sendable, Hashable, Codable {
        case automatic = 0
        case manual = 1
    }

    public struct ProvisioningSourceData: Sendable, Hashable, Codable {
        public var configurationName: String
        public var provisioningStyle: ProvisioningStyle
        public var bundleIdentifierFromInfoPlist: String
        public var additionalFields: [String: JSONValue] = [:]

        public init(configurationName: String, provisioningStyle: ProvisioningStyle, bundleIdentifierFromInfoPlist: String) {
            self.configurationName = configurationName
            self.provisioningStyle = provisioningStyle
            self.bundleIdentifierFromInfoPlist = bundleIdentifierFromInfoPlist
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            configurationName = try container.decode(String.self, forKey: .configurationName)
            provisioningStyle = try container.decode(ProvisioningStyle.self, forKey: .provisioningStyle)
            bundleIdentifierFromInfoPlist = try container.decode(String.self, forKey: .bundleIdentifierFromInfoPlist)
            additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        }

        public func encode(to encoder: any Encoder) throws {
            try encodeAdditionalFields(additionalFields, to: encoder, excluding: CodingKeys.self)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(configurationName, forKey: .configurationName)
            try container.encode(provisioningStyle, forKey: .provisioningStyle)
            try container.encode(bundleIdentifierFromInfoPlist, forKey: .bundleIdentifierFromInfoPlist)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case configurationName, provisioningStyle, bundleIdentifierFromInfoPlist
        }
    }
}
