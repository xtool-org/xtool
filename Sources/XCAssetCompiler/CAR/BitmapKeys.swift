import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a 52-byte descriptor block.
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
enum BitmapKeys {
    /// The 52-byte descriptor. Layout was derived by diffing actool's outputs
    /// for `.appiconset` vs `.imageset` renditions. The first 7 u32s are
    /// constant (header-like); the remaining 6 vary by asset kind.
    struct Descriptor {
        var kind: Kind
        /// Number of distinct (idiom, subtype) tuples this asset is keyed on.
        var idiomSubtypeCount: UInt32

        enum Kind {
            case appIcon
            case image
        }

        func encode() -> Data {
            var w = ByteWriter()
            // Header (constant across asset kinds in the reference).
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0x28))
            w.writeLE(UInt32(9))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0x0e))
            // Variable section. Values come from the actool reference.
            //   AppIcon  : [u32=2, u16=1, u16=1, u32=7]
            //   Image    : [u32=1, u16=1, u16=0, u32=1]
            // The exact semantics aren't fully reverse-engineered yet, so for
            // v1 we hardcode the templates per kind and pass through the
            // discovered (idiom, subtype) count. Field 7 in particular seems
            // to track that count.
            w.writeLE(idiomSubtypeCount)
            switch kind {
            case .appIcon:
                w.writeLE(UInt16(1))            // (u16, u16) tuple
                w.writeLE(UInt16(1))
                w.writeLE(UInt32(7))
            case .image:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
                w.writeLE(UInt32(1))
            }
            // Three trailing -1 sentinels.
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(0xFFFFFFFF))
            precondition(w.offset == 52, "BITMAPKEYS descriptor must be 52 bytes; got \(w.offset)")
            return w.data
        }
    }

    /// Per-asset BITMAPKEYS entry: `(NameIdentifier, descriptor bytes)`.
    static func entries(for assets: [(name: String, descriptor: Descriptor)]) -> [BOMTree.InlineKeyEntry] {
        return assets.map { asset in
            BOMTree.InlineKeyEntry(
                key: FacetKeys.nameHash(asset.name) & 0xFFFF,
                value: asset.descriptor.encode()
            )
        }
    }
}
