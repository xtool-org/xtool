import ArgumentParser
import Foundation
import PackLib
import XUtils

struct DevNotarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notarize", abstract: "Submit, resume, and verify a Developer ID signed macOS app",
        discussion: "Submit creates a new private release directory. Other actions use that directory. "
            + "Credentials must already exist in an explicitly selected notarytool keychain profile. "
            + "No signing or credential provisioning is performed."
    )

    enum Action: String, ExpressibleByArgument, CaseIterable { case submit, status, resume, log, staple, verify }

    @Argument(help: "submit, status, resume, log, staple, or verify")
    var action: Action
    @Argument(help: "Signed .app for submit; release directory for other actions")
    var path: String
    @Option(help: "New release directory (submit only)")
    var output: String?
    @Option(help: "Explicit existing notarytool keychain profile for network actions")
    var keychainProfile: String?
    @Option(help: "Bounded wait in seconds (resume only)")
    var timeout: Int = 60
    @Option(help: "Recover unknown submission using a completed Apple log matching the archive (resume only)")
    var submissionID: String?

    func validate() throws {
        guard (action == .submit) == (output != nil) else {
            throw ValidationError("--output is required for submit and unavailable for other actions")
        }
        guard timeout > 0, action == .resume || (timeout == 60 && submissionID == nil) else {
            throw ValidationError("--timeout and --submission-id are supported only by resume")
        }
        if action == .staple || action == .verify {
            guard keychainProfile == nil else { throw ValidationError("This action does not use keychain credentials") }
        } else {
            _ = try MacNotarizationOperation.authentication(keychainProfile)
        }
    }

    func run() async throws {
        let url = URL(fileURLWithPath: path)
        switch action {
        case .submit:
            guard let output else { throw StringError("Missing --output") }
            try await MacNotarizationOperation.submit(bundle: url, directory: URL(fileURLWithPath: output),
                                                      profile: keychainProfile)
            print("Submission recorded in \(output); use status or resume with that directory")
        case .status, .resume:
            let status = try await MacNotarizationOperation.update(directory: url, profile: keychainProfile,
                                                                   wait: action == .resume, timeout: timeout,
                                                                   recoveryID: submissionID)
            print("Notarization status: \(status)")
            if status == "Invalid" || status == "Rejected" { throw ExitCode.failure }
        case .log:
            let data = try await MacNotarizationOperation.log(directory: url, profile: keychainProfile)
            print(String(decoding: data, as: UTF8.self))
        case .staple:
            try await MacNotarizationOperation.staple(directory: url)
            print("Stapled and sealed distribution in \(path)/distribution")
        case .verify:
            try await MacNotarizationOperation.verify(directory: url)
            print("Verified archive, signatures, and stapled ticket in \(path)")
        }
    }
}
