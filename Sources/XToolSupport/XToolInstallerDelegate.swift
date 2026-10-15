import Foundation
import XKit
import ConcurrencyExtras

final class XToolAuthDelegate: TwoFactorAuthDelegate {
    func fetchCode() async -> String? {
        try? await Console.prompt("Code: ")
    }
}

actor XToolInstallerDelegate: IntegratedInstallerDelegate {
    private let allowsRevocation: Bool

    /// Set once signing asked to revoke certificates and this delegate declined without prompting.
    private(set) var refusedRevocation = false

    /// Pass `allowsRevocation: false` to refuse certificate revocation outright instead of prompting for it.
    init(allowsRevocation: Bool = true) {
        self.allowsRevocation = allowsRevocation
    }

    private let updateTask = LockIsolated<Task<Void, Never>?>(nil)

    nonisolated func setPresentedMessage(_ message: IntegratedInstaller.Message?) {
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
        fflush(stdoutSafe)
    }

    var prevStage: String?
    var prevProgress: String?

    private func _installerDidUpdate(toStage stage: String, progress: Double?) {
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
                fflush(stdoutSafe)
            } else {
                print("\n[\(stage)] ...", terminator: "")
                fflush(stdoutSafe)
            }
        } else if progString != prevProgress {
            if let progString = progString {
                print("\r[\(stage)] \(progString)", terminator: "")
                fflush(stdoutSafe)
            } else {
                print("\r[\(stage)]", terminator: "")
                fflush(stdoutSafe)
            }
        }
    }

    nonisolated func installerDidUpdate(toStage stage: String, progress: Double?) {
        updateTask.withValue { task in
            task = Task { [prev = task] in
                await prev?.value
                await _installerDidUpdate(toStage: stage, progress: progress)
            }
        }
    }

    func confirmRevocation(of certificates: [DeveloperServicesCertificate]) async -> Bool {
        print("\nThe following certificates must be revoked:")
        print(
            certificates.map {
                "- \($0.attributes!.name!) (expires \($0.attributes!.expirationDate!.formatted(date: .abbreviated, time: .shortened)))"
            }.joined(separator: "\n")
        )
        guard allowsRevocation else {
            print("Stopping without revoking them.")
            refusedRevocation = true
            return false
        }
        do {
            return try await Console.confirm("Continue?")
        } catch {
            return false
        }
    }
}
