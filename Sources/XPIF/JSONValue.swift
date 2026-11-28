import Foundation

extension XPIF {
    /// JSON fields not yet represented by the typed model survive decoding, editing, and encoding.
    public enum JSONValue: Sendable, Hashable, Codable {
        case null
        case bool(Bool)
        case number(Decimal)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}

struct StringKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ value: String) { stringValue = value }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func decodeAdditionalFields<Keys: CodingKey & CaseIterable>(
    from decoder: any Decoder, excluding: Keys.Type
) throws -> [String: XPIF.JSONValue] {
    let known = Set(Keys.allCases.map(\.stringValue))
    let container = try decoder.container(keyedBy: StringKey.self)
    var fields: [String: XPIF.JSONValue] = [:]
    for key in container.allKeys where !known.contains(key.stringValue) {
        fields[key.stringValue] = try container.decode(XPIF.JSONValue.self, forKey: key)
    }
    return fields
}

func encodeAdditionalFields<Keys: CodingKey & CaseIterable>(
    _ fields: [String: XPIF.JSONValue], to encoder: any Encoder, excluding: Keys.Type
) throws {
    let known = Set(Keys.allCases.map(\.stringValue))
    var container = encoder.container(keyedBy: StringKey.self)
    for (key, value) in fields where !known.contains(key) {
        try container.encode(value, forKey: StringKey(key))
    }
}

extension KeyedDecodingContainer {
    /// The legacy PIF wire format uses strings for booleans.
    func decodePIFBool(forKey key: Key, default defaultValue: Bool = false) throws -> Bool {
        guard contains(key) else { return defaultValue }
        let value = try decode(String.self, forKey: key)
        switch value {
        case "true": return true
        case "false": return false
        default:
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected true or false")
        }
    }
}

// Keep explicit default fields emitted by SwiftPM, while allowing Xcode's sparse form.
func decodeExplicitDefaults(from decoder: any Decoder, defaults: [String: XPIF.JSONValue]) throws -> [String: XPIF.JSONValue] {
    let container = try decoder.container(keyedBy: StringKey.self)
    return try defaults.filter { key, value in
        try container.decodeIfPresent(XPIF.JSONValue.self, forKey: StringKey(key)) == value
    }
}

func encodeExplicitDefaults(_ defaults: [String: XPIF.JSONValue], to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: StringKey.self)
    for (key, value) in defaults { try container.encode(value, forKey: StringKey(key)) }
}
