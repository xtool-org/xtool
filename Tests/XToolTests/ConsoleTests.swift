import Testing
import XUtils
@testable import XToolSupport

@Test func testPromptReadsLineWhenOutputIsDevNull() async throws {
    let input = try FileDescriptor.pipe()
    defer {
        try? input.readEnd.close()
        try? input.writeEnd.close()
    }
    try input.writeEnd.writeAll("hello\n".utf8)

    let output = try FileDescriptor.open("/dev/null", .writeOnly)
    defer { try? output.close() }

    let reply = try await Console.prompt(
        "Path to Xcode.xip: ",
        input: input.readEnd.rawValue,
        output: output.rawValue
    )
    #expect(reply == "hello")
}

@Test func testPromptReadsLineFromPipes() async throws {
    let input = try FileDescriptor.pipe()
    let output = try FileDescriptor.pipe()
    defer {
        try? input.readEnd.close()
        try? input.writeEnd.close()
        try? output.readEnd.close()
        try? output.writeEnd.close()
    }
    try input.writeEnd.writeAll("hello\n".utf8)

    let reply = try await Console.prompt(
        "prompt: ",
        input: input.readEnd.rawValue,
        output: output.writeEnd.rawValue
    )
    #expect(reply == "hello")
}

@Test func testPromptReturnsPartialLineAtEOF() async throws {
    let input = try FileDescriptor.pipe()
    defer { try? input.readEnd.close() }
    try input.writeEnd.writeAll("hello".utf8)
    try input.writeEnd.close()

    let output = try FileDescriptor.pipe()
    defer {
        try? output.readEnd.close()
        try? output.writeEnd.close()
    }

    let reply = try await Console.prompt(
        "prompt: ",
        input: input.readEnd.rawValue,
        output: output.writeEnd.rawValue
    )
    #expect(reply == "hello")
}

@Test func testPromptReturnsEmptyStringAtEOF() async throws {
    let input = try FileDescriptor.pipe()
    defer { try? input.readEnd.close() }
    try input.writeEnd.close()

    let output = try FileDescriptor.pipe()
    defer {
        try? output.readEnd.close()
        try? output.writeEnd.close()
    }

    let closedPipe = try await Console.prompt(
        "prompt: ",
        input: input.readEnd.rawValue,
        output: output.writeEnd.rawValue
    )
    #expect(closedPipe == "")

    let devNull = try FileDescriptor.open("/dev/null", .readOnly)
    defer { try? devNull.close() }
    let discarded = try await Console.prompt(
        "prompt: ",
        input: devNull.rawValue,
        output: output.writeEnd.rawValue
    )
    #expect(discarded == "")
}

@Test func testPromptReadsLineLongerThanFallbackBuffer() async throws {
    let line = String(repeating: "a", count: 1000)
    let input = try FileDescriptor.pipe()
    defer {
        try? input.readEnd.close()
        try? input.writeEnd.close()
    }
    try input.writeEnd.writeAll((line + "\n").utf8)

    let output = try FileDescriptor.open("/dev/null", .writeOnly)
    defer { try? output.close() }

    let reply = try await Console.prompt(
        "prompt: ",
        input: input.readEnd.rawValue,
        output: output.rawValue
    )
    #expect(reply == line)
}

#if os(Linux)
@Test func testEpollPreflightRejectsDevNullAndAcceptsPipe() throws {
    let devNull = try FileDescriptor.open("/dev/null", .writeOnly)
    defer { try? devNull.close() }
    let pipe = try FileDescriptor.pipe()
    defer {
        try? pipe.readEnd.close()
        try? pipe.writeEnd.close()
    }

    #expect(!Console.isEpollRegisterable(devNull.rawValue))
    #expect(Console.isEpollRegisterable(pipe.readEnd.rawValue))
}
#endif
