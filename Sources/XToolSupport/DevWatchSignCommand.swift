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
        let context = try SigningContext(
            auth: auth.authData(),
            targetDevice: .init(udid: target.udid, name: target.name),
            platform: .watchOS
        )
        let signer = AutoSigner(context: context) { _ in
            print("Signing requires certificate revocation; stopping without revoking certificates.")
            return false
        }
        _ = try await signer.sign(
            app: app,
            status: { print($0) },
            progress: { _ in }
        )
        print("Signed the Watch app. Device installation remains a separate step.")
    }
}
