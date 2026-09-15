import Testing
@testable import XToolSupport

@Test func commandParser() throws {
    func sut(_ string: some StringProtocol) throws -> [String] {
        try CommandParser.parse(string)
    }

    #expect(try sut(#""#).isEmpty)
    #expect(try sut(#"foo"#) == ["foo"])
    #expect(try sut(#"foo "#) == ["foo"])
    #expect(try sut(#"foo one two"#) == ["foo", "one", "two"])
    #expect(try sut(#"foo 'one two' three"#) == ["foo", "one two", "three"])
    #expect(try sut(#"foo 'one!two' three"#) == ["foo", "one!two", "three"])
    #expect(try sut(#"foo one\!two three"#) == ["foo", "one!two", "three"])
    #expect(try sut(#"foo one\'two three"#) == ["foo", "one'two", "three"])
    #expect(try sut(#"foo one'two three'four five"#) == ["foo", "onetwo threefour", "five"])

    #expect(throws: CommandParser.Errors.unclosedQuote) {
        try sut(#"foo one two' three"#)
    }
    #expect(throws: CommandParser.Errors.unpairedEscape) {
        try sut(#"foo a b \"#)
    }
}
