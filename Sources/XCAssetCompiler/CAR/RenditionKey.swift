import Foundation

/// Packed rendition key matching `v1KeyFormat` (CoreUI 970, 9 attributes).
///
/// Encoded as a sequence of little-endian `UInt16` tokens, one per attribute,
/// in the order declared by `KEYFORMAT`. The pair `(attributeID, attributeValue)`
/// is implicit: the position in the tuple selects which attribute the token
/// belongs to. Total size is 18 bytes (9 × u16).
struct RenditionKey: Hashable, Sendable {
    var appearance: UInt16
    var localization: UInt16
    var scale: UInt16
    var idiom: UInt16
    var subtype: UInt16
    var dimension2: UInt16
    var identifier: UInt16
    var element: UInt16
    var part: UInt16

    /// CoreUI element IDs that v1 emits. Values dumped from reference
    /// `Assets.car` produced by actool (Xcode 26 / CoreUI 970).
    enum Element: UInt16 {
        /// Element used by both `.image` (imageset) and `.appIcon` bitmap
        /// renditions. The category is differentiated by `Part` below.
        case bitmap = 85
    }

    /// CoreUI part IDs that v1 emits.
    enum Part: UInt16 {
        /// Used by SpringBoard's icon-render pipeline (`.appiconset`).
        case appIcon = 220
        /// Used by UIImage(named:) for generic `.imageset` assets.
        case image = 181
    }

    init(rendition: Rendition) {
        self.appearance = (rendition.appearance?.darkLuminosity == true) ? 1 : 0
        self.localization = 0
        self.scale = rendition.scale?.rawValueByte ?? 0
        self.idiom = rendition.idiom.rawValueByte
        self.subtype = 0
        self.identifier = UInt16(FacetKeys.nameHash(rendition.name) & 0xFFFF)
        switch rendition.body {
        case .bitmap(let body):
            self.element = Element.bitmap.rawValue
            switch body.kind {
            case .appIcon:
                self.part = Part.appIcon.rawValue
                // Dimension2 is the appicon "Icon Index" slot. v1 only
                // emits one logical icon size per appiconset, so this is
                // always 1.
                self.dimension2 = 1
            case .image:
                self.part = Part.image.rawValue
                // Generic image assets don't use Dimension2 at all.
                self.dimension2 = 0
            }
        case .color:
            self.element = 0
            self.part = 0
            self.dimension2 = 0
        }
    }

    init(
        appearance: UInt16 = 0,
        localization: UInt16 = 0,
        scale: UInt16 = 0,
        idiom: UInt16 = 0,
        subtype: UInt16 = 0,
        dimension2: UInt16 = 0,
        identifier: UInt16 = 0,
        element: UInt16 = 0,
        part: UInt16 = 0
    ) {
        self.appearance = appearance
        self.localization = localization
        self.scale = scale
        self.idiom = idiom
        self.subtype = subtype
        self.dimension2 = dimension2
        self.identifier = identifier
        self.element = element
        self.part = part
    }

    func encode() -> Data {
        var w = ByteWriter()
        w.writeLE(appearance)
        w.writeLE(localization)
        w.writeLE(scale)
        w.writeLE(idiom)
        w.writeLE(subtype)
        w.writeLE(dimension2)
        w.writeLE(identifier)
        w.writeLE(element)
        w.writeLE(part)
        return w.data
    }

    static func decode(_ data: Data) -> RenditionKey? {
        guard data.count == 18 else { return nil }
        func u16(_ offset: Int) -> UInt16 {
            let lo = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
            let hi = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
            return lo | (hi << 8)
        }
        return RenditionKey(
            appearance: u16(0),
            localization: u16(2),
            scale: u16(4),
            idiom: u16(6),
            subtype: u16(8),
            dimension2: u16(10),
            identifier: u16(12),
            element: u16(14),
            part: u16(16)
        )
    }
}
