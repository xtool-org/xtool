import Foundation

struct Rendition: Sendable {
    enum Body: Sendable {
        case bitmap(BitmapBody)
        case color(ColorBody)
    }

    var name: String
    var idiom: Idiom
    var scale: Scale?
    var appearance: Appearance?
    var gamut: Gamut?
    var body: Body
}

struct BitmapBody: Sendable {
    /// Which CoreUI rendition category this bitmap belongs to. Determines the
    /// `(element, part)` pair we encode in the rendition key and FACETKEYS
    /// value -- actool picks different codes for appicons vs. generic images,
    /// and UIImage(named:) only finds renditions whose part matches the
    /// expected category for the lookup path.
    enum Kind: Sendable {
        /// `element=85, part=220`. Used by SpringBoard's icon-render pipeline.
        case appIcon
        /// `element=85, part=181`. Used by UIImage(named:) for generic image
        /// assets from an `.imageset`.
        case image
    }

    var width: UInt32
    var height: UInt32
    var pixelsBGRA: [UInt8]
    var colorSpaceID: UInt8
    var kind: Kind
    /// The source filename (e.g. "icon@2x.png"). Stored in the CSI header's
    /// 128-char name field; actool uses the filename here, not the asset name.
    var renditionName: String
}

struct ColorBody: Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
    var colorSpaceID: UInt8
}
