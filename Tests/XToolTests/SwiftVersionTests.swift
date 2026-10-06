import Testing
@testable import PackLib

@Test(arguments: [
    ("6.2", SwiftVersion(6, 2)),
    ("6.2.0", SwiftVersion(6, 2)),
    ("6.2.1", SwiftVersion(6, 2, 1)),
    ("Swift version 6.2 (swift-6.2-RELEASE)\nTarget: aarch64-unknown-linux-gnu", SwiftVersion(6, 2)),
    ("Swift version 6.2.1 (swift-6.2.1-RELEASE)", SwiftVersion(6, 2, 1)),
    ("Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)", SwiftVersion(6, 2)),
    ("Apple Swift version 6.2.1 (swiftlang-6.2.1.4.3 clang-1700.3.19.1)", SwiftVersion(6, 2, 1)),
    ("Swift version 6.4-dev (LLVM abcdef, Swift abcdef)", SwiftVersion(6, 4)),
    ("Apple Swift version 6.4.1-dev (LLVM abcdef, Swift abcdef)", SwiftVersion(6, 4, 1)),
    ("Swift version 6.2 effective-5.10 (swift-6.2-RELEASE)", SwiftVersion(6, 2)),
    ("Swift version 6.2", SwiftVersion(6, 2)),
    ("Apple Swift version 6.2.1", SwiftVersion(6, 2, 1)),
    ("Swift version 6.4-dev", SwiftVersion(6, 4)),
    ("Apple Swift version 6.4.1-dev", SwiftVersion(6, 4, 1)),
    ("Swift version 6.4-dev\n", SwiftVersion(6, 4)),
    ("Swift version 6.4-dev\nTarget: aarch64-unknown-linux-gnu", SwiftVersion(6, 4)),
])
func testSwiftVersionParsing(string: String, expected: SwiftVersion) {
    #expect(SwiftVersion(string) == expected)
}

@Test(arguments: [
    "",
    "6",
    "6.2.1.4",
    "swift version 6.2 (swift-6.2-RELEASE)",
    "Swift version ",
    "Swift version 6 (swift-6-RELEASE)",
    "Swift version 6.2.1.4 (swift-6.2.1.4-RELEASE)",
    "Swift version six.2 (swift-6.2-RELEASE)",
    "Swift version 6.two (swift-6.2-RELEASE)",
    "Swift version 6.2.one (swift-6.2.1-RELEASE)",
    "Swift version 6.2-beta (swift-6.2-RELEASE)",
    "Swift version 99999999999999999999.2 (swift-6.2-RELEASE)",
])
func testSwiftVersionParsingInvalidInput(string: String) {
    #expect(SwiftVersion(string) == nil)
}

@Test(arguments: [
    (SwiftVersion(0, 0), "0.0.0"),
    (SwiftVersion(6, 2), "6.2.0"),
    (SwiftVersion(6, 2, 1), "6.2.1"),
    (SwiftVersion(10, 20, 30), "10.20.30"),
])
func testSwiftVersionStringConversion(version: SwiftVersion, expected: String) {
    #expect(version.description == expected)
    #expect(String(version) == expected)
    #expect(SwiftVersion(version.description) == version)
}

@Test(arguments: [
    (SwiftVersion(5, 99, 99), SwiftVersion(6, 0, 0)),
    (SwiftVersion(6, 2, 99), SwiftVersion(6, 3, 0)),
    (SwiftVersion(6, 2, 0), SwiftVersion(6, 2, 1)),
    (SwiftVersion(9, 0, 0), SwiftVersion(10, 0, 0)),
    (SwiftVersion(6, 9, 0), SwiftVersion(6, 10, 0)),
    (SwiftVersion(6, 2, 9), SwiftVersion(6, 2, 10)),
])
func testSwiftVersionOrdering(lower: SwiftVersion, higher: SwiftVersion) {
    #expect(lower < higher)
    #expect(higher > lower)
    #expect(lower <= higher)
    #expect(higher >= lower)
    #expect(!(higher < lower))
    #expect(!(lower > higher))
    #expect(lower != higher)
}

@Test(arguments: [
    (SwiftVersion(6, 2), SwiftVersion(6, 2, 0)),
    (SwiftVersion(6, 2, 1), SwiftVersion(6, 2, 1)),
])
func testSwiftVersionComparisonEquality(lhs: SwiftVersion, rhs: SwiftVersion) {
    #expect(lhs == rhs)
    #expect(!(lhs < rhs))
    #expect(!(rhs < lhs))
    #expect(!(lhs > rhs))
    #expect(!(rhs > lhs))
    #expect(lhs <= rhs)
    #expect(lhs >= rhs)
}
