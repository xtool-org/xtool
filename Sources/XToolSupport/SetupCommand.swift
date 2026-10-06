import ArgumentParser
import Foundation
import XKit
import PackLib

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Set up xtool for iOS development",
        discussion: """
        Authenticates with Apple if needed, then adds the iOS SDK to SwiftPM.

        Equivalent to running `xtool auth && xtool sdk`
        """
    )

    func run() async throws {
        try await SetupOperation().run()
    }
}

struct SetupOperation {
    var quiet = false

    func run() async throws {
        try await AuthOperation(logoutFromExisting: false, quiet: quiet).run()
        try await EnsureSDKOperation(quiet: quiet).run()
    }
}
