//
//  DTXMessage.swift
//  XKit
//
//  DTX is the binary RPC protocol Instruments/testmanagerd speak (`com.apple.instruments.
//  remoteserver[.DVTSecureSocketProxy]`, `com.apple.testmanagerd.lockdown[.secure]`). Nothing in
//  xtool's dependency graph (libimobiledevice, SwiftyMobileDevice, xtool-core) implements it --
//  this is a from-scratch implementation, structured after the documented, working reference in
//  appium-ios-device's `lib/instrument/transformer/headers.js` (Apache-2.0 -- read for wire
//  format, rewritten from scratch in Swift here).
//
//  Wire layout of a single (unfragmented) DTX message:
//
//    DTXMessageHeader (32 bytes, all fields little-endian):
//      u32 magic            0x1F3D5B79
//      u32 headerLength      32 (this struct's own size)
//      u16 fragmentId
//      u16 fragmentCount
//      u32 payloadLength    size of everything after this header
//      u32 identifier       request/response correlation id
//      u32 conversationIndex  0 for a request, incremented for each reply
//      u32 channel           channel this message is addressed to/from (see DTXChannel)
//      u32 expectsReply      nonzero if the recipient must ack with an empty reply
//
//    DTXMessagePayloadHeader (16 bytes):
//      u32 flags
//      u32 auxiliaryLength   size of the auxiliary buffer below, INCLUDING its own 16-byte header
//      u64 totalLength       auxiliaryLength + selectorLength (i.e. everything after this header)
//
//    auxiliary buffer (auxiliaryLength bytes; present even when empty -- just its own header):
//      u64 magic             0x1F0
//      u64 entriesLength     size of the entries below (auxiliaryLength - 16)
//      entries...            each: u32 entryMagic (0xa) + u32 type + type-specific payload
//
//    selector/payload (totalLength - auxiliaryLength bytes):
//      an NSKeyedArchiver-encoded object (see NSKeyedArchive.swift) -- usually a plain NSString
//      selector name for method-invocation messages, but can be any archived object.

import Foundation

enum DTXMessageFlags: UInt32, Sendable {
    case push = 0
    case recv = 1
    case send = 2
    case reply = 3
}

/// A single auxiliary argument passed alongside a selector invocation.
enum DTXAuxiliaryValue: Sendable {
    case int32(Int32)
    case int64(Int64)
    case object(NSKeyedValue)

    fileprivate static let auxiliaryEntryMagic: UInt32 = 0xa

    fileprivate enum WireType: UInt32 {
        case text = 1
        case nsKeyed = 2
        case uint32LE = 3
        case uint64LE = 4
        case int64LE = 6
    }
}

extension DTXAuxiliaryValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int32) { self = .int32(value) }
}

/// The auxiliary argument buffer for a DTX message (see the file-level doc comment for layout).
struct DTXAuxiliaryBuffer: Sendable {
    var values: [DTXAuxiliaryValue] = []

    mutating func append(_ value: DTXAuxiliaryValue) {
        values.append(value)
    }

