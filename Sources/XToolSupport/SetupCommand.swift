import ArgumentParser
import Foundation
import XKit

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

        #if os(macOS)
        if !quiet {
            print("Skipping Darwin SDK setup since we're on macOS.")
        }
        #else
        switch try await DarwinSDK.current()?.isUpToDate() {
        case true?:
            if !quiet {
                print("Darwin SDK is up to date.")
            }
        case false?:
            if !quiet {
                print("Darwin SDK is outdated.")
            }
            fallthrough
        case nil:
            let path = try await Console.prompt("""
            Now generating the Darwin SDK.
            
            Please download Xcode from http://developer.apple.com/download/all/?q=Xcode
            and enter the path to the downloaded Xcode.xip.
            
            Path to Xcode.xip: 
            """)

            let expanded = (path as NSString).expandingTildeInPath

            try await InstallSDKOperation(path: expanded).run()
        }
        #endif
    }
}
