//
//  RemoteXPCCodec.swift
//  XKit
//
//  RemoteXPC is the binary message format iOS 17+ uses for the RSD/pairing/tunnel control-plane
//  protocols (carried as HTTP/2 DATA frames -- see `MinimalHTTP2Framer.swift`). Nothing in xtool's
//  dependency graph implements it -- this is a from-scratch implementation, structured after the
//  documented, working reference in go-ios's `ios/xpc/encoding.go` (MIT -- read for wire format,
//  rewritten from scratch in Swift here; same clean-room approach as `DTXMessage.swift`).
//
//  Wire layout of a full RemoteXPC message:
//
//    wrapper header (24 bytes, little-endian):
//      u32 magic       0x29b00b92
//      u32 flags
//      u64 bodyLen     0 if there's no body (nothing follows)
//      u64 msgId
//
//    body (bodyLen bytes, omitted entirely when bodyLen == 0):
//      u32 magic       0x42133742
//      u32 version     5
//      <object>        always a dictionary in practice, encoded per the `RemoteXPCValue` cases
//
//    object encoding: every value is prefixed by a u32 type tag, then type-specific payload.
//    Strings/dictionary keys are NUL-terminated and the whole field (tag-relative for strings,
//    key-relative for dictionary keys) is padded to a multiple of 4 bytes. data/string/array/
//    dictionary payloads are additionally prefixed by their own u32 byte length.
//

import Foundation

enum RemoteXPCValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case date(Date)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([RemoteXPCValue])
    case dictionary([String: RemoteXPCValue])
}

enum RemoteXPCFlag {
    static let alwaysSet: UInt32 = 0x0000_0001
    static let data: UInt32 = 0x0000_0100
    /// `0x0001_0000` is the generic "this message expects a reply" bit -- go-ios/pymobiledevice3
    /// both use it for plain request/response RPCs (e.g. `com.apple.coredevice.appservice`
    /// invocations), not just heartbeats. `heartbeatRequest` below is the same numeric value,
    /// kept as-is since it's already used that way elsewhere; this is just the correctly-named
    /// alias for non-heartbeat callers.
    static let wantsReply: UInt32 = 0x0001_0000
    static let heartbeatRequest: UInt32 = 0x0001_0000
    static let heartbeatReply: UInt32 = 0x0002_0000
    static let fileOpen: UInt32 = 0x0010_0000
    static let initHandshake: UInt32 = 0x0040_0000
}

struct RemoteXPCMessage: Sendable {
    var flags: UInt32
    /// `nil` means "no body at all" (an empty wrapper, `bodyLen == 0`), distinct from an empty
    /// dictionary body -- mirrors go-ios's `Message.Body == nil` special case.
    var body: [String: RemoteXPCValue]?
    var id: UInt64 = 0
}

enum RemoteXPCError: Swift.Error {
    case badMagic
    case badVersion
    case notEnoughData
    case unknownType(UInt32)
    case bodyNotADictionary
}

enum RemoteXPCCodec {
    private static let wrapperMagic: UInt32 = 0x29b0_0b92
    private static let objectMagic: UInt32 = 0x4213_3742
    private static let bodyVersion: UInt32 = 0x0000_0005

    /// Size of the fixed wrapper header (magic + flags + bodyLen + msgId), i.e. how many bytes a
    /// stream-based reader must pull before it can determine how many further bytes (`bodyLen`,
    /// per `bodyLength(fromHeader:)`) make up the rest of the message.
    static let wrapperHeaderLength = 24

    /// Reads the `bodyLen` field out of a message's first `wrapperHeaderLength` bytes, for
    /// callers (like `RemoteXPCConnection`) that read a message off a byte stream in two passes:
    /// header first, then exactly `bodyLength` more bytes, before handing the whole thing to
    /// `decode(_:)`.
    static func bodyLength(fromHeader header: Data) throws -> UInt64 {
        var cursor = header.startIndex
        guard try readLE(header, &cursor, as: UInt32.self) == wrapperMagic else {
            throw RemoteXPCError.badMagic
        }
        _ = try readLE(header, &cursor, as: UInt32.self) // flags
        return try readLE(header, &cursor, as: UInt64.self)
    }

    private enum WireType: UInt32 {
        case null = 0x0000_1000
        case bool = 0x0000_2000
        case int64 = 0x0000_3000
        case uint64 = 0x0000_4000
        case double = 0x0000_5000
        case date = 0x0000_7000
        case data = 0x0000_8000
        case string = 0x0000_9000
        case uuid = 0x0000_a000
        case array = 0x0000_e000
        case dictionary = 0x0000_f000
    }

    // MARK: - Encoding

