import Foundation
#if canImport(Compression)
import Compression
#endif

/// CSI ("CTSI") rendition header is 184 bytes little-endian, followed by an
/// optional TVL section (currently unused, tvlLength=0) and then the body.
/// Layout verified against the reference Assets.car produced by actool
/// (Xcode 26 / CoreUI 970): on disk the tag reads "ISTC" (CTSI as an LE
/// multi-char constant), layout=12 for bitmap icons, scaleFactor=scale*100.
enum CSIWriter {
    /// 'CTSI' as an LE multi-char constant. Produces file bytes I,S,T,C.
    static let tag: UInt32 = 0x43545349

    /// `pixelFormat` = 'ARGB' as an LE multi-char constant. Produces file
    /// bytes B,G,R,A. The pixel encoding is in BGRA byte order in memory.
    static let pixelFormatARGB: UInt32 = 0x41524742

    /// Layout types observed in the reference. The names are derived from
    /// CoreUI symbol names where known.
    enum Layout: UInt16 {
        /// Per the reference: every raw bitmap icon emitted by actool uses 12.
        case bitmapIcon = 12
        case namedColor = 1009
    }

    static func bitmap(name: String, body: BitmapBody, scaleFactor: UInt32) -> Data {
        let tvl = bitmapTVL(width: body.width, height: body.height)
        let payload = bitmapBody(width: body.width, height: body.height, pixels: body.pixelsBGRA)
        // actool sets bit 4 of renditionFlags for `.image` (generic) bitmaps
        // and leaves it cleared for `.appIcon`. We mirror this; the bit is
        // structural and on-device UIImage(named:) resolution does work
        // through the LZFSE+KCBC path verified end-to-end.
        let renditionFlags: UInt32 = (body.kind == .image) ? 0x10 : 0x00
        var w = ByteWriter()
        writeHeader(
            into: &w,
            renditionFlags: renditionFlags,
            width: body.width,
            height: body.height,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormatARGB,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .bitmapIcon,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        w.write(tvl)
        w.write(payload)
        return w.data
    }

    static func color(name: String, body: ColorBody) -> Data {
        let payload = colorBody(body: body)
        var w = ByteWriter()
        writeHeader(
            into: &w,
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 100,
            pixelFormat: 0,
            colorSpace: UInt32(body.colorSpaceID),
            layout: .namedColor,
            name: name,
            tvlLength: 0,
            bitmapCount: 0,
            renditionLength: UInt32(payload.count)
        )
        w.write(payload)
        return w.data
    }

    // swiftlint:disable:next function_parameter_count
    private static func writeHeader(
        into w: inout ByteWriter,
        renditionFlags: UInt32,
        width: UInt32,
        height: UInt32,
        scaleFactor: UInt32,
        pixelFormat: UInt32,
        colorSpace: UInt32,
        layout: Layout,
        name: String,
        tvlLength: UInt32,
        bitmapCount: UInt32,
        renditionLength: UInt32
    ) {
        let start = w.offset
        w.writeLE(tag)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(renditionFlags)
        w.writeLE(width)
        w.writeLE(height)
        w.writeLE(scaleFactor)
        w.writeLE(pixelFormat)
        w.writeLE(colorSpace)
        w.writeLE(UInt32(0))                    // modtime (matches reference; was wall-clock)
        w.writeLE(layout.rawValue)
        w.writeLE(UInt16(0))                    // zero
        w.writePadded(name, length: 128)
        w.writeLE(tvlLength)
        w.writeLE(bitmapCount)
        w.writeLE(UInt32(0))                    // reserved
        w.writeLE(renditionLength)
        precondition(w.offset - start == 184, "CSI header must be 184 bytes; got \(w.offset - start)")
    }

    /// MLEC wrapper for bitmap pixels, framed in a single KCBC chunk.
    ///
    /// Layout verified against actool's reference Assets.car:
    ///
    ///   MLEC magic        4 bytes
    ///   compressionType   u32  (0 = raw, 3 = LZFSE)
    ///   bytesPerPixel     u32  (4 for BGRA8)
    ///   chunkCount        u32  (1 for our single-chunk path)
    ///   then chunkCount * KCBC chunks
    ///
    /// Each KCBC chunk:
    ///
    ///   KCBC magic        4 bytes
    ///   reserved          8 zero bytes
    ///   chunkHeight       u32  (rows covered by this chunk)
    ///   payloadSize       u32  (bytes of compressed/raw payload following)
    ///   payload[]         raw BGRA pixels (when compressionType=0)
    ///                     or LZFSE bvx2 stream (when compressionType=3)
    /// 104-byte TVL (type-length-value) metadata block emitted between the
    /// CSI header and the MLEC body for bitmap renditions.
    ///
    /// Five entries, with types and values derived from actool's reference
    /// output. Without these, CoreUI can parse the rendition's key but cannot
    /// "materialize" the bitmap -- `assetutil --info` reports AssetType
    /// "Unknown" and omits PixelWidth/PixelHeight/Encoding/Compression.
    private static func bitmapTVL(width: UInt32, height: UInt32) -> Data {
        var w = ByteWriter()

        // Type 1001 (20-byte value): bitmap descriptor.
        // Fields: (1, 0, 0, width, height). The leading 1 is presumed to be a
        // bitmap-type/flags field; the trailing dims duplicate the CSI header
        // dims and seem to be what CoreUI consults during materialisation.
        w.writeLE(UInt32(1001))
        w.writeLE(UInt32(20))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1003 (28-byte value): destination rect.
        // Fields: (1, 0, 0, 0, 0, width, height) -- (flags, x, y, z, w, w, h).
        w.writeLE(UInt32(1003))
        w.writeLE(UInt32(28))
        w.writeLE(UInt32(1))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(0))
        w.writeLE(width)
        w.writeLE(height)

        // Type 1004 (8-byte value): slice/scale pair. Reference is (0, 1.0f).
        w.writeLE(UInt32(1004))
        w.writeLE(UInt32(8))
        w.writeLE(UInt32(0))
        w.writeLE(UInt32(Float(1).bitPattern))

        // Type 1006 (4-byte value): always 1 in the reference. Likely a
        // bitmap-count/has-mipmap-stages flag.
        w.writeLE(UInt32(1006))
        w.writeLE(UInt32(4))
        w.writeLE(UInt32(1))

        // Type 1007 (4-byte value): bytes per row, aligned up to 16.
        w.writeLE(UInt32(1007))
        w.writeLE(UInt32(4))
        let bytesPerRow = width * 4
        let aligned = (bytesPerRow + 15) & ~15
        w.writeLE(aligned)

        precondition(w.offset == 104, "bitmap TVL must be 104 bytes; got \(w.offset)")
        return w.data
    }

