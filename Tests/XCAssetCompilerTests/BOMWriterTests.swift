import Foundation
import Testing
@testable import XCAssetCompiler

@Suite("BOMWriter")
struct BOMWriterTests {
    @Test("Header has BOMStore magic and points to non-zero index/vars")
    func headerLayout() {
        var bom = BOMWriter()
        let id = bom.addBlock(Data([0xAA, 0xBB, 0xCC]))
        bom.setVariable("DEMO", blockID: id)
        let data = bom.finalize()
        let bytes = [UInt8](data)
        #expect(Array(bytes.prefix(8)) == Array("BOMStore".utf8))
        // version is BE u32 at 0x08
        #expect(bytes[8...11] == [0, 0, 0, 1])
        // numberOfBlocks is BE u32 at 0x0C; we have 2 (block 0 reserved + 1 we added)
        #expect(bytes[12...15] == [0, 0, 0, 2])
        let indexOff = readU32BE(data, 0x10)
        let varsOff = readU32BE(data, 0x18)
        #expect(indexOff > 0)
        #expect(varsOff > indexOff)
    }

    @Test("Tree round-trip: parse our own output structurally")
    func treeRoundTrip() {
        var bom = BOMWriter()
        let entries: [BOMTree.Entry] = [
            .init(key: Data("alpha".utf8), value: Data([0x01])),
            .init(key: Data("bravo".utf8), value: Data([0x02])),
            .init(key: Data("charlie".utf8), value: Data([0x03])),
        ]
        let treeBlockID = BOMTree.insert(into: &bom, entries: entries)
        bom.setVariable("TREE", blockID: treeBlockID)
        let data = bom.finalize()

        // Find the tree header block via the variables table
        let varsOff = Int(readU32BE(data, 0x18))
        let varsCount = Int(readU32BE(data, varsOff))
        var cursor = varsOff + 4
        var treeID: UInt32 = 0
        for _ in 0..<varsCount {
            let blockID = readU32BE(data, cursor)
            cursor += 4
            let nameLen = Int(data[data.index(data.startIndex, offsetBy: cursor)])
            cursor += 1
            let nameRange = cursor..<(cursor + nameLen)
            let name = String(decoding: data[nameRange.lowerBound..<nameRange.upperBound], as: UTF8.self)
            cursor += nameLen
            if name == "TREE" {
                treeID = blockID
            }
        }
        #expect(treeID != 0)

        // Parse block index to find the tree header block bytes
        let indexOff = Int(readU32BE(data, 0x10))
        let blockCount = Int(readU32BE(data, indexOff))
        var blocks: [(Int, Int)] = []
        for i in 0..<blockCount {
            let addr = Int(readU32BE(data, indexOff + 4 + i * 8))
            let len = Int(readU32BE(data, indexOff + 4 + i * 8 + 4))
            blocks.append((addr, len))
        }
        let (treeAddr, treeLen) = blocks[Int(treeID)]
        #expect(treeLen >= 21)
        let treeMagic = readU32BE(data, treeAddr)
        #expect(treeMagic == BOMTree.treeMagic)
        let leafBlockID = Int(readU32BE(data, treeAddr + 8))
        let (leafAddr, _) = blocks[leafBlockID]
        // leaf header: isLeaf u16, count u16
        let isLeaf = readU16BE(data, leafAddr)
        let count = readU16BE(data, leafAddr + 2)
        #expect(isLeaf == 1)
        #expect(count == 3)
    }

    private func readU32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.index(data.startIndex, offsetBy: offset)])
        let b1 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)])
        let b2 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)])
        let b3 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func readU16BE(_ data: Data, _ offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
        let b1 = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
        return (b0 << 8) | b1
    }
}
