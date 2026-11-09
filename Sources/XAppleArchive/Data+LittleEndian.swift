import Foundation

extension Data {
    /// Reads a little-endian integer at the zero-based `offset`.
    func loadLE<T: FixedWidthInteger>(_: T.Type = T.self, at offset: Int) -> T {
        var value: T = 0
        Swift.withUnsafeMutableBytes(of: &value) { dest in
            let start = startIndex + offset
            dest.copyBytes(from: self[start..<(start + MemoryLayout<T>.size)])
        }
        return T(littleEndian: value)
    }

    /// A copy of the `count` bytes starting at the zero-based `offset`.
    func bytes(at offset: Int, count: Int) -> Data {
        let start = startIndex + offset
        return Data(self[start..<(start + count)])
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
