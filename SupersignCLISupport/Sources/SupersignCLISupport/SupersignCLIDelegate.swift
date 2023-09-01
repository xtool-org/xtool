import Foundation
import Supersign

private func _fetchCode(completion: @escaping (String?) -> Void) {
    completion(Console.prompt("Code: "))
}

final class SupersignCLIAuthDelegate: TwoFactorAuthDelegate {
    func fetchCode(completion: @escaping (String?) -> Void) {
        _fetchCode(completion: completion)
    }
}

final class SupersignCLIDelegate: IntegratedInstallerDelegate, TwoFactorAuthDelegate {
    public enum Error: Swift.Error {
        case compressionFailed
    }

    let preferredTeam: DeveloperServicesTeam.ID?
    let completion: () -> Void
    init(preferredTeam: DeveloperServicesTeam.ID?, completion: @escaping () -> Void) {
        self.preferredTeam = preferredTeam
        self.completion = completion
    }

    func fetchCode(completion: @escaping (String?) -> Void) {
        _fetchCode(completion: completion)
    }

    func fetchTeam(fromTeams teams: [DeveloperServicesTeam], completion: @escaping (DeveloperServicesTeam?) -> Void) {
        if let preferredTeam = preferredTeam {
            // Fails if a team with the requested ID isn't found.
            // This is intentional to avoid interactivity.
            return completion(teams.first(where: { $0.id == preferredTeam }))
        }

        let selected = Console.choose(
            from: teams,
            onNoElement: { fatalError("No development teams available") },
            multiPrompt: "\nSelect a team",
            formatter: {
                "\($0.name) (\($0.id.rawValue))"
            }
        )
        completion(selected)
    }

    func setPresentedMessage(_ message: IntegratedInstaller.Message?) {
        let text: String
        switch message {
        case .pairDevice:
            text = "Please tap 'trust' on your device..."
        case .unlockDevice:
            text = "Please unlock your device..."
        case nil:
            text = "Continuing..."
        }
        print("\n\(text)", terminator: "")
        fflush(stdout)
    }

    var prevStage: String?
    var prevProgress: String?

    func installerDidUpdate(toStage stage: String, progress: Double?) {
        let progString: String?
        if let progress = progress {
            let progInt = Int(progress * 100)
            if progInt < 10 {
                progString = "  \(progInt)%"
            } else if progInt < 100 {
                progString = " \(progInt)%"
            } else {
                progString = "\(progInt)%"
            }
        } else {
            progString = nil
        }

        defer {
            prevStage = stage
            prevProgress = progString
        }

        if stage != prevStage {
            if let progString = progString {
                print("\n[\(stage)] \(progString)", terminator: "")
                fflush(stdout)
            } else {
                print("\n[\(stage)] ...", terminator: "")
                fflush(stdout)
            }
        } else if progString != prevProgress {
            if let progString = progString {
                print("\r[\(stage)] \(progString)", terminator: "")
                fflush(stdout)
            } else {
                print("\r[\(stage)]", terminator: "")
                fflush(stdout)
            }
        }
    }

    func installerDidComplete(withResult result: Result<String, Swift.Error>) {
        print("\n")
        switch result {
        case .success(let bundleID):
            print("Successfully installed!")
            if let file = ProcessInfo.processInfo.environment["SUPERSIGN_METADATA_FILE"] {
                do {
                    try Data("\(bundleID)\n".utf8).write(to: URL(fileURLWithPath: file))
                } catch {
                    print("warning: Failed to write metadata to SUPERSIGN_METADATA_FILE: \(error)")
                }
            }
        case .failure(let error):
            print("Failed :(")
            print("Error: \(error)")
        }
        completion()
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func confirmRevocation(of certificates: [DeveloperServicesCertificate]) async -> Bool {
        print("\nThe following certificates must be revoked:")
        print(
            certificates.map {
                "- \($0.attributes.name) (expires \(Self.expiryFormatter.string(from: $0.attributes.expiry)))"
            }.joined(separator: "\n")
        )
        return await Task.detached { Console.confirm("Continue?") }.value
    }

    // TODO: Use `powershell Compress-Archive` and `powershell Expand-Archive` on Windows

    func decompress(
        ipa: URL,
        in directory: URL,
        progress: @escaping (Double?) -> Void,
        completion: @escaping (_ success: Bool) -> Void
    ) {
        progress(nil)

        let unzip = Process()
        unzip.launchPath = "/usr/bin/unzip"
        unzip.arguments = ["-q", ipa.path, "-d", directory.path]
        unzip.launch()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { return completion(false) }

        completion(true)
    }

    func compress(
        payloadDir: URL,
        progress: @escaping (Double?) -> Void,
        completion: @escaping (Result<URL, Swift.Error>) -> Void
    ) {
        progress(nil)

        let dest = payloadDir.deletingLastPathComponent().appendingPathComponent("app.ipa")

        let zip = Process()
        zip.launchPath = "/usr/bin/zip"
        zip.currentDirectoryPath = payloadDir.deletingLastPathComponent().path
        zip.arguments = ["-yqru0", dest.path, "Payload"]
        zip.launch()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { return completion(.failure(Error.compressionFailed)) }

        completion(.success(dest))
    }
}
