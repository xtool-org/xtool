import Foundation

/// kThemeRenditionAttribute IDs for CoreUI 970 (StorageVersion 17, Xcode 26).
///
/// Values determined by dumping the KEYFORMAT block of an actool-produced
/// Assets.car (`xcrun assetutil --info`). Older CoreUI versions used a
/// different numbering; do not rely on writeups that predate Xcode 14.
enum AttributeID: UInt32 {
    case element = 1
    case part = 2
    case appearance = 7
    case dimension2 = 9
    case scale = 12
    case localization = 13
    case idiom = 15
    case subtype = 16
    case identifier = 17
}

/// Attribute order CoreUI 970 emits in `KEYFORMAT` (and which the rendition key
/// tuple positions mirror exactly). Order is significant: CoreUI binary-searches
/// rendition keys by raw byte comparison after packing them into this slot
/// layout.
let v1KeyFormat: [AttributeID] = [
    .appearance,
    .localization,
    .scale,
    .idiom,
    .subtype,
    .dimension2,
    .identifier,
    .element,
    .part,
]

/// `kfmt` block payload.
enum KeyFormatBlock {
    static let magic: UInt32 = 0x6B666D74 // 'kfmt' as LE multi-char constant

    static func data(attributes: [AttributeID] = v1KeyFormat) -> Data {
        var w = ByteWriter()
        w.writeLE(magic)
        w.writeLE(UInt32(0))                            // version
        w.writeLE(UInt32(attributes.count))             // maximumRenditionKeyTokenCount
        for attr in attributes {
            w.writeLE(attr.rawValue)
        }
        return w.data
    }
}
