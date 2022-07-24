import Foundation
import Supersign
import SwiftyMobileDevice
import ArgumentParser

struct UninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall an installed app"
    )

    @OptionGroup @FromArguments var connection: ConnectionManager.Client

    @Argument(
        help: "The app to uninstall"
    ) var bundleID: String

    func run() throws {
        let installProxy = try InstallationProxyClient(device: connection.device, label: "supersign-inst")
        let sem = DispatchSemaphore(value: 0)
        var error: Error?
        installProxy.uninstall(bundleID: bundleID, progress: { _ in }) { result in
            if case let .failure(err) = result {
                error = err
            }
            sem.signal()
        }
        sem.wait()
        if let error = error {
            print("Failed: \(error)")
        } else {
            print("Success!")
        }
    }
}
