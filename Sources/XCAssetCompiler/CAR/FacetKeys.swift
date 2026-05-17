import Foundation

/// FACETKEYS maps human-readable asset names to a list of attribute pairs that
/// CoreUI uses to seed a rendition lookup.
///
/// Value layout (verified against actool output, Xcode 26 / CoreUI 970):
/// - `cursorHotSpotX u16`, `cursorHotSpotY u16`
/// - `numberOfAttributes u16`
/// - array of `(attributeName u16, attributeValue u16)`
enum FacetKeys {
    static func value(for name: String, kind: Kind) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt16(0))            // cursorHotSpotX
        w.writeLE(UInt16(0))            // cursorHotSpotY
        let crc = nameHash(name)
        let identifier = UInt16(crc & 0xFFFF)
        let pairs = kind.pairs(identifier: identifier)
        w.writeLE(UInt16(pairs.count))
        for (attrName, attrValue) in pairs {
            w.writeLE(attrName)
            w.writeLE(attrValue)
        }
        return w.data
    }

    enum Kind {
        case appIcon
        case image
        case color

        func pairs(identifier: UInt16) -> [(UInt16, UInt16)] {
            switch self {
            case .appIcon:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.appIcon.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .image:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.image.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .color:
                return [
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            }
        }
    }

    /// CRC32 (IEEE) of the asset name, truncated to 16 bits for the identifier slot.
    static func nameHash(_ name: String) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in name.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
