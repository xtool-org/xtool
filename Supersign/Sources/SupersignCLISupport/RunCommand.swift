import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an installed app"
    )

    @OptionGroup @FromArguments var connection: ConnectionManager.Client

    @Argument(
        help: "The app to run"
    ) var bundleID: String

    @Argument(
        help: .init(
            "Launch arguments to pass to the app",
            valueName: "arg"
        )
    ) var args: [String] = []

    func run() throws {
        let installProxy = try InstallationProxyClient(device: connection.device, label: "supersign-inst")
        let executable: URL
        do {
            executable = try installProxy.executable(forBundleID: bundleID)
        } catch {
            throw Console.Error("Could not find an installed app with bundle ID '\(bundleID)'")
        }

        print("Launching \(executable.lastPathComponent)...")

        let debugserver = try DebugserverClient(device: connection.device, label: "supersign")
        guard try debugserver.launch(executable: executable, arguments: args) == "OK" else {
            throw Console.Error("Launch failed (!OK)")
        }
        guard try debugserver.send(command: "qLaunchSuccess", arguments: []) == Data("OK".utf8) else {
            throw Console.Error("Launch failed (!qLaunchSuccess)")
        }
        try debugserver.send(command: "D", arguments: [])
    }
}
