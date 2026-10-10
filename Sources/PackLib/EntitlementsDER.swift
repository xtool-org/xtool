import Foundation

/// Encodes entitlements in the DER format produced by `codesign --generate-entitlement-der`,
/// which Xcode embeds in the `__TEXT,__ents_der` section of simulator binaries.
enum EntitlementsDER {
    private enum Value: Decodable {
        case bool(Bool)
        case integer(Int)
        case string(String)
        case array([Value])
        case dictionary([String: Value])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([Value].self) {
                self = .array(value)
            } else {
                self = .dictionary(try container.decode([String: Value].self))
            }
        }
    }

    static func encode(plist: Data) throws -> Data {
        let entitlements = try PropertyListDecoder().decode([String: Value].self, from: plist)
        // [APPLICATION 16] { version INTEGER 1, entitlements }
        return Data(element(tag: 0x70, [0x02, 0x01, 0x01] + encode(.dictionary(entitlements))))
    }

    private static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .bool(let value):
            element(tag: 0x01, [value ? 0xFF : 0x00])
        case .integer(let value):
            element(tag: 0x02, integerBytes(value))
        case .string(let value):
            element(tag: 0x0C, Array(value.utf8))
        case .array(let values):
            element(tag: 0x30, values.flatMap(encode))
        case .dictionary(let entries):
            // [CONTEXT 16] { SEQUENCE { UTF8String key, value }... }, sorted by key
            element(tag: 0xB0, entries
                .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                .flatMap { element(tag: 0x30, encode(.string($0.key)) + encode($0.value)) })
        }
    }

    private static func element(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    private static func length(_ count: Int) -> [UInt8] {
        guard count >= 0x80 else { return [UInt8(count)] }
        let bytes = withUnsafeBytes(of: UInt64(count).bigEndian, Array.init).drop { $0 == 0 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    // minimal two's complement, big endian
    private static func integerBytes(_ value: Int) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int64(value).bigEndian, Array.init)
        while bytes.count > 1,
              (bytes[0] == 0x00 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0) {
            bytes.removeFirst()
        }
        return bytes
    }
}
