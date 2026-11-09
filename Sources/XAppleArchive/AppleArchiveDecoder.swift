import Foundation

/// The header of an entry in an Apple Archive (`.aar`) stream.
struct AppleArchiveHeader: Sendable {
    /// A field key such as `PAT` or `DAT`.
    struct Key: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        var rawValue: String

        var description: String { rawValue }

        static let type = Self(rawValue: "TYP")
        static let path = Self(rawValue: "PAT")
        static let linkPath = Self(rawValue: "LNK")
        static let mode = Self(rawValue: "MOD")
        static let modificationTime = Self(rawValue: "MTM")
        static let data = Self(rawValue: "DAT")
        static let hardLinkCluster = Self(rawValue: "HLC")
    }

    enum Value: Sendable, Hashable {
        case flag
        case uint(UInt64)
        case string(Data)
        case hash(Data)
        case timespec(seconds: Int64, nanoseconds: UInt32)
        /// A blob whose contents follow the header.
        case blob(size: UInt64)
    }

    struct EntryType: RawRepresentable, Hashable, Sendable {
        var rawValue: UInt8

        static let regularFile = Self(rawValue: UInt8(ascii: "F"))
        static let directory = Self(rawValue: UInt8(ascii: "D"))
        static let symbolicLink = Self(rawValue: UInt8(ascii: "L"))
        static let metadata = Self(rawValue: UInt8(ascii: "M"))
    }

    /// The header's fields, in order.
    var fields: [(key: Key, value: Value)]

    subscript(key: Key) -> Value? {
        fields.first { $0.key == key }?.value
    }

    var entryType: EntryType? {
        guard case .uint(let value)? = self[.type], let byte = UInt8(exactly: value) else { return nil }
        return EntryType(rawValue: byte)
    }

    /// The entry's path, relative to the root of the archive.
    var path: String? { string(.path) }

    var linkPath: String? { string(.linkPath) }

    var mode: UInt16? { uint(.mode).flatMap { UInt16(exactly: $0 & 0o7777) } }

    var hardLinkCluster: UInt64? { uint(.hardLinkCluster) }

    var modificationDate: Date? {
        guard case .timespec(let seconds, let nanoseconds)? = self[.modificationTime] else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9)
    }

    func uint(_ key: Key) -> UInt64? {
        guard case .uint(let value)? = self[key] else { return nil }
        return value
    }

    func string(_ key: Key) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    var blobs: [(key: Key, size: UInt64)] {
        fields.compactMap {
            guard case .blob(let size) = $0.value else { return nil }
            return ($0.key, size)
        }
    }
}

/// An incremental (push) decoder for Apple Archive (`.aar`) streams.
///
/// Feed it consecutive chunks of the stream with ``decode(_:handler:)``.
struct AppleArchiveDecoder {
    enum Event {
        /// The start of a new entry.
        case header(AppleArchiveHeader)
        /// A chunk of the blob `key` of the current entry. Blobs are delivered
        /// in the order they appear in the header.
        case blob(key: AppleArchiveHeader.Key, data: Data)
        /// The end of the current entry.
        case endOfEntry
    }

    private enum State {
        case header
        case blobs([(key: AppleArchiveHeader.Key, size: UInt64)], index: Int, remaining: UInt64)
    }

    private static let prefixSize = 6

    private var state = State.header
    private var buffer = Data()

    init() {}

