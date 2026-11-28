import Foundation

#if canImport(Compression)
import Compression
#elseif canImport(CLZMA)
import CLZMA
#endif

/// The algorithm used to compress the segments of an encrypted archive.
struct AEACompressionAlgorithm: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UInt8

    static let none = Self(rawValue: UInt8(ascii: "-"))
    static let lz4 = Self(rawValue: UInt8(ascii: "4"))
    static let lzbitmap = Self(rawValue: UInt8(ascii: "b"))
    static let lzfse = Self(rawValue: UInt8(ascii: "e"))
    static let lzvn = Self(rawValue: UInt8(ascii: "f"))
    static let lzma = Self(rawValue: UInt8(ascii: "x"))
    static let zlib = Self(rawValue: UInt8(ascii: "z"))

    var description: String {
        switch self {
        case .none: "none"
        case .lz4: "lz4"
        case .lzbitmap: "lzbitmap"
        case .lzfse: "lzfse"
        case .lzvn: "lzvn"
        case .lzma: "lzma"
        case .zlib: "zlib"
        default: "unknown (0x\(String(rawValue, radix: 16)))"
        }
    }

    /// Whether segments compressed with this algorithm can be decoded on the current platform.
    var isSupported: Bool {
        switch self {
        case .none, .lzma:
            true
        #if canImport(Compression)
        case .lz4, .lzbitmap, .lzfse, .zlib:
            true
        #endif
        default:
            false
        }
    }

    /// Decompresses `input` into exactly `size` bytes.
    func decompress(_ input: Data, size: Int) throws -> Data {
        if self == .none {
            guard input.count == size else {
                throw AEAError("Stored segment has size \(input.count), expected \(size)")
            }
            return input
        }
        #if canImport(Compression)
        let algorithm: compression_algorithm
        switch self {
        case .lzma: algorithm = COMPRESSION_LZMA
        // segments are raw LZ4 blocks without the "bv41" framing
        case .lz4: algorithm = COMPRESSION_LZ4_RAW
        case .lzbitmap: algorithm = COMPRESSION_LZBITMAP
        case .lzfse: algorithm = COMPRESSION_LZFSE
        case .zlib: algorithm = COMPRESSION_ZLIB
        default: throw AEAError("Unsupported compression algorithm: \(self)")
        }
        let input = self == .zlib ? try Self.stripZlibWrapper(input) : input
        // The buffer API silently truncates overlong output, so leave
        // room for one extra byte to be able to detect it.
        var output = Data(count: size + 1)
        let written = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                    nil, algorithm
                )
            }
        }
        guard written == size else {
            throw AEAError("Segment decompressed to \(written) bytes, expected \(size)")
        }
        output.removeLast()
        return output
        #elseif canImport(CLZMA)
        guard self == .lzma else {
            throw AEAError("Unsupported compression algorithm on this platform: \(self)")
        }
        var output = Data(count: size)
        var memlimit = UInt64.max
        var inPos = 0
        var outPos = 0
        let result = output.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                lzma_stream_buffer_decode(
                    &memlimit, 0, nil,
                    src.bindMemory(to: UInt8.self).baseAddress!, &inPos, src.count,
                    dst.bindMemory(to: UInt8.self).baseAddress!, &outPos, dst.count
                )
            }
        }
        guard result == LZMA_OK, inPos == input.count, outPos == size else {
            throw AEAError("Failed to decompress LZMA segment (status \(result.rawValue))")
        }
        return output
        #else
        throw AEAError("Unsupported compression algorithm on this platform: \(self)")
        #endif
    }

    #if canImport(Compression)
    /// COMPRESSION_ZLIB operates on raw DEFLATE streams, but AEA stores
    /// zlib-wrapped (RFC 1950) data.
    private static func stripZlibWrapper(_ input: Data) throws -> Data {
        guard input.count >= 6,
              input[input.startIndex] & 0x0F == 8,
              (UInt16(input[input.startIndex]) << 8 | UInt16(input[input.startIndex + 1])) % 31 == 0,
              input[input.startIndex + 1] & 0x20 == 0
        else { throw AEAError("Invalid zlib segment header") }
        return input.dropFirst(2).dropLast(4)
    }
    #endif
}

/// The checksum stored alongside each segment of an encrypted archive.
struct AEAChecksumAlgorithm: RawRepresentable, Hashable, Sendable {
    var rawValue: UInt8

    static let none = Self(rawValue: 0)
    static let murmur64 = Self(rawValue: 1)
    static let sha256 = Self(rawValue: 2)

    var size: Int? {
        switch self {
        case .none: 0
        case .murmur64: 8
        case .sha256: 32
        default: nil
        }
    }
}

/// MurmurHash64A with AEA's seed.
func murmur64(_ data: Data) -> UInt64 {
    let m: UInt64 = 0xc6a4_a793_5bd1_e995
    var h: UInt64 = 0xE223_6FDC_26A5_F6D2 ^ (UInt64(data.count) &* m)
    let blocks = data.count / 8
    for i in 0..<blocks {
        var k = data.loadLE(UInt64.self, at: i * 8)
        k = k &* m
        k ^= k >> 47
        k = k &* m
        h ^= k
        h = h &* m
    }
    let tail = data.count % 8
    if tail != 0 {
        for i in 0..<tail {
            h ^= UInt64(data[data.startIndex + blocks * 8 + i]) << (8 * i)
        }
        h = h &* m
    }
    h ^= h >> 47
    h = h &* m
    h ^= h >> 47
    return h
}