    static func encode(_ message: RemoteXPCMessage) -> Data {
        var out = Data()
        appendLE(&out, wrapperMagic)
        appendLE(&out, message.flags)
        guard let body = message.body else {
            appendLE(&out, UInt64(0)) // bodyLen
            appendLE(&out, message.id)
            return out
        }
        var bodyData = Data()
        appendLE(&bodyData, objectMagic)
        appendLE(&bodyData, bodyVersion)
        encodeDictionary(&bodyData, body)

        appendLE(&out, UInt64(bodyData.count))
        appendLE(&out, message.id)
        out += bodyData
        return out
    }

    private static func encodeValue(_ out: inout Data, _ value: RemoteXPCValue) {
        switch value {
        case .null:
            appendLE(&out, WireType.null.rawValue)
        case .bool(let b):
            appendLE(&out, WireType.bool.rawValue)
            out.append(b ? 1 : 0)
            out.append(contentsOf: [0, 0, 0]) // padding to 4 bytes, matching Go's `pad [3]byte`
        case .int64(let i):
            appendLE(&out, WireType.int64.rawValue)
            appendLE(&out, UInt64(bitPattern: i))
        case .uint64(let u):
            appendLE(&out, WireType.uint64.rawValue)
            appendLE(&out, u)
        case .double(let d):
            appendLE(&out, WireType.double.rawValue)
            appendLE(&out, d.bitPattern)
        case .date(let date):
            appendLE(&out, WireType.date.rawValue)
            let nanos = Int64(date.timeIntervalSince1970 * 1_000_000_000)
            appendLE(&out, UInt64(bitPattern: nanos))
        case .data(let data):
            appendLE(&out, WireType.data.rawValue)
            appendLE(&out, UInt32(data.count))
            out += data
            out += Data(repeating: 0, count: Int(calcPadding(UInt32(data.count))))
        case .string(let s):
            let utf8 = Array(s.utf8)
            appendLE(&out, WireType.string.rawValue)
            appendLE(&out, UInt32(utf8.count + 1)) // +1 for NUL terminator
            let padded = Int(calcPadding(UInt32(utf8.count + 1)))
            out += Data(utf8)
            out += Data(repeating: 0, count: 1 + padded)
        case .uuid(let uuid):
            appendLE(&out, WireType.uuid.rawValue)
            withUnsafeBytes(of: uuid.uuid) { out.append(contentsOf: $0) }
        case .array(let values):
            var inner = Data()
            for v in values { encodeValue(&inner, v) }
            appendLE(&out, WireType.array.rawValue)
            appendLE(&out, UInt32(inner.count))
            appendLE(&out, UInt32(values.count))
            out += inner
        case .dictionary(let dict):
            encodeDictionary(&out, dict)
        }
    }

    private static func encodeDictionary(_ out: inout Data, _ dict: [String: RemoteXPCValue]) {
        var inner = Data()
        appendLE(&inner, UInt32(dict.count))
        for (key, value) in dict {
            encodeDictionaryKey(&inner, key)
            encodeValue(&inner, value)
        }
        appendLE(&out, WireType.dictionary.rawValue)
        appendLE(&out, UInt32(inner.count))
        out += inner
    }

    private static func encodeDictionaryKey(_ out: inout Data, _ key: String) {
        let utf8 = Array(key.utf8)
        let strLen = utf8.count + 1
        let padding = Int(calcPadding(UInt32(strLen)))
        out += Data(utf8)
        out += Data(repeating: 0, count: 1 + padding)
    }

    /// Rounds `l` up to the next multiple of 4 and returns the number of padding bytes needed.
    private static func calcPadding(_ l: UInt32) -> UInt32 {
        let rounded = ((l + 3) / 4) * 4
        return rounded - l
    }

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> RemoteXPCMessage {
        var cursor = data.startIndex
        guard try readLE(data, &cursor, as: UInt32.self) == wrapperMagic else {
            throw RemoteXPCError.badMagic
        }
        let flags = try readLE(data, &cursor, as: UInt32.self)
        let bodyLen = try readLE(data, &cursor, as: UInt64.self)
        let msgId = try readLE(data, &cursor, as: UInt64.self)
        guard bodyLen > 0 else {
            return RemoteXPCMessage(flags: flags, body: nil, id: msgId)
        }
        guard try readLE(data, &cursor, as: UInt32.self) == objectMagic else {
            throw RemoteXPCError.badMagic
        }
        guard try readLE(data, &cursor, as: UInt32.self) == bodyVersion else {
            throw RemoteXPCError.badVersion
        }
        guard case .dictionary(let dict) = try decodeValue(data, &cursor) else {
            throw RemoteXPCError.bodyNotADictionary
        }
        return RemoteXPCMessage(flags: flags, body: dict, id: msgId)
    }

