import Foundation
import XKit
import XUtils
import XCLIUtils
import ArgumentParser

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload an ipa file to App Store Connect (TestFlight)",
        discussion: """
        This uses the App Store Connect API, so you need to be logged in with an API key \
        (`xtool auth login --mode key`). The app must already exist in App Store Connect.
        """
    )

    @Argument(
        help: "The path to the ipa to upload",
        completion: .file(extensions: ["ipa"])
    ) var path: String

    @Option(
        name: .long,
        help: "The App Store Connect ID of the app. By default it's looked up from the ipa's bundle ID."
    ) var appID: String?

    @Flag(
        help: "Wait for App Store Connect to finish processing the build, and report any problem it finds."
    ) var wait = false

    @Flag(
        help: "Only check the ipa locally and print what's wrong with it. Doesn't need to be logged in."
    ) var check = false

    @Flag(
        help: "Check the ipa and look up the app, but don't upload anything."
    ) var dryRun = false

    @Flag(
        help: "Upload even if the local checks found errors."
    ) var skipCheck = false

    func run() async throws {
        let ipa = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: ipa.path) else {
            throw Console.Error("\(path) does not exist.")
        }

        let report = try await IPAInspector().inspect(ipa: ipa)
        for finding in report.findings {
            d.out.print(finding)
        }
        if check {
            guard report.errors.isEmpty else { throw ExitCode.failure }
            d.out.print("No errors found.")
            return
        }
        if !report.errors.isEmpty && !skipCheck {
            throw Console.Error(
                "The ipa has problems that App Store Connect is likely to reject. "
                    + "Fix them, or pass --skip-check to upload anyway."
            )
        }
        guard let info = report.info else {
            throw Console.Error("Could not read the bundle ID and version from the ipa.")
        }

        guard case .appStoreConnect(let key) = try AuthToken.saved().authData() else {
            throw Console.Error(
                "This command requires an App Store Connect API key. Log in with `xtool auth login --mode key`."
            )
        }
        let uploader = BuildUploader(key: key)
        let appID: String
        if let explicit = self.appID {
            appID = explicit
        } else {
            appID = try await uploader.resolveApp(bundleID: info.bundleID)
        }

        d.out.print("\(info.bundleID) \(info.version) (\(info.build)), \(info.platform), app \(appID)")
        if dryRun {
            d.out.print("Dry run: nothing was uploaded.")
            return
        }

        let result = try await uploader.upload(
            ipa: ipa, info: info, appID: appID, wait: wait, onEvent: Self.printEvent
        )
        for message in result.warnings {
            d.out.print("warning: \(message)")
        }
        for message in result.infos {
            d.out.print("note: \(message)")
        }
        if wait {
            d.out.print("Build \(info.build) was accepted by App Store Connect.")
        } else {
            d.out.print("Uploaded. App Store Connect is processing the build (state: \(result.state)). Use --wait to follow it.")
        }
    }

    private static func printEvent(_ event: BuildUploader.Event) {
        switch event {
        case .createdUpload(let id):
            d.out.print("Created upload \(id)")
        case .reservedFile(let parts):
            d.out.print("Uploading \(parts) part\(parts == 1 ? "" : "s")...")
        case .uploadedPart(let completed, let total):
            d.out.print("Uploaded part \(completed)/\(total)")
        case .committedFile:
            d.out.print("Upload finished.")
        case .processing(let state):
            d.out.print("Processing: \(state)")
        }
    }
}
