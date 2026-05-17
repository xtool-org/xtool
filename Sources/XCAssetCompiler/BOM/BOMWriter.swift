import Foundation

/// Writes a BOM (Bill of Materials) container.
///
/// Format derived from the public BOM headers (libbom) and reverse engineering
/// in https://blog.timac.org/2018/1018-reverse-engineering-the-car-file-format/
/// and https://dbg.re/posts/car-file-format/.
///
/// Container layout, big-endian throughout:
/// - 32-byte header at offset 0
/// - Block payloads packed sequentially
/// - Block index table at `indexOffset`: `count u32` then `(addr u32, len u32)` pairs (block 0 is null)
/// - Variables table at `varsOffset`: `count u32` then per-entry `{ blockID u32, nameLen u8, name[nameLen] }`
struct BOMWriter {
    struct Block {
        var data: Data
    }

    struct Variable {
        var name: String
        var blockID: UInt32
    }

    private var blocks: [Block] = []
    private var variables: [Variable] = []

    init() {
        // Block 0 is reserved/null.
        blocks.append(Block(data: Data()))
    }

    @discardableResult
    mutating func addBlock(_ data: Data) -> UInt32 {
        blocks.append(Block(data: data))
        return UInt32(blocks.count - 1)
    }

    mutating func setVariable(_ name: String, blockID: UInt32) {
        variables.append(Variable(name: name, blockID: blockID))
    }

    func finalize() -> Data {
        var writer = ByteWriter()

        // Header placeholder; we patch addresses after we know payload size.
        writer.write(Array("BOMStore".utf8)) // 0x00: magic (8 bytes)
        writer.writeBE(UInt32(1))            // 0x08: version
        writer.writeBE(UInt32(blocks.count)) // 0x0C: numberOfBlocks
        writer.writeBE(UInt32(0))            // 0x10: indexOffset (patched)
        writer.writeBE(UInt32(0))            // 0x14: indexLength (patched)
        writer.writeBE(UInt32(0))            // 0x18: varsOffset (patched)
        writer.writeBE(UInt32(0))            // 0x1C: varsLength (patched)
        // BOM headers are 512 bytes in some references; pad to be safe so block payloads
        // never overlap with the header.
        writer.writeZeros(512 - writer.offset)

        var blockOffsets: [UInt32] = [0] // block 0 is null
        for block in blocks.dropFirst() {
            blockOffsets.append(UInt32(writer.offset))
            writer.write(block.data)
        }

        let indexOffset = UInt32(writer.offset)
        writer.writeBE(UInt32(blocks.count))
        for (i, block) in blocks.enumerated() {
            let addr = i == 0 ? UInt32(0) : blockOffsets[i]
            let len = UInt32(block.data.count)
            writer.writeBE(addr)
            writer.writeBE(len)
        }
        let indexLength = UInt32(writer.offset) - indexOffset

        let varsOffset = UInt32(writer.offset)
        writer.writeBE(UInt32(variables.count))
        for v in variables {
            writer.writeBE(v.blockID)
            let nameBytes = Array(v.name.utf8)
            precondition(nameBytes.count <= 255)
            writer.write(byte: UInt8(nameBytes.count))
            writer.write(nameBytes)
        }
        let varsLength = UInt32(writer.offset) - varsOffset

        writer.patchBE(indexOffset, at: 0x10)
        writer.patchBE(indexLength, at: 0x14)
        writer.patchBE(varsOffset, at: 0x18)
        writer.patchBE(varsLength, at: 0x1C)

        return writer.data
    }
}
