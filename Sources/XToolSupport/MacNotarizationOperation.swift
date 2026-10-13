import Dependencies
import Foundation
import PackLib
import Subprocess
import XUtils

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct MacNotarizationClient: DependencyKey, Sendable {
    var isMacOS: @Sendable () -> Bool
    var run: @Sendable (String, [String]) async throws -> Data
    var verifySignature: @Sendable (URL, MacSigningReceipt) async throws -> Void

    static let liveValue = Self(
        isMacOS: {
            #if os(macOS)
            true
            #else
            false
            #endif
        },
        run: { executable, arguments in
            let result = try await Subprocess.run(
                .path(.init(executable)), arguments: .init(arguments),
                output: .string(limit: .max), error: .currentStandardError
            ).checkSuccess()
            return Data(result.standardOutput.utf8)
        },
        verifySignature: { _ = try await MacSigningOperation.verify(bundle: $0, receipt: $1, verifyInventory: false) }
    )
    static let testValue = Self(
        isMacOS: { false },
        run: { _, _ in throw StringError("Unexpected notarization command") },
        verifySignature: { _, _ in throw StringError("Unexpected signing verification") }
    )
}

extension DependencyValues {
    var macNotarizationClient: MacNotarizationClient {
        get { self[MacNotarizationClient.self] }
        set { self[MacNotarizationClient.self] = newValue }
    }
}

/// Append-only local evidence, not a cryptographic attestation. Upload bytes are never rewritten.
struct MacNotarizationReceipt: Codable, Sendable {
    var version = 1
    var sequence = 0
    var bundleName: String
    var signingReceiptSHA256: String
    var uploadSHA256: String
    var submissionID: String?
    var status: String
    var logSHA256: String?
    var distributionSHA256: String?
    var distributionInventory: ArtifactInventory?
}

enum MacNotarizationOperation {
    static func requireHost() throws {
        @Dependency(\.macNotarizationClient) var client
        guard client.isMacOS() else { throw StringError("Notarization requires a Mac") }
    }