    mutating func decode(_ chunk: Data, handler: (Event) throws -> Void) throws {
        var input = chunk[...]
        while !input.isEmpty {
            switch state {
            case .header:
                if buffer.count < Self.prefixSize {
                    let needed = Self.prefixSize - buffer.count
                    buffer.append(input.prefix(needed))
                    input = input.dropFirst(needed)
                    guard buffer.count == Self.prefixSize else { continue }
                    guard buffer.prefix(4) == Data("AA01".utf8) || buffer.prefix(4) == Data("YAA1".utf8) else {
                        throw AEAError("Invalid Apple Archive header magic")
                    }
                }
                let size = Int(buffer.loadLE(UInt16.self, at: 4))
                guard size >= Self.prefixSize else {
                    throw AEAError("Invalid Apple Archive header size: \(size)")
                }
                let needed = size - buffer.count
                buffer.append(input.prefix(needed))
                input = input.dropFirst(needed)
                guard buffer.count == size else { continue }

                let header = try Self.parseHeader(buffer.dropFirst(Self.prefixSize))
                buffer.removeAll(keepingCapacity: true)
                try handler(.header(header))
                state = .blobs(header.blobs, index: 0, remaining: header.blobs.first?.size ?? 0)
                try advance(handler: handler)
            case .blobs(let blobs, let index, let remaining):
                let count = Int(min(remaining, UInt64(input.count)))
                try handler(.blob(key: blobs[index].key, data: input.prefix(count)))
                input = input.dropFirst(count)
                state = .blobs(blobs, index: index, remaining: remaining - UInt64(count))
                try advance(handler: handler)
            }
        }
    }

    /// Validates that the stream did not end in the middle of an entry.
    func finish() throws {
        guard case .header = state, buffer.isEmpty else {
            throw AEAError("Apple Archive stream is truncated")
        }
    }

    /// Skips past completed blobs, ending the entry if there are none left.
    private mutating func advance(handler: (Event) throws -> Void) throws {
        guard case .blobs(let blobs, var index, var remaining) = state else { return }
        while remaining == 0 {
            index += 1
            guard index < blobs.count else {
                state = .header
                try handler(.endOfEntry)
                return
            }
            remaining = blobs[index].size
        }
        state = .blobs(blobs, index: index, remaining: remaining)
    }

    private static let uintSizes: [UInt8: Int] = [
        UInt8(ascii: "1"): 1, UInt8(ascii: "2"): 2, UInt8(ascii: "4"): 4, UInt8(ascii: "8"): 8,
    ]
    private static let blobSizeSizes: [UInt8: Int] = [
        UInt8(ascii: "A"): 2, UInt8(ascii: "B"): 4, UInt8(ascii: "C"): 8,
    ]
    private static let hashSizes: [UInt8: Int] = [
        UInt8(ascii: "F"): 4, UInt8(ascii: "G"): 20, UInt8(ascii: "H"): 32, UInt8(ascii: "I"): 48, UInt8(ascii: "J"): 64,
    ]

    private static func parseHeader(_ data: Data) throws -> AppleArchiveHeader {
        let data = Data(data)
        var fields: [(key: AppleArchiveHeader.Key, value: AppleArchiveHeader.Value)] = []
        var offset = 0

        func take(_ count: Int) throws -> Data {
            guard data.count - offset >= count else {
                throw AEAError("Truncated Apple Archive header field")
            }
            defer { offset += count }
            return data.bytes(at: offset, count: count)
        }

        func uint(size: Int) throws -> UInt64 {
            try take(size).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        while offset < data.count {
            let tag = try take(4)
            let key = AppleArchiveHeader.Key(rawValue: String(decoding: tag.prefix(3), as: UTF8.self))
            let type = tag[3]
            let value: AppleArchiveHeader.Value
            if type == UInt8(ascii: "*") {
                value = .flag
            } else if let size = uintSizes[type] {
                value = .uint(try uint(size: size))
            } else if let size = blobSizeSizes[type] {
                value = .blob(size: try uint(size: size))
            } else if let size = hashSizes[type] {
                value = .hash(try take(size))
            } else if type == UInt8(ascii: "P") {
                value = .string(try take(Int(try uint(size: 2))))
            } else if type == UInt8(ascii: "S") {
                value = .timespec(seconds: Int64(bitPattern: try uint(size: 8)), nanoseconds: 0)
            } else if type == UInt8(ascii: "T") {
                let seconds = Int64(bitPattern: try uint(size: 8))
                value = .timespec(seconds: seconds, nanoseconds: UInt32(try uint(size: 4)))
            } else {
                throw AEAError("Unknown Apple Archive field type: \(String(decoding: tag, as: UTF8.self))")
            }
            fields.append((key, value))
        }
        return AppleArchiveHeader(fields: fields)
    }
}
