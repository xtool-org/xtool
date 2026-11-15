import Foundation

extension Packer {
    private static let archiveMagics = [Data("!<arch>\n".utf8), Data("!<thin>\n".utf8)]
    private static let maxFatSlices = 64

    /// Whether the binary at `url` is a static archive, either bare or as every slice of a universal
    /// binary. Static frameworks are already linked into the executable, so they must not be embedded.
    ///
    /// The archive magics are listed in
    /// https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
    static func isStaticArchive(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        func read(_ count: Int, at offset: UInt64) throws -> Data {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }

        let header = try read(8, at: 0)
        if archiveMagics.contains(header) { return true }
        guard header.count == 8 else { return false }

        let archSize: Int
        switch header.bigEndian(UInt32.self, at: 0) {
        case 0xCAFEBABE: archSize = 20
        case 0xCAFEBABF: archSize = 32
        default: return false
        }
        let sliceCount = Int(header.bigEndian(UInt32.self, at: 4))
        guard (1...maxFatSlices).contains(sliceCount) else { return false }

        let archs = try read(sliceCount * archSize, at: 8)
        guard archs.count == sliceCount * archSize else { return false }
        return try (0..<sliceCount).allSatisfy { index in
            let offsetField = index * archSize + 8
            let sliceOffset = archSize == 32
                ? archs.bigEndian(UInt64.self, at: offsetField)
                : UInt64(archs.bigEndian(UInt32.self, at: offsetField))
            return try archiveMagics.contains(read(8, at: sliceOffset))
        }
    }
}

extension Data {
    fileprivate func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