    static func authentication(_ profile: String?) throws -> [String] {
        guard let profile, !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StringError("Network notarization commands require an explicit --keychain-profile")
        }
        return ["--keychain-profile", profile]
    }

    static func submit(bundle: URL, directory: URL, profile: String?) async throws {
        try requireHost()
        let auth = try authentication(profile)
        let source = bundle.resolvingSymlinksInPath().standardizedFileURL
        let output = directory.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(directory.lastPathComponent).standardizedFileURL
        guard output.path != source.path, !output.path.hasPrefix(source.path + "/") else {
            throw StringError("Release directory must be outside the input app")
        }
        let receipt = try MacSigningReceipt.verify(bundle: bundle)
        guard receipt.mode == .developerID else { throw StringError("Notarization requires Developer ID signing") }
        @Dependency(\.macNotarizationClient) var client
        try await client.verifySignature(bundle, receipt)
        // Creation is exclusive. An existing output, including an interrupted attempt, is never resubmitted.
        guard mkdir(directory.path, 0o700) == 0 else {
            throw StringError("Release directory must be new; existing attempts are never resubmitted")
        }
        let lock = try acquireLock(directory)
        defer { releaseLock(lock) }
        let snapshot = directory.appendingPathComponent("signed", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        let app = snapshot.appendingPathComponent(bundle.lastPathComponent)
        try FileManager.default.copyItem(at: bundle, to: app)
        try FileManager.default.copyItem(at: MacSigningReceipt.receiptURL(for: bundle),
                                         to: MacSigningReceipt.receiptURL(for: app))
        let copied = try MacSigningReceipt.verify(bundle: app)
        try await client.verifySignature(app, copied)
        let upload = directory.appendingPathComponent("upload.zip")
        _ = try await client.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--sequesterRsrc", app.path, upload.path])
        var state = MacNotarizationReceipt(
            bundleName: app.lastPathComponent,
            signingReceiptSHA256: try ArtifactInventory.hash(MacSigningReceipt.receiptURL(for: app)),
            uploadSHA256: try ArtifactInventory.hash(upload), status: "submission-started"
        )
        try append(&state, directory: directory)
        let response = try await client.run("/usr/bin/xcrun", ["notarytool", "submit", upload.path,
                                                              "--no-wait", "--output-format", "json"] + auth)
        let value = try JSONDecoder().decode(Submission.self, from: response)
        guard UUID(uuidString: value.id) != nil else { throw StringError("Invalid notarization submission UUID") }
        state.submissionID = value.id
        state.status = "submitted"
        try response.write(to: directory.appendingPathComponent("submission.json"), options: .atomic)
        try append(&state, directory: directory)
    }

    static func update(directory: URL, profile: String?, wait: Bool = false, timeout: Int = 60,
                       recoveryID: String? = nil) async throws -> String {
        try requireHost()
        let auth = try authentication(profile)
        guard timeout > 0 else { throw StringError("Timeout must be positive") }
        let lock = try acquireLock(directory)
        defer { releaseLock(lock) }
        var state = try load(directory)
        try validateInputs(state, directory: directory)
        if let recoveryID {
            guard state.submissionID == nil, UUID(uuidString: recoveryID) != nil else {
                throw StringError("Recovery requires an ambiguous submission and a valid explicit submission UUID")
            }
            // A completed Apple log must establish exact archive binding before adopting the supplied UUID.
            _ = try await fetchLog(state, id: recoveryID, directory: directory, authentication: auth)
            state.submissionID = recoveryID
            state.status = "recovered"
            try append(&state, directory: directory)
        }
        guard let id = state.submissionID else {
            throw StringError("Submission outcome is unknown; use --submission-id with a completed matching Apple log. "
                + "Do not resubmit.")
        }
        @Dependency(\.macNotarizationClient) var client
        var arguments = ["notarytool", wait ? "wait" : "info", id, "--output-format", "json"] + auth
        if wait { arguments += ["--timeout", "\(timeout)s"] }
        let response = try await client.run("/usr/bin/xcrun", arguments)
        let value = try JSONDecoder().decode(Submission.self, from: response)
        guard value.id.lowercased() == id.lowercased(), let status = value.status,
              ["Accepted", "Invalid", "In Progress", "Rejected"].contains(status) else {
            throw StringError("Unexpected notarization response identity or status")
        }
        // Once stapled, observations cannot discard the distribution evidence.
        if state.status == "stapled" { return state.status }
        state.status = status
        if status == "Accepted" || status == "Invalid" || status == "Rejected" {
            let log = try await fetchLog(state, id: id, directory: directory, authentication: auth)
            guard log.status == status else { throw StringError("Notarization status and log disagree") }
            state.logSHA256 = try ArtifactInventory.hash(logURL(directory))
        }
        try append(&state, directory: directory)
        return state.status
    }

    static func log(directory: URL, profile: String?) async throws -> Data {
        try requireHost()
        let auth = try authentication(profile)
        let lock = try acquireLock(directory)
        defer { releaseLock(lock) }
        let state = try load(directory)
        try validateInputs(state, directory: directory)
        guard let id = state.submissionID else { throw StringError("Submission UUID is unknown") }
        _ = try await fetchLog(state, id: id, directory: directory, authentication: auth)
        return try Data(contentsOf: logURL(directory))
    }

    static func staple(directory: URL) async throws {
        try requireHost()
        let lock = try acquireLock(directory)
        defer { releaseLock(lock) }
        var state = try load(directory)
        try validateInputs(state, directory: directory)
        if state.status == "stapled" { try await verifyDistribution(state, directory: directory); return }
        guard state.status == "Accepted" else {
            throw StringError("Stapling requires an accepted archive-bound notarization log")
        }
        try verifyAcceptedLog(state, directory: directory)
        let destination = directory.appendingPathComponent("distribution")
        if FileManager.default.fileExists(atPath: destination.path) {
            var recovered = try JSONDecoder().decode(MacNotarizationReceipt.self,
                                                     from: Data(contentsOf: destination.appendingPathComponent("receipt.json")))
            guard recovered.bundleName == state.bundleName,
                  recovered.signingReceiptSHA256 == state.signingReceiptSHA256,
                  recovered.uploadSHA256 == state.uploadSHA256, recovered.submissionID == state.submissionID,
                  recovered.logSHA256 == state.logSHA256 else {
                throw StringError("Existing distribution is not bound to this submission")
            }
            try await verifyDistribution(recovered, directory: directory)
            recovered.sequence = state.sequence
            try append(&recovered, directory: directory)
            return
        }
        let work = directory.appendingPathComponent("staple-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let source = signedApp(state, directory: directory)
        let app = work.appendingPathComponent(state.bundleName)
        try FileManager.default.copyItem(at: source, to: app)
        @Dependency(\.macNotarizationClient) var client
        let signing = try MacSigningReceipt.verify(bundle: source)
        try await client.verifySignature(app, signing)
        _ = try await client.run("/usr/bin/xcrun", ["stapler", "staple", app.path])
        _ = try await client.run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        try await client.verifySignature(app, signing)
        let zip = work.appendingPathComponent("distribution.zip")
        _ = try await client.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--sequesterRsrc", app.path, zip.path])
        state.distributionInventory = try ArtifactInventory(directory: app)
        state.distributionSHA256 = try ArtifactInventory.hash(zip)
        state.status = "stapled"
        // Publish recoverable evidence together with the app; a crash before the event append is resumable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: work.appendingPathComponent("receipt.json"), options: .atomic)
        try FileManager.default.moveItem(at: work, to: destination)
        try append(&state, directory: directory)
    }

    static func verify(directory: URL) async throws {
        try requireHost()
        let lock = try acquireLock(directory)
        defer { releaseLock(lock) }
        let state = try load(directory)
        try validateInputs(state, directory: directory)
        try await verifyDistribution(state, directory: directory)
    }

    private static func verifyDistribution(_ state: MacNotarizationReceipt, directory: URL) async throws {
        guard state.status == "stapled", let inventory = state.distributionInventory,
              let expected = state.distributionSHA256 else {
            throw StringError("No verified stapled distribution receipt")
        }
        try verifyAcceptedLog(state, directory: directory)
        let distribution = directory.appendingPathComponent("distribution")
        let app = distribution.appendingPathComponent(state.bundleName)
        try inventory.verify(directory: app)
        guard try ArtifactInventory.hash(distribution.appendingPathComponent("distribution.zip")) == expected else {
            throw StringError("Distribution archive changed")
        }
        let signing = try MacSigningReceipt.verify(bundle: signedApp(state, directory: directory))
        @Dependency(\.macNotarizationClient) var client
        try await client.verifySignature(app, signing)
        _ = try await client.run("/usr/bin/xcrun", ["stapler", "validate", app.path])
    }

    /// The stored log must still match its recorded hash, bind this archive, and be accepted.
    private static func verifyAcceptedLog(_ state: MacNotarizationReceipt, directory: URL) throws {
        guard let logHash = state.logSHA256, try ArtifactInventory.hash(logURL(directory)) == logHash else {
            throw StringError("Stored notarization log is missing or changed")
        }
        let log = try JSONDecoder().decode(NotaryLog.self, from: Data(contentsOf: logURL(directory)))
        try validateLog(log, state: state, id: state.submissionID ?? "")
        guard log.status == "Accepted" else { throw StringError("Notarization log is not accepted") }
    }

    private static func logURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("notary-log.json")
    }

    private static func signedApp(_ state: MacNotarizationReceipt, directory: URL) -> URL {
        directory.appendingPathComponent("signed").appendingPathComponent(state.bundleName)
    }

    struct Submission: Decodable { var id: String; var status: String? }
    struct NotaryLog: Codable { var jobId: String; var sha256: String; var status: String }

    private static func fetchLog(_ state: MacNotarizationReceipt, id: String, directory: URL,
                                 authentication: [String]) async throws -> NotaryLog {
        @Dependency(\.macNotarizationClient) var client
        let data = try await client.run("/usr/bin/xcrun", ["notarytool", "log", id] + authentication)
        let log = try JSONDecoder().decode(NotaryLog.self, from: data)
        try validateLog(log, state: state, id: id)
        let destination = logURL(directory)
        if let previous = state.logSHA256 {
            guard try ArtifactInventory.hash(destination) == previous else { throw StringError("Stored notary log changed") }
            let existing = try JSONDecoder().decode(NotaryLog.self, from: Data(contentsOf: destination))
            guard existing.jobId == log.jobId, existing.sha256 == log.sha256, existing.status == log.status else {
                throw StringError("Notarization log changed")
            }
        } else {
            try data.write(to: destination, options: .atomic)
        }
        return log
    }

    static func validateLog(_ log: NotaryLog, state: MacNotarizationReceipt, id: String) throws {
        guard log.jobId.lowercased() == id.lowercased(), log.sha256.lowercased() == state.uploadSHA256,
              ["Accepted", "Invalid", "Rejected"].contains(log.status) else {
            throw StringError("Apple notarization log does not bind this submission and exact archive")
        }
    }

    static func validateInputs(_ state: MacNotarizationReceipt, directory: URL) throws {
        guard state.version == 1, state.bundleName.hasSuffix(".app"),
              state.bundleName == URL(fileURLWithPath: state.bundleName).lastPathComponent,
              !state.bundleName.contains("/"), !state.bundleName.contains("\\") else {
            throw StringError("Invalid notarization receipt")
        }
        let app = signedApp(state, directory: directory)
        guard try ArtifactInventory.hash(MacSigningReceipt.receiptURL(for: app)) == state.signingReceiptSHA256,
              try ArtifactInventory.hash(directory.appendingPathComponent("upload.zip")) == state.uploadSHA256 else {
            throw StringError("Signed receipt or submitted archive changed")
        }
        let signed = try MacSigningReceipt.verify(bundle: app)
        guard signed.mode == .developerID else { throw StringError("Notarization requires Developer ID signing") }
    }

    static func acquireLock(_ directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent("operation.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StringError("Cannot open notarization lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw StringError("Another notarization operation is running")
        }
        // Never unlink this inode. The kernel releases the lock even when the process crashes.
        return descriptor
    }

    static func releaseLock(_ descriptor: Int32) {
        // Explicit unlock also releases copies inherited during a concurrent fork before exec.
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func append(_ state: inout MacNotarizationReceipt, directory: URL) throws {
        state.sequence += 1
        let url = directory.appendingPathComponent(String(format: "receipt-%06d.json", state.sequence))
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StringError("Receipt event already exists") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func load(_ directory: URL) throws -> MacNotarizationReceipt {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("receipt-") && $0.hasSuffix(".json") }.sorted()
        guard let last = names.last else { throw StringError("No notarization receipt; do not retry an ambiguous submission") }
        let state = try JSONDecoder().decode(MacNotarizationReceipt.self,
                                             from: Data(contentsOf: directory.appendingPathComponent(last)))
        guard state.version == 1, state.sequence == names.count,
              names.enumerated().allSatisfy({ $0.element == String(format: "receipt-%06d.json", $0.offset + 1) }) else {
            throw StringError("Invalid notarization receipt event sequence")
        }
        return state
    }
}
