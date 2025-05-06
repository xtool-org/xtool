import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app"
    )
    
    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The app to launch"
    ) var bundleID: String

    @Argument(
        help: .init(
            "Launch arguments to pass to the app",
            valueName: "arg"
        )
    ) var args: [String] = []

    func run() async throws {
        let client = try await connectionOptions.client()

        let installProxy = try InstallationProxyClient(device: client.device, label: "xtool-inst")
        let executable: URL
        do {
            executable = try installProxy.executable(forBundleID: bundleID)
        } catch {
            throw Console.Error("Could not find an installed app with bundle ID '\(bundleID)'")
        }

        print("Launching \(executable.lastPathComponent)...")

        let debugserver = try DebugserverClient(device: client.device, label: "xtool")
        guard try debugserver.launch(executable: executable, arguments: args) == "OK" else {
            throw Console.Error("Launch failed (!OK)")
        }
        guard try debugserver.send(command: "qLaunchSuccess", arguments: []) == Data("OK".utf8) else {
            throw Console.Error("Launch failed (!qLaunchSuccess)")
        }
        try debugserver.send(command: "D", arguments: [])
    }
}
