import ArgumentParser
import Foundation
import XKit

struct DevWatchSignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign-watch",
        abstract: "Experimentally provision and sign a standalone Watch app"
    )

    @Argument(help: "Watch .app bundle to sign")
    var path: String

    @Option(help: "JSON file containing the target Watch's udid and name")
    var deviceInfo: String

    private struct Target: Decodable {
        var udid: String
        var name: String
    }

    func run() async throws {
        let app = URL(fileURLWithPath: path)
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil
        ) as? [String: Any]
        guard info?["WKApplication"] as? Bool == true,
              info?["CFBundleSupportedPlatforms"] as? [String] == ["WatchOS"] else {
            throw Console.Error("sign-watch requires a single-target watchOS device app.")
        }
        let target = try JSONDecoder().decode(Target.self, from: Data(contentsOf: URL(fileURLWithPath: deviceInfo)))
        guard !target.udid.isEmpty else { throw Console.Error("The Watch UDID is missing.") }
        let auth = try AuthToken.saved()
        // Refuse revocation outright: this command runs ahead of a separate install step, and revoking
        // a free account's certificate breaks apps already installed from it on other devices.
        let installDelegate = XToolInstallerDelegate(allowsRevocation: false)
        let installer = IntegratedInstaller(
            auth: auth.authData(),
            delegate: installDelegate
        )
        do {
            defer { print() }
            try await installer.signInPlace(
                app: app,
                targetDevice: .init(udid: target.udid, name: target.name),
                platform: .watchOS
            )
        } catch let error as CancellationError {
            // A refused revocation surfaces as a cancellation; only a real Ctrl-C may exit as `Cancelled.`
            guard await installDelegate.refusedRevocation else { throw error }
            throw Console.Error("""
            Signing needs a development certificate this machine does not hold, and sign-watch does not \
            revoke the existing one. Run `xtool dev build --sign` in an iOS project to replace it \
            interactively, then retry.
            """)
        }
        print("Signed the Watch app. Device installation remains a separate step.")
    }
}
