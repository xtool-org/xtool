import Testing
import Foundation
@testable import XKit

/// Reference bytes for `Message{Flags: AlwaysSetFlag, Body: map[string]interface{}{}}` captured
/// from go-ios's `ios/xpc/xpc_empty_dict.bin` test fixture (MIT) -- a real, wire-captured
/// RemoteXPC message, not just self-consistency between this file's encode/decode. Matches the
/// byte-for-byte Foundation-comparison convention used in `NSKeyedArchiveTests.swift`.
private let emptyDictFixture: [UInt8] = [
    0x92, 0x0b, 0xb0, 0x29, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x42, 0x37, 0x13, 0x42, 0x05, 0x00, 0x00, 0x00,
    0x00, 0xf0, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]

@Test func testRemoteXPCDecodesRealEmptyDictFixture() throws {
    let decoded = try RemoteXPCCodec.decode(Data(emptyDictFixture))
    #expect(decoded.flags == RemoteXPCFlag.alwaysSet)
    #expect(decoded.body == [:])
}

@Test func testRemoteXPCEncodesMatchingRealEmptyDictFixture() throws {
    let message = RemoteXPCMessage(flags: RemoteXPCFlag.alwaysSet, body: [:], id: 0)
    let encoded = RemoteXPCCodec.encode(message)
    #expect(Array(encoded) == emptyDictFixture)
}

@Test func testRemoteXPCEmptyWrapperRoundTrips() throws {
    let message = RemoteXPCMessage(flags: RemoteXPCFlag.initHandshake | RemoteXPCFlag.alwaysSet, body: nil, id: 0)
    let encoded = RemoteXPCCodec.encode(message)
    #expect(encoded.count == 24) // magic(4) + flags(4) + bodyLen(8) + msgId(8), no body bytes

    let decoded = try RemoteXPCCodec.decode(encoded)
    #expect(decoded.flags == message.flags)
    #expect(decoded.body == nil)
}

@Test func testRemoteXPCDictionaryRoundTripsAllValueTypes() throws {
    let uuid = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let body: [String: RemoteXPCValue] = [
        "aString": .string("hello world"),
        "aBool": .bool(true),
        "anInt": .int64(-42),
        "aUInt": .uint64(42),
        "aDouble": .double(3.5),
        "aData": .data(Data([0x01, 0x02, 0x03])),
        "aUUID": .uuid(uuid),
        "aDate": .date(date),
        "aNull": .null,
        "anArray": .array([.int64(1), .string("two"), .bool(false)]),
        "aDict": .dictionary(["nested": .string("value")]),
    ]
    let message = RemoteXPCMessage(flags: RemoteXPCFlag.alwaysSet | RemoteXPCFlag.data, body: body, id: 7)

    let encoded = RemoteXPCCodec.encode(message)
    let decoded = try RemoteXPCCodec.decode(encoded)

    #expect(decoded.flags == message.flags)
    #expect(decoded.id == 7)
    guard let decodedBody = decoded.body else {
        Issue.record("expected a body")
        return
    }
    #expect(decodedBody["aString"] == .string("hello world"))
    #expect(decodedBody["aBool"] == .bool(true))
    #expect(decodedBody["anInt"] == .int64(-42))
    #expect(decodedBody["aUInt"] == .uint64(42))
    #expect(decodedBody["aDouble"] == .double(3.5))
    #expect(decodedBody["aData"] == .data(Data([0x01, 0x02, 0x03])))
    #expect(decodedBody["aUUID"] == .uuid(uuid))
    if case .date(let decodedDate)? = decodedBody["aDate"] {
        #expect(abs(decodedDate.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001)
    } else {
        Issue.record("expected a date")
    }
    #expect(decodedBody["aNull"] == .null)
    #expect(decodedBody["anArray"] == .array([.int64(1), .string("two"), .bool(false)]))
    #expect(decodedBody["aDict"] == .dictionary(["nested": .string("value")]))
}
