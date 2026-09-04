import Testing
import Foundation
@testable import XKit

@Test func testDTXMessageHeaderRoundTrips() throws {
    var message = DTXMessage(
        identifier: 7,
        channelCode: -3,
        conversationIndex: 1,
        expectsReply: true,
        flags: .send,
        payload: .string("_IDE_initiateControlSessionWithProtocolVersion:")
    )
    message.auxiliary.append(.int32(36))

    let encoded = message.encoded()

    // header is always the first 32 bytes, unfragmented
    let header = try DTXMessage.parseHeader(encoded.prefix(DTXMessage.headerLength))
    #expect(header.magic == DTXMessage.headerMagic)
    #expect(header.headerLength == UInt32(DTXMessage.headerLength))
    #expect(header.fragmentId == 0)
    #expect(header.fragmentCount == 1)
    #expect(header.identifier == 7)
    #expect(header.conversationIndex == 1)
    #expect(header.channelCode == -3)
    #expect(header.expectsReply == true)
    #expect(Int(header.payloadLength) == encoded.count - DTXMessage.headerLength)

    let body = encoded.suffix(from: DTXMessage.headerLength)
    let parsed = try DTXMessage.parseBody(header, body: Data(body))
    #expect(parsed.identifier == 7)
    #expect(parsed.channelCode == -3)
    #expect(parsed.conversationIndex == 1)
    #expect(parsed.expectsReply == true)
    guard case .string(let selector)? = parsed.payload else {
        Issue.record("expected a string payload")
        return
    }
    #expect(selector == "_IDE_initiateControlSessionWithProtocolVersion:")
    #expect(parsed.auxiliary.values.count == 1)
    guard case .int32(let value) = parsed.auxiliary.values[0] else {
        Issue.record("expected an int32 auxiliary value")
        return
    }
    #expect(value == 36)
}

@Test func testDTXMessageWithoutPayloadRoundTrips() throws {
    // matches the empty-ack reply pattern used to satisfy expectsReply
    let message = DTXMessage(identifier: 1, channelCode: 0, conversationIndex: 1, flags: .reply)
    let encoded = message.encoded()
    let header = try DTXMessage.parseHeader(encoded.prefix(DTXMessage.headerLength))
    let body = Data(encoded.suffix(from: DTXMessage.headerLength))
    let parsed = try DTXMessage.parseBody(header, body: body)
    #expect(parsed.payload == nil)
    #expect(parsed.auxiliary.values.isEmpty)
}

@Test func testDTXAuxiliaryBufferRoundTripsMixedTypes() throws {
    var aux = DTXAuxiliaryBuffer()
    aux.append(.int32(42))
    aux.append(.int64(-9_000_000_000))
    aux.append(.object(.string("hello")))
    aux.append(.object(.dictionary(["a": .int(1)])))

    let encoded = aux.encoded()
    let parsed = try DTXAuxiliaryBuffer.parse(encoded)
    #expect(parsed.entries.count == 4)

    guard case .int32(let i32) = parsed.entries[0] else { Issue.record("expected int32"); return }
    #expect(i32 == 42)

    guard case .int64(let i64) = parsed.entries[1] else { Issue.record("expected int64"); return }
    #expect(i64 == -9_000_000_000)

    guard case .object(.string(let str)) = parsed.entries[2] else { Issue.record("expected string object"); return }
    #expect(str == "hello")

    guard case .object(.dictionary(let dict)) = parsed.entries[3] else { Issue.record("expected dict object"); return }
    #expect(dict["a"] == .int(1))
}