    /// Full wire bytes, including this buffer's own 16-byte sub-header.
    ///
    /// The sub-header is four little-endian `UInt32` fields -- `bufferSize`, an unused field
    /// (observed always 0), `auxiliarySize` (the actual entries length -- what parsing needs),
    /// and a second unused field (also observed always 0) -- not, as this code assumed until a
    /// real device's `_notifyOfPublishedCapabilities:` reply (which carries a real, several-KB
    /// capabilities plist, unlike the empty/trivial auxiliary buffers every earlier real-device
    /// test happened to exercise) exposed the bug, an 8-byte magic constant followed by an 8-byte
    /// length. There is no magic value to validate at all -- go-ios's `AuxiliaryHeader` struct
    /// (MIT -- read for the wire-format field layout only, not copied; see this file's header
    /// comment) documents `bufferSize` and the two unused fields as safely ignorable on decode.
    /// `bufferSize` is set equal to `auxiliarySize` here since nothing in the reference material
    /// suggests they need to differ for a buffer we're constructing ourselves.
    func encoded() -> Data {
        var entries = Data()
        for value in values {
            switch value {
            case .int32(let int):
                var entry = Data()
                appendLE(&entry, DTXAuxiliaryValue.auxiliaryEntryMagic)
                appendLE(&entry, DTXAuxiliaryValue.WireType.uint32LE.rawValue)
                appendLE(&entry, UInt32(bitPattern: int))
                entries += entry
            case .int64(let int):
                var entry = Data()
                appendLE(&entry, DTXAuxiliaryValue.auxiliaryEntryMagic)
                appendLE(&entry, DTXAuxiliaryValue.WireType.int64LE.rawValue)
                appendLE(&entry, UInt64(bitPattern: int))
                entries += entry
            case .object(let object):
                let archived = NSKeyedArchive.archive(object)
                var entry = Data()
                appendLE(&entry, DTXAuxiliaryValue.auxiliaryEntryMagic)
                appendLE(&entry, DTXAuxiliaryValue.WireType.nsKeyed.rawValue)
                appendLE(&entry, UInt32(archived.count))
                entry += archived
                entries += entry
            }
        }

        var header = Data()
        appendLE(&header, UInt32(entries.count)) // bufferSize
        appendLE(&header, UInt32(0)) // unused
        appendLE(&header, UInt32(entries.count)) // auxiliarySize
        appendLE(&header, UInt32(0)) // unused
        return header + entries
    }

    /// Parses a full auxiliary buffer (including its 16-byte sub-header) back into typed values.
    /// Object entries are decoded via `NSKeyedArchive.unarchive` and exposed as `.object` wrapping
    /// a `Decoded` value.
    struct Parsed {
        /// All entries, in wire order, tagged by kind for callers that care about argument order.
        var entries: [Entry] = []

        enum Entry {
            case int32(Int32)
            case int64(Int64)
            case object(NSKeyedArchive.Decoded)
        }
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= 16 else { return Parsed() }
        var cursor = data.startIndex

        // bufferSize, unused (see `encoded()`'s doc comment for the sub-header layout) -- no
        // magic value to validate here.
        _ = readLE(data, &cursor, as: UInt32.self)
        _ = readLE(data, &cursor, as: UInt32.self)
        let declaredEntriesLength = Int(readLE(data, &cursor, as: UInt32.self)) // auxiliarySize
        _ = readLE(data, &cursor, as: UInt32.self) // unused
        let entriesEnd = min(data.endIndex, cursor + declaredEntriesLength)

        var result = Parsed()
        while cursor < entriesEnd {
            guard data.distance(from: cursor, to: entriesEnd) >= 8 else { break }
            let entryMagic = readLE(data, &cursor, as: UInt32.self)
            guard entryMagic == DTXAuxiliaryValue.auxiliaryEntryMagic else {
                throw DTXError.malformedAuxiliaryBuffer
            }
            let rawType = readLE(data, &cursor, as: UInt32.self)
            guard let type = DTXAuxiliaryValue.WireType(rawValue: rawType) else {
                throw DTXError.unknownAuxiliaryType(rawType)
            }
            switch type {
            case .text:
                let length = Int(readLE(data, &cursor, as: UInt32.self))
                let end = min(entriesEnd, cursor + length)
                let bytes = data[cursor..<end]
                cursor = end
                if let string = String(data: bytes, encoding: .utf8) {
                    result.entries.append(.object(.string(string)))
                }
            case .nsKeyed:
                let length = Int(readLE(data, &cursor, as: UInt32.self))
                let end = min(entriesEnd, cursor + length)
                let archived = Data(data[cursor..<end])
                cursor = end
                let decoded = try NSKeyedArchive.unarchive(archived)
                result.entries.append(.object(decoded))
            case .uint32LE:
                let value = Int32(bitPattern: readLE(data, &cursor, as: UInt32.self))
                result.entries.append(.int32(value))
            case .uint64LE:
                let value = Int64(bitPattern: readLE(data, &cursor, as: UInt64.self))
                result.entries.append(.int64(value))
            case .int64LE:
                let value = Int64(bitPattern: readLE(data, &cursor, as: UInt64.self))
                result.entries.append(.int64(value))
            }
        }
        return result
    }
}

