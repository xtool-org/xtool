import Foundation

struct ByteWriter {
    private(set) var data: Data = Data()

    var offset: Int { data.count }

    mutating func write(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    mutating func write(_ slice: Data) {
        data.append(slice)
    }

    mutating func write(byte: UInt8) {
        data.append(byte)
    }

    mutating func writeBE(_ value: UInt16) {
        data.append(UInt8(value >> 8 & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func writeBE(_ value: UInt32) {
        data.append(UInt8(value >> 24 & 0xFF))
        data.append(UInt8(value >> 16 & 0xFF))
        data.append(UInt8(value >> 8 & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    mutating func writeLE(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8 & 0xFF))
    }

    mutating func writeLE(_ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8 & 0xFF))
        data.append(UInt8(value >> 16 & 0xFF))
        data.append(UInt8(value >> 24 & 0xFF))
    }

    mutating func writeLE(_ value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }

    mutating func writeFourCC(_ s: String) {
        precondition(s.utf8.count == 4)
        data.append(contentsOf: Array(s.utf8))
    }

    mutating func writePadded(_ s: String, length: Int) {
        let bytes = Array(s.utf8.prefix(length))
        data.append(contentsOf: bytes)
        if bytes.count < length {
            data.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
        }
    }

    mutating func writeZeros(_ count: Int) {
        data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    mutating func patchBE(_ value: UInt32, at offset: Int) {
        data[data.startIndex + offset + 0] = UInt8(value >> 24 & 0xFF)
        data[data.startIndex + offset + 1] = UInt8(value >> 16 & 0xFF)
        data[data.startIndex + offset + 2] = UInt8(value >> 8 & 0xFF)
        data[data.startIndex + offset + 3] = UInt8(value & 0xFF)
    }
}
