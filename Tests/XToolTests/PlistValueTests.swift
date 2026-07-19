import Testing
import Foundation
import plist
@testable import XKit

@Test func testPlistValueRoundTripsThroughPlistT() {
    let value = PlistValue.dictionary([
        "aString": .string("hello"),
        "aData": .data(Data([0x01, 0x02, 0x03])),
        "aUInt": .uint(42),
        "aBoolTrue": .bool(true),
        "aBoolFalse": .bool(false),
        "aUID": .uid(7),
        "anArray": .array([.string("a"), .string("b"), .uint(3)]),
        "nested": .dictionary(["inner": .string("value")]),
    ])

    let node = value.toPlistT()
    defer { plist_free(node) }

    let roundTripped = PlistValue(plistT: node)
    #expect(roundTripped == value)
}

@Test func testPlistValueRoundTripsThroughBinaryData() {
    let value = PlistValue.dictionary([
        "aString": .string("hello"),
        "aData": .data(Data([0x01, 0x02, 0x03])),
    ])

    let binary = value.toBinaryData()
    #expect(binary.starts(with: Data("bplist00".utf8)))

    let roundTripped = PlistValue.parse(binary: binary)
    #expect(roundTripped == value)
}

@Test func testPlistValueParsesXMLPropertyList() throws {
    let dict: [String: Any] = ["ApBoardID": "0x8", "ApChipID": "0x8110", "Trusted": true]
    let xml = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)

    let parsed = PlistValue.parse(xml: xml)
    guard case .dictionary(let result) = parsed else {
        Issue.record("Expected a dictionary")
        return
    }

    #expect(result["ApBoardID"] == .string("0x8"))
    #expect(result["ApChipID"] == .string("0x8110"))
    #expect(result["Trusted"] == .bool(true))
}

extension PlistValue: Equatable {
    public static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case (.dictionary(let l), .dictionary(let r)): l == r
        case (.array(let l), .array(let r)): l == r
        case (.string(let l), .string(let r)): l == r
        case (.data(let l), .data(let r)): l == r
        case (.uint(let l), .uint(let r)): l == r
        case (.real(let l), .real(let r)): l == r
        case (.bool(let l), .bool(let r)): l == r
        case (.uid(let l), .uid(let r)): l == r
        default: false
        }
    }
}
