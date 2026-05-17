import Foundation

/// EXTENDED_METADATA: a fixed-size, 1028-byte block CoreUI consults during
/// catalog validation. Layout (verified against actool, Xcode 26 / CoreUI 970):
///
/// - `[0x000..0x100)` -- META magic (4 bytes 'M','E','T','A') + 252 zero bytes
/// - `[0x100..0x200)` -- PlatformVersion (e.g. "16.0"): 4 prefix zeros + 252
///   bytes of NUL-padded string
/// - `[0x200..0x300)` -- Platform (e.g. "ios"): same layout
/// - `[0x300..0x400)` -- Authoring Tool string: same layout
/// - `[0x400..0x404)` -- 4 trailing zeros
///
/// Without this block, UIImage(named:) lookup fails on device for non-icon
/// imageset assets even when FACETKEYS / RENDITIONS / BITMAPKEYS all resolve
/// correctly -- CoreUI appears to gate image-asset materialisation on the
/// platform match recorded here.
enum ExtendedMetadata {
    static let defaultPlatform = "ios"
    static let defaultAuthoringTool = "xtool clean-room CAR writer (Assets.car v1)"

    static func data(
        deploymentTarget: String,
        platform: String = defaultPlatform,
        authoringTool: String = defaultAuthoringTool
    ) -> Data {
        var w = ByteWriter()
        // Slot 0: META magic + 252 zeros (the first slot is the only one that
        // doesn't follow the 4-prefix/252-string pattern).
        w.writeFourCC("META")
        w.writeZeros(252)
        // Slot 1: PlatformVersion (deployment target).
        writeStringSlot(into: &w, deploymentTarget)
        // Slot 2: Platform name ("ios").
        writeStringSlot(into: &w, platform)
        // Slot 3: Authoring Tool string.
        writeStringSlot(into: &w, authoringTool)
        // Trailing 4 zero bytes.
        w.writeZeros(4)
        precondition(w.offset == 1028, "EXTENDED_METADATA must be 1028 bytes; got \(w.offset)")
        return w.data
    }

    private static func writeStringSlot(into w: inout ByteWriter, _ value: String) {
        w.writeZeros(4)                     // 4-byte prefix (unused / reserved)
        w.writePadded(value, length: 252)
    }
}
