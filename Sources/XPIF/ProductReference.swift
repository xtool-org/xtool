import Foundation

extension XPIF {
    /// A target's product reference has an identity independent of its target GUID.
    public struct ProductReference: Sendable, Hashable, Codable {
        public var id: GUID
        public var name: String
        public var type: String = "product"
        public var additionalFields: [String: JSONValue] = [:]

        public init(id: GUID, name: String) {
            self.id = id
            self.name = name
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(GUID.self, forKey: .guid)
            name = try container.decode(String.self, forKey: .name)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "product"
            additionalFields = try decodeAdditionalFields(from: decoder, excluding: CodingKeys.self)
        }

        public func encode(to encoder: any Encoder) throws {
            try encodeAdditionalFields(additionalFields, to: encoder, excluding: CodingKeys.self)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(id, forKey: .guid)
            try container.encode(name, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case type, guid, name
        }
    }
}
