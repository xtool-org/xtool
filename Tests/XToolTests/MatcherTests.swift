import Testing
@testable import XToolSupport

extension SDKEntry {
    fileprivate static let test = E("Root", [
        E("Intermediate", [
            E("Leaf"),
        ]),
        E("AnotherLeaf"),
        E("BeforeWildcard", [
            E(nil, [
                E("AfterWildcard"),
            ]),
        ]),
    ])
}

@Test func testMatcherSupportsSlices() {
    let s = SDKEntry.test

    let slice0 = ["Root"].map { $0[...] }[0...]
    #expect(s.matches(slice0))

    let slice1 = ["foo", "bar", "Root"].map { $0[...] }[2...]
    #expect(s.matches(slice1))

    let slice2 = ["foo", "bar", "NotRoot"].map { $0[...] }[2...]
    #expect(!s.matches(slice2))
}

@Test func testMatcherLeaves() {
    let s = SDKEntry.test

    #expect(s.matches(["Root", "Intermediate"]))
    #expect(!s.matches(["Root", "NotIntermediate"]))

    #expect(s.matches(["Root", "Intermediate", "Leaf"]))
    #expect(!s.matches(["Root", "Intermediate", "NotLeaf"]))
    #expect(s.matches(["Root", "Intermediate", "Leaf", "AfterLeaf"]))

    #expect(s.matches(["Root", "AnotherLeaf"]))
    #expect(s.matches(["Root", "AnotherLeaf", "AfterAnotherLeaf"]))

    #expect(!s.matches(["Junk", "Root"]))

    #expect(s.matches(["Root", "BeforeWildcard"]))
    #expect(s.matches(["Root", "BeforeWildcard", "Blah"]))
    #expect(s.matches(["Root", "BeforeWildcard", "Blah", "AfterWildcard"]))
    #expect(s.matches(["Root", "BeforeWildcard", "Blah", "AfterWildcard", "Suffix"]))
    #expect(!s.matches(["Root", "BeforeWildcard", "Blah", "NotAfterWildcard"]))
    #expect(!s.matches(["Root", "BeforeWildcard", "Blah", "NotAfterWildcard", "Suffix"]))
}
