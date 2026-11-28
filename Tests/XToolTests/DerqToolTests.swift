import CustomDump
import Foundation
import Testing
@testable import XToolSupport

struct DerqToolTests {
    @Test func matchesAppleDEREncoding() throws {
        // Captured from `derq query -f xml -i <plist> -o <der> --raw`.
        // In particular, NSNumber must not turn integer 0/1 into BOOLEANs.
        let fixtures: [(Any, String)] = [
            (false, "7011020101b00c300a0c0576616c7565010100"),
            (true, "7011020101b00c300a0c0576616c75650101ff"),
            (0, "7011020101b00c300a0c0576616c7565020100"),
            (1, "7011020101b00c300a0c0576616c7565020101"),
            (-1, "7011020101b00c300a0c0576616c75650201ff"),
            (127, "7011020101b00c300a0c0576616c756502017f"),
            (128, "7012020101b00d300b0c0576616c756502020080"),
            (256, "7012020101b00d300b0c0576616c756502020100"),
            (-129, "7012020101b00d300b0c0576616c75650202ff7f"),
            (Int64.min, "7018020101b01330110c0576616c756502088000000000000000"),
            (Int64.max, "7018020101b01330110c0576616c756502087fffffffffffffff"),
        ]
        for (value, expected) in fixtures {
            for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: format, options: 0)
                expectNoDifference(try hexEncoded(plist), expected)
            }
        }
    }

    @Test func encodesEmptyAndNestedDictionaries() throws {
        let empty = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        expectNoDifference(try hexEncoded(empty), "7005020101b000")
        let nested: [String: Any] = ["z": [], "a": ["flag": true], "message": "<&>\t\n🍎"]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let plist = try PropertyListSerialization.data(fromPropertyList: nested, format: format, options: 0)
            expectNoDifference(try hexEncoded(plist),
                               "7034020101b02f30100c0161b00b30090c04666c61670101ff"
                               + "30140c076d6573736167650c093c263e090af09f8d8e30050c017a3000")
        }
    }

    @Test func rejectsUnsupportedValues() throws {
        for value: Any in [Data([1, 2]), Date(timeIntervalSince1970: 0), 1.5, UInt64.max] {
            let plist = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .xml, options: 0)
            #expect(throws: (any Error).self) { try DerqEncoder().encodeEntitlements(plist) }
        }
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .xml, options: 0)
        #expect(throws: (any Error).self) { try DerqEncoder().encodeEntitlements(array) }
        #expect(throws: (any Error).self) { try DerqEncoder().encodeEntitlements(Data("invalid plist".utf8)) }
    }

    private func hexEncoded(_ plist: Data) throws -> String {
        try DerqEncoder().encodeEntitlements(plist).map { String(format: "%02x", $0) }.joined()
    }
}