enum DTXError: Swift.Error {
    case notEnoughData
    case badMagic
    case malformedAuxiliaryBuffer
    case unknownAuxiliaryType(UInt32)
    case fragmentChannelMismatch
}

/// A single (reassembled) DTX message.
struct DTXMessage: Sendable {
    static let headerMagic: UInt32 = 0x1F3D5B79
    static let headerLength = 32
    static let payloadHeaderLength = 16

    var identifier: UInt32
    var channelCode: Int32
    var conversationIndex: UInt32
    var expectsReply: Bool
    var flags: DTXMessageFlags

    var auxiliary = DTXAuxiliaryBuffer()
    /// The selector name (for a method-invocation message) or arbitrary archived payload (for a
    /// reply). `nil` for an empty ack.
    var payload: NSKeyedValue?

    init(
        identifier: UInt32,
        channelCode: Int32,
        conversationIndex: UInt32 = 0,
        expectsReply: Bool = false,
        flags: DTXMessageFlags = .send,
        payload: NSKeyedValue? = nil
    ) {
        self.identifier = identifier
        self.channelCode = channelCode
        self.conversationIndex = conversationIndex
        self.expectsReply = expectsReply
        self.flags = flags
        self.payload = payload
    }

    /// Serializes to the wire format. Always emits a single fragment (fragmentId 0, fragmentCount
    /// 1) -- xtool never needs to send messages large enough to require fragmentation in
    /// practice (the largest payloads it sends, XCTestConfiguration archives, are a few KB).
    func encoded() -> Data {
        let selectorBytes = payload.map(NSKeyedArchive.archive) ?? Data()
        let auxBytes = auxiliary.encoded()

        var payloadHeader = Data()
        appendLE(&payloadHeader, flags.rawValue)
        appendLE(&payloadHeader, UInt32(auxBytes.count))
        appendLE(&payloadHeader, UInt64(auxBytes.count + selectorBytes.count))

        var header = Data()
        appendLE(&header, Self.headerMagic)
        appendLE(&header, UInt32(Self.headerLength))
        appendLE(&header, UInt16(0)) // fragmentId
        appendLE(&header, UInt16(1)) // fragmentCount
        appendLE(&header, UInt32(Self.payloadHeaderLength + auxBytes.count + selectorBytes.count))
        appendLE(&header, identifier)
        appendLE(&header, conversationIndex)
        appendLE(&header, UInt32(bitPattern: channelCode))
        appendLE(&header, expectsReply ? UInt32(1) : UInt32(0))

        return header + payloadHeader + auxBytes + selectorBytes
    }

    struct ParsedHeader {
        var magic: UInt32
        var headerLength: UInt32
        var fragmentId: UInt16
        var fragmentCount: UInt16
        var payloadLength: UInt32
        var identifier: UInt32
        var conversationIndex: UInt32
        var channelCode: Int32
        var expectsReply: Bool
    }

    static func parseHeader(_ data: Data) throws -> ParsedHeader {
        guard data.count >= headerLength else { throw DTXError.notEnoughData }
        var cursor = data.startIndex
        let magic = readLE(data, &cursor, as: UInt32.self)
        guard magic == headerMagic else { throw DTXError.badMagic }
        let headerLen = readLE(data, &cursor, as: UInt32.self)
        let fragmentId = readLE(data, &cursor, as: UInt16.self)
        let fragmentCount = readLE(data, &cursor, as: UInt16.self)
        let payloadLength = readLE(data, &cursor, as: UInt32.self)
        let identifier = readLE(data, &cursor, as: UInt32.self)
        let conversationIndex = readLE(data, &cursor, as: UInt32.self)
        let channelCode = Int32(bitPattern: readLE(data, &cursor, as: UInt32.self))
        let expectsReply = readLE(data, &cursor, as: UInt32.self) != 0
        return ParsedHeader(
            magic: magic,
            headerLength: headerLen,
            fragmentId: fragmentId,
            fragmentCount: fragmentCount,
            payloadLength: payloadLength,
            identifier: identifier,
            conversationIndex: conversationIndex,
            channelCode: channelCode,
            expectsReply: expectsReply
        )
    }