    private static func bitmapBody(width: UInt32, height: UInt32, pixels: [UInt8]) -> Data {
        // actool splits appicon bitmaps into 3 KCBC chunks of equal row
        // height (120 -> 3x40, 180 -> 3x60). We mirror that when the height
        // divides evenly by 3; otherwise we fall back to a single chunk
        // covering the whole image. The 3-chunk split is mimicry rather than
        // a correctness requirement: CoreUI accepts both layouts.
        //
        // The MLEC wrapper always advertises compressionType=3 (LZFSE) and
        // each chunk payload is a valid LZFSE stream. On macOS we let
        // Apple's Compression framework actually compress. On Linux we emit
        // a single LZFSE "uncompressed block" envelope (`bvx-` + size +
        // raw bytes + `bvx$` end-of-stream); CoreUI's LZFSE decoder reads
        // this as a passthrough and ends up with the raw pixels intact.
        // Size cost on Linux: roughly the raw bitmap size + 12 bytes per
        // chunk. Avoiding the alternative (compressionType=0 raw, which
        // CoreUI's runtime quietly fails to materialise) is worth it.
        let bytesPerRow = Int(width) * 4
        let canChunkInThree = height % 3 == 0
        let chunkCount: UInt32 = canChunkInThree ? 3 : 1
        let rowsPerChunk = height / chunkCount

        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        for i in 0..<Int(chunkCount) {
            let start = i * Int(rowsPerChunk) * bytesPerRow
            let end = start + Int(rowsPerChunk) * bytesPerRow
            let slice = Array(pixels[start..<end])
            chunks.append((rows: rowsPerChunk, payload: lzfseEncode(slice)))
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(UInt32(3))                    // compressionType = 3 (LZFSE)
        w.writeLE(UInt32(4))                    // bytesPerPixel (BGRA8 = 4)
        w.writeLE(chunkCount)

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }

    /// Produce a valid LZFSE stream from `input`.
    ///
    /// On macOS, uses Apple's Compression framework for actual LZFSE
    /// compression. On Linux, where `Compression` is not part of the Swift
    /// SDK (it's a Darwin-only system framework, closed source, not
    /// redistributed), hand-emits the LZFSE "uncompressed block" envelope.
    /// CoreUI's LZFSE decoder reads it as a passthrough and ends up with
    /// the raw pixels intact -- verified rendering on a real iOS device
    /// from a Linux-built `Assets.car`.
    ///
    /// LZFSE uncompressed block layout (from lzfse_internal.h):
    ///
    ///   magic        u32  ('bvx-' = LZFSE_UNCOMPRESSED_BLOCK_MAGIC)
    ///   n_raw_bytes  u32  (size of the raw payload that follows)
    ///   payload      raw bytes
    ///   end magic    u32  ('bvx$' = LZFSE_ENDOFSTREAM_BLOCK_MAGIC)
    ///
    /// **Future option:** vendor an LZFSE implementation so Linux gets
    /// real compression instead of passthrough. That would close the
    /// bundle-size gap and remove our dependency on CoreUI continuing to
    /// accept the uncompressed-block path. It is purely an optimisation;
    /// the passthrough is structurally valid LZFSE per Apple's own spec.
    private static func lzfseEncode(_ input: [UInt8]) -> [UInt8] {
        #if canImport(Compression)
        let bound = input.count + 256
        var output = [UInt8](repeating: 0, count: bound)
        let encoded = input.withUnsafeBufferPointer { inBuf -> Int in
            output.withUnsafeMutableBufferPointer { outBuf in
                compression_encode_buffer(
                    outBuf.baseAddress!, bound,
                    inBuf.baseAddress!, input.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        precondition(encoded > 0, "LZFSE encoding failed for \(input.count)-byte buffer")
        return Array(output.prefix(encoded))
        #else
        var w = ByteWriter()
        w.writeFourCC("bvx-")                   // uncompressed block magic
        w.writeLE(UInt32(input.count))          // n_raw_bytes
        w.write(input)                          // raw payload
        w.writeFourCC("bvx$")                   // end-of-stream magic
        return Array(w.data)
        #endif
    }

    private static func colorBody(body: ColorBody) -> Data {
        var w = ByteWriter()
        w.writeFourCC("COLR")
        w.writeLE(UInt32(0))                    // version
        w.writeLE(UInt32(body.colorSpaceID))    // colorSpaceID with flag bits
        w.writeLE(UInt32(4))                    // numberOfComponents
        for component in [body.red, body.green, body.blue, body.alpha] {
            w.writeLE(component.bitPattern)
        }
        return w.data
    }
}
