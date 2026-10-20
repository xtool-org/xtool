import Foundation
import ArgumentParser
import Dependencies
import XKit
import XUtils

struct SignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign an ipa or app for distribution",
        discussion: """
        Re-signs an existing .ipa or .app with an Apple Distribution identity and an App Store or \
        Ad Hoc provisioning profile, and writes the result as a new .ipa. \
        The input is not modified. This works offline and never contacts Apple.

        The .p12 password is read from the XTOOL_P12_PASSWORD environment variable \
        (or from the file given to --p12-password-file); it is never taken as an argument.
        """
    )

    @OptionGroup var signing: DistributionSigningOptions

    @Option(
        name: .shortAndLong,
        help: "Where to write the signed .ipa (defaults to '<name>-signed.ipa' next to the input)"
    ) var output: String?

    @Argument(help: "The .ipa or .app to sign") var path: String

    func validate() throws {
        guard signing.isEnabled else {
            throw ValidationError("'sign' requires --p12 and at least one --profile.")
        }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "ipa", "app": break
        default: throw ValidationError("The input must be a .ipa or a .app.")
        }
    }

    func run() async throws {
        @Dependency(\.zipCompressor) var compressor

        let input = URL(fileURLWithPath: path)
        let outputURL = output.map { URL(fileURLWithPath: $0) }
            ?? input.deletingLastPathComponent().appendingPathComponent(
                input.deletingPathExtension().lastPathComponent + "-signed.ipa"
            )

        // fail on bad credentials before unpacking anything
        _ = try signing.makeSigner()

        let staging = try TemporaryDirectory(name: "sign")
        let payload = staging.url.appendingPathComponent("Payload")

        switch input.pathExtension.lowercased() {
        case "ipa":
            print("Unpacking...")
            try await compressor.decompress(file: input, in: staging.url, progress: { _ in })
        default:
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: input, to: payload.appendingPathComponent(input.lastPathComponent))
        }

        guard let app = payload.implicitContents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw Console.Error("No .app found in Payload/")
        }

        try await signing.sign(app: app)

        let ipa = try await compressor.compress(directory: payload) { progress in
            if let progress {
                print("\rPackaging... \(Int(progress * 100))%", terminator: "")
            } else {
                print("\rPackaging...", terminator: "")
            }
        }
        print()
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.moveItem(at: ipa, to: outputURL)
        print("Wrote to \(outputURL.path)")
    }
}
