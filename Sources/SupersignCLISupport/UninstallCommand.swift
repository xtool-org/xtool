import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall an installed app"
    )

    @OptionGroup @FromArguments var connection: ConnectionManager.Client

    @Argument(
        help: "The app to uninstall"
    ) var bundleID: String

    func run() async throws {
        let installProxy = try InstallationProxyClient(device: connection.device, label: "supersign-inst")
        do {
            try await installProxy.uninstall(
                bundleID: bundleID,
                progress: { _ in }
            )
        } catch {
            print("Failed: \(error)")
            return
        }
        print("Success!")
    }
}
