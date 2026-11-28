import Testing
import Library

@Test func message() throws { #expect(try libraryMessage().contains("Package fixture")) }
