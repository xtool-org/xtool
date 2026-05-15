import Foundation

/// APPEARANCEKEYS tree: maps appearance name strings to UInt32 IDs that match
/// the `appearance` attribute values appearing in rendition keys.
///
/// **Important platform difference:** iOS uses `UIAppearanceAny` /
/// `UIAppearanceDark`; macOS uses `NSAppearanceNameAqua` /
/// `NSAppearanceNameDarkAqua`. CoreUI's runtime walks this tree by exact
/// name string -- on iOS, an Assets.car that registers only the macOS
/// names will silently fail every `UIImage(named:)` lookup because the
/// "any" appearance can't be resolved to its numeric ID, and the rendition
/// key match never succeeds.
enum AppearanceKeys {
    static let any: UInt32 = 0
    static let dark: UInt32 = 1

    static func entries() -> [BOMTree.Entry] {
        [
            BOMTree.Entry(
                key: Data("UIAppearanceAny".utf8),
                value: Self.encodeID(any)
            ),
        ]
    }

    private static func encodeID(_ id: UInt32) -> Data {
        var w = ByteWriter()
        w.writeLE(id)
        return w.data
    }
}
