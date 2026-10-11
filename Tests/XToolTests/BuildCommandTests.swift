import Testing
import ArgumentParser
@testable import XToolSupport

@Test func topLevelBuildCommandIsRegistered() throws {
    let command = try XToolCommand.parseAsRoot(["build"])
    #expect(command is BuildCommand || command is DevBuildCommand)
}

@Test func nestedDevBuildCommandIsRegistered() throws {
    let command = try XToolCommand.parseAsRoot(["dev", "build"])
    #expect(command is DevBuildCommand)
}
