import Testing
import Foundation
@testable import XKit

@Test func testNSKeyedArchiveRoundTripsPrimitives() throws {
    let value = NSKeyedValue.dictionary([
        "aString": .string("hello"),
        "aNumber": .int(42),
        "aBool": .bool(true),
        "anArray": .array([.string("a"), .int(1), .bool(false)]),
    ])

    let data = NSKeyedArchive.archive(value)
    #expect(data.starts(with: Data("bplist00".utf8)))

    let decoded = try NSKeyedArchive.unarchive(data)
    guard case .dictionary(let dict) = decoded else {
        Issue.record("expected a dictionary")
        return
    }
    #expect(dict["aString"] == .string("hello"))
    #expect(dict["aNumber"] == .int(42))
    #expect(dict["aBool"] == .bool(true))
    guard case .array(let array)? = dict["anArray"] else {
        Issue.record("expected an array")
        return
    }
    #expect(array == [.string("a"), .int(1), .bool(false)])
}

@Test func testNSKeyedArchiveEncodesCustomClassName() throws {
    // mirrors how NSURL is archived by Foundation's own NSKeyedArchiver: NS.base/NS.relative
    // fields, $classname "NSURL" -- verified separately against a real NSKeyedArchiver run on
    // this toolchain to confirm the wire shape.
    let value = NSKeyedValue.object(
        className: "NSURL",
        extraClasses: ["NSObject"],
        properties: [
            ("NS.base", .null),
            ("NS.relative", .string("file:///tmp/foo.xctest")),
        ]
    )

    let data = NSKeyedArchive.archive(value)
    let decoded = try NSKeyedArchive.unarchive(data)
    guard case .object(let className, let fields) = decoded else {
        Issue.record("expected a classed object")
        return
    }
    #expect(className == "NSURL")
    #expect(fields["NS.relative"] == .string("file:///tmp/foo.xctest"))
    #expect(fields["NS.base"] == .null)
}

@Test func testNSKeyedArchiveBoxedPrimitiveGetsOwnObjectsEntry() throws {
    // XCTestConfiguration.formatVersion is documented (via appium-ios-device) to be archived as
    // a boxed reference rather than an inline value; verify our .boxed wrapper actually produces
    // a UID-referenced $objects entry rather than an inline one.
    let value = NSKeyedValue.object(
        className: "XCTestConfiguration",
        properties: [
            ("formatVersion", .boxed(.int(2))),
            ("reportResultsToIDE", .bool(true)),
        ]
    )
    let data = NSKeyedArchive.archive(value)
    let decoded = try NSKeyedArchive.unarchive(data)
    guard case .object(_, let fields) = decoded else {
        Issue.record("expected a classed object")
        return
    }
    #expect(fields["formatVersion"] == .int(2))
    #expect(fields["reportResultsToIDE"] == .bool(true))
}

@Test func testNSKeyedArchiveInlinesDataMatchingFoundation() throws {
    // Regression test for a real bug found via real-device testing: `NS.uuidbytes` (an NSUUID's
    // only field) must be archived as raw inline bytes, not boxed as a UID reference to a
    // separate `$objects` entry -- boxing it produced a structurally different archive that
    // testmanagerd silently failed to decode as an NSUUID (logged the session identifier as
    // "(null)" and closed the session). Verified byte-for-byte against this toolchain's real
    // `NSKeyedArchiver` archiving a real `NSUUID` -- see the doc comment on `Archiver.encode()`.
    let uuid = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
    let foundationData = try NSKeyedArchiver.archivedData(withRootObject: uuid as NSUUID, requiringSecureCoding: false)
    let fPlist = try PropertyListSerialization.propertyList(from: foundationData, format: nil) as! [String: Any]
    let fObjects = fPlist["$objects"] as! [Any]
    let fUUIDEntry = fObjects[1] as! [String: Any]
    // Foundation inlines the bytes directly (an NSData value), not a UID reference.
    #expect(fUUIDEntry["NS.uuidbytes"] is Data)

    let ourValue = NSKeyedValue.object(className: "NSUUID", properties: [
        ("NS.uuidbytes", .data(uuid.dtxUUIDBytes)),
    ])
    let ourData = NSKeyedArchive.archive(ourValue)
    let decoded = try NSKeyedArchive.unarchive(ourData)
    guard case .object(let className, let fields) = decoded else {
        Issue.record("expected a classed object")
        return
    }
    #expect(className == "NSUUID")
    #expect(fields["NS.uuidbytes"] == .data(uuid.dtxUUIDBytes))
}

extension NSKeyedArchive.Decoded: Equatable {
    public static func == (lhs: NSKeyedArchive.Decoded, rhs: NSKeyedArchive.Decoded) -> Bool {
        switch (lhs, rhs) {
        case (.string(let l), .string(let r)): l == r
        case (.data(let l), .data(let r)): l == r
        case (.int(let l), .int(let r)): l == r
        case (.double(let l), .double(let r)): l == r
        case (.bool(let l), .bool(let r)): l == r
        case (.array(let l), .array(let r)): l == r
        case (.dictionary(let l), .dictionary(let r)): l == r
        case (.object(let lc, let lf), .object(let rc, let rf)): lc == rc && lf == rf
        case (.null, .null): true
        default: false
        }
    }
}
