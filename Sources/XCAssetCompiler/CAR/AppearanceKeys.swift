import Foundation

/// APPEARANCEKEYS tree: maps appearance name strings to UInt32 IDs that match
/// the `appearance` attribute values appearing in rendition keys.
///
/// CoreUI's runtime walks this tree by exact name-string match to resolve
/// the appearance slot in a rendition key. Every numeric ID that can appear
/// in a rendition key must have a row here, or the rendition lookup
/// silently fails (UIImage(named:) returns nil with no error).
///
/// **Platform difference:** iOS uses `UIAppearanceAny` / `UIAppearanceDark`.
/// macOS uses `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua`. Since
/// xtool only targets iOS apps, we register the UIAppearance* names. Both
/// `any` and `dark` rows are required because `RenditionKey.init(rendition:)`
/// packs `appearance=0` for default variants and `appearance=1` for dark
/// (`luminosity dark`) variants; omitting either row breaks lookups for
/// the corresponding catalog entries.
enum AppearanceKeys {
    static let any: UInt32 = 0
    static let dark: UInt32 = 1

    static func entries() -> [BOMTree.Entry] {
        [
            BOMTree.Entry(
                key: Data("UIAppearanceAny".utf8),
                value: Self.encodeID(any)
            ),
            BOMTree.Entry(
                key: Data("UIAppearanceDark".utf8),
                value: Self.encodeID(dark)
            ),
        ]
    }

    private static func encodeID(_ id: UInt32) -> Data {
        var w = ByteWriter()
        w.writeLE(id)
        return w.data
    }
}