    /// Parses a reassembled message body (everything after the 32-byte `DTXMessageHeader`,
    /// concatenated across all fragments) into a `DTXMessage`.
    static func parseBody(_ header: ParsedHeader, body: Data) throws -> DTXMessage {
        var message = DTXMessage(
            identifier: header.identifier,
            channelCode: header.channelCode,
            conversationIndex: header.conversationIndex,
            expectsReply: header.expectsReply
        )
        guard !body.isEmpty else { return message }
        guard body.count >= payloadHeaderLength else { throw DTXError.notEnoughData }

        var cursor = body.startIndex
        let flagsRaw = readLE(body, &cursor, as: UInt32.self)
        message.flags = DTXMessageFlags(rawValue: flagsRaw) ?? .send
        let auxLength = Int(readLE(body, &cursor, as: UInt32.self))
        let totalLength = Int(readLE(body, &cursor, as: UInt64.self))

        guard auxLength >= 0, totalLength >= auxLength else { throw DTXError.notEnoughData }

        let auxEnd = min(body.endIndex, cursor + auxLength)
        if auxLength > 0 {
            message.auxiliary = try dtxAuxiliaryBuffer(from: body[cursor..<auxEnd])
        }
        cursor = auxEnd

        let selectorLength = totalLength - auxLength
        if selectorLength > 0 {
            let selectorEnd = min(body.endIndex, cursor + selectorLength)
            let selectorData = Data(body[cursor..<selectorEnd])
            let decoded = try NSKeyedArchive.unarchive(selectorData)
            message.payload = decoded.asNSKeyedValue
        }

        return message
    }
}

private func dtxAuxiliaryBuffer(from data: Data) throws -> DTXAuxiliaryBuffer {
    let parsed = try DTXAuxiliaryBuffer.parse(Data(data))
    var buffer = DTXAuxiliaryBuffer()
    for entry in parsed.entries {
        switch entry {
        case .int32(let value):
            buffer.append(.int32(value))
        case .int64(let value):
            buffer.append(.int64(value))
        case .object(let decoded):
            if let value = decoded.asNSKeyedValue {
                buffer.append(.object(value))
            }
        }
    }
    return buffer
}

extension NSKeyedArchive.Decoded {
    /// Round-trips a decoded value back into an (encodable) `NSKeyedValue`, for the common case
    /// of relaying/re-encoding a plain value. Loses fidelity for `.object` (custom Objective-C
    /// classes) since those aren't generally re-encodable without knowing their exact class
    /// shape; callers that need to re-send a decoded custom object should construct a fresh
    /// `NSKeyedValue.object` themselves.
    var asNSKeyedValue: NSKeyedValue? {
        switch self {
        case .string(let value): .string(value)
        case .data(let value): .data(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .bool(let value): .bool(value)
        case .array(let value): .array(value.compactMap(\.asNSKeyedValue))
        case .dictionary(let value): .dictionary(value.compactMapValues(\.asNSKeyedValue))
        case .object: nil
        case .null: .null
        }
    }
}

// MARK: - Little-endian read/write helpers

private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
}

private func readLE<T: FixedWidthInteger>(_ data: Data, _ cursor: inout Data.Index, as type: T.Type) -> T {
    let size = MemoryLayout<T>.size
    let end = min(data.endIndex, cursor + size)
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