    private static func decodeValue(_ data: Data, _ cursor: inout Data.Index) throws -> RemoteXPCValue {
        let rawType = try readLE(data, &cursor, as: UInt32.self)
        guard let type = WireType(rawValue: rawType) else {
            throw RemoteXPCError.unknownType(rawType)
        }
        switch type {
        case .null:
            return .null
        case .bool:
            guard data.distance(from: cursor, to: data.endIndex) >= 4 else { throw RemoteXPCError.notEnoughData }
            let byte = data[cursor]
            cursor = data.index(cursor, offsetBy: 4)
            return .bool(byte != 0)
        case .int64:
            return .int64(Int64(bitPattern: try readLE(data, &cursor, as: UInt64.self)))
        case .uint64:
            return .uint64(try readLE(data, &cursor, as: UInt64.self))
        case .double:
            return .double(Double(bitPattern: try readLE(data, &cursor, as: UInt64.self)))
        case .date:
            let nanos = Int64(bitPattern: try readLE(data, &cursor, as: UInt64.self))
            return .date(Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000))
        case .data:
            let length = Int(try readLE(data, &cursor, as: UInt32.self))
            let bytes = try readBytes(data, &cursor, count: length)
            skip(data, &cursor, count: Int(calcPadding(UInt32(length))))
            return .data(bytes)
        case .string:
            let length = Int(try readLE(data, &cursor, as: UInt32.self))
            let bytes = try readBytes(data, &cursor, count: length)
            skip(data, &cursor, count: Int(calcPadding(UInt32(length))))
            let trimmed = bytes.prefix(while: { $0 != 0 })
            return .string(String(decoding: trimmed, as: UTF8.self))
        case .uuid:
            let bytes = try readBytes(data, &cursor, count: 16)
            let uuid = bytes.withUnsafeBytes { raw -> UUID in
                let tuple = raw.loadUnaligned(as: uuid_t.self)
                return UUID(uuid: tuple)
            }
            return .uuid(uuid)
        case .array:
            _ = try readLE(data, &cursor, as: UInt32.self) // payload byte length, unused on decode
            let count = Int(try readLE(data, &cursor, as: UInt32.self))
            var values: [RemoteXPCValue] = []
            // `count` is an unvalidated wire value (up to ~4 billion); clamp the up-front
            // allocation to the remaining buffer size, since every element needs at least one
            // byte to decode -- the loop below still fails fast via a bounds check if `count`
            // doesn't match what's actually there.
            values.reserveCapacity(min(count, data.distance(from: cursor, to: data.endIndex)))
            for _ in 0..<count {
                values.append(try decodeValue(data, &cursor))
            }
            return .array(values)
        case .dictionary:
            _ = try readLE(data, &cursor, as: UInt32.self) // payload byte length, unused on decode
            let count = Int(try readLE(data, &cursor, as: UInt32.self))
            var dict: [String: RemoteXPCValue] = [:]
            for _ in 0..<count {
                let key = try readDictionaryKey(data, &cursor)
                dict[key] = try decodeValue(data, &cursor)
            }
            return .dictionary(dict)
        }
    }

    private static func readDictionaryKey(_ data: Data, _ cursor: inout Data.Index) throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard cursor < data.endIndex else { throw RemoteXPCError.notEnoughData }
            let byte = data[cursor]
            cursor = data.index(after: cursor)
            if byte == 0 { break }
            bytes.append(byte)
        }
        skip(data, &cursor, count: Int(calcPadding(UInt32(bytes.count + 1))))
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Little-endian read/write helpers

private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func readLE<T: FixedWidthInteger>(
    _ data: Data, _ cursor: inout Data.Index, as type: T.Type
) throws -> T {
    let size = MemoryLayout<T>.size
    guard data.distance(from: cursor, to: data.endIndex) >= size else { throw RemoteXPCError.notEnoughData }
    let end = data.index(cursor, offsetBy: size)
    var value: T = 0
    let bytes = data[cursor..<end]
    withUnsafeMutableBytes(of: &value) { dest in
        for (i, byte) in bytes.enumerated() {
            dest[i] = byte
        }
    }
    cursor = end
    return T(littleEndian: value)
}

private func readBytes(_ data: Data, _ cursor: inout Data.Index, count: Int) throws -> Data {
    guard data.distance(from: cursor, to: data.endIndex) >= count else { throw RemoteXPCError.notEnoughData }
    let end = data.index(cursor, offsetBy: count)
    let result = Data(data[cursor..<end])
    cursor = end
    return result
}

private func skip(_ data: Data, _ cursor: inout Data.Index, count: Int) {
    cursor = data.index(cursor, offsetBy: count, limitedBy: data.endIndex) ?? data.endIndex
}
