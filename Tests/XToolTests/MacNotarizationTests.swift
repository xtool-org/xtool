import ArgumentParser
import Dependencies
import Foundation
import Testing
import XUtils
@testable import PackLib
@testable import XToolSupport

struct MacNotarizationTests {
    actor Commands {
        var calls: [[String]] = []
        var interruptSubmit = false
        var wrongLog = false
        var status = "Accepted"
        let id = "12345678-1234-1234-1234-123456789012"
        let release: URL

        init(release: URL) { self.release = release }
        func interrupt() { interruptSubmit = true }
        func mismatch() { wrongLog = true }
        func setStatus(_ value: String) { status = value }

        func run(_ executable: String, _ arguments: [String]) throws -> Data {
            calls.append([executable] + arguments)
            if executable == "/usr/bin/ditto" {
                try Data("archive".utf8).write(to: URL(fileURLWithPath: arguments.last!))
                return Data()
            }
            if arguments.first == "stapler" {
                if arguments[1] == "staple" {
                    try Data("ticket".utf8).write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("ticket"))
                }
                return Data()
            }
            if arguments[1] == "submit", interruptSubmit { throw StringError("Interrupted after upload") }
            if arguments[1] == "log" {
                let hash = try ArtifactInventory.hash(release.appendingPathComponent("upload.zip"))
                return try JSONEncoder().encode(MacNotarizationOperation.NotaryLog(
                    jobId: id, sha256: wrongLog ? String(repeating: "0", count: 64) : hash, status: status
                ))
            }
            return Data("{\"id\":\"\(id)\",\"status\":\"\(status)\"}".utf8)
        }
    }

    func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let app = root.appendingPathComponent("Example.app")
        try MacArtifactTests.fixture(at: app)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let inventory = try ArtifactInventory(directory: app)
        let plan = MacSigningPlan(bundleName: app.lastPathComponent, target: target, mode: .developerID,
                                  identity: String(repeating: "A", count: 40),
                                  inputArtifactSHA256: String(repeating: "b", count: 64), inputInventory: inventory,
                                  targets: [.init(path: "", entitlements: nil)])
        var receipt = try MacSigningReceipt(plan: plan, bundle: app)
        receipt.signatures = [.init(path: "", certificateSHA1: plan.identity, teamIdentifier: "TESTTEAM",
                                    authority: "Developer ID Application: Test", hardenedRuntime: true,
                                    timestamp: "test timestamp")]
        try receipt.write(beside: app)
        return (root, app, root.appendingPathComponent("release"))
    }

    func stub(_ dependencies: inout DependencyValues, _ commands: Commands) {
        dependencies.macHostClient = MacHostClient(isMacOS: { true }, stream: { try await commands.run($0, $1) })
        dependencies.macNotarizationClient = MacNotarizationClient(verifySignature: { _, _ in })
    }

    @Test func completeFlowPreservesUploadAndVerifiesDistribution() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "chosen-profile")
            let original = try ArtifactInventory.hash(release.appendingPathComponent("upload.zip"))
            #expect(try await MacNotarizationOperation.update(directory: release, profile: "chosen-profile") == "Accepted")
            try await MacNotarizationOperation.staple(directory: release)
            try await MacNotarizationOperation.verify(directory: release)
            try await MacNotarizationOperation.staple(directory: release)
            #expect(try ArtifactInventory.hash(release.appendingPathComponent("upload.zip")) == original)
            #expect(try MacNotarizationOperation.load(release).status == "stapled")
            let calls = await commands.calls
            #expect(calls.filter { $0.contains("submit") }.count == 1)
            #expect(calls.filter { $0.contains("staple") }.count == 1)
            #expect(calls.contains { $0.contains("--no-wait") && $0.contains("chosen-profile") })
            try Data("tampered".utf8).write(to: release.appendingPathComponent("distribution/distribution.zip"))
            await #expect(throws: (any Error).self) { try await MacNotarizationOperation.verify(directory: release) }
        }
    }

    @Test func interruptedSubmitNeverResubmitsAndCanRecoverBoundUUID() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        await commands.interrupt()
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            await #expect(throws: (any Error).self) {
                try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            }
            #expect(try MacNotarizationOperation.load(release).status == "submission-started")
            await #expect(throws: (any Error).self) {
                try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            }
            await #expect(throws: (any Error).self) {
                try await MacNotarizationOperation.update(directory: release, profile: "profile")
            }
            #expect(try await MacNotarizationOperation.update(directory: release, profile: "profile", wait: true,
                                                              timeout: 12, recoveryID: commands.id) == "Accepted")
            let calls = await commands.calls
            #expect(calls.filter { $0.contains("submit") }.count == 1)
            #expect(calls.contains { $0.contains("wait") && $0.contains("12s") })
        }
    }

    @Test func wrongAppleArchiveHashCannotAuthorizeStapling() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            await commands.mismatch()
            await #expect(throws: (any Error).self) {
                try await MacNotarizationOperation.update(directory: release, profile: "profile")
            }
            await #expect(throws: (any Error).self) { try await MacNotarizationOperation.staple(directory: release) }
            #expect(try MacNotarizationOperation.load(release).status == "submitted")
        }
    }

    @Test func changedUploadPreventsNetworkRequests() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            let count = await commands.calls.count
            try Data("changed".utf8).write(to: release.appendingPathComponent("upload.zip"))
            await #expect(throws: (any Error).self) {
                try await MacNotarizationOperation.update(directory: release, profile: "profile")
            }
            #expect(await commands.calls.count == count)
        }
    }

    @Test func invalidStatusPersistsWithoutDistribution() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            await commands.setStatus("Invalid")
            #expect(try await MacNotarizationOperation.update(directory: release, profile: "profile") == "Invalid")
            await #expect(throws: (any Error).self) { try await MacNotarizationOperation.staple(directory: release) }
        }
    }

    @Test func outputInsideSourceRejectsBeforeMutationOrTools() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try ArtifactInventory(directory: app)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: {
            for directory in [app, app.appendingPathComponent("release"), alias.appendingPathComponent("release")] {
                await #expect(throws: (any Error).self) {
                    try await MacNotarizationOperation.submit(bundle: app, directory: directory, profile: "profile")
                }
            }
            try before.verify(directory: app)
            #expect(await commands.calls.isEmpty)
        }
    }

    @Test func commandRejectsMissingProfileAndCrossActionFlags() throws {
        #expect(throws: (any Error).self) { try DevNotarizeCommand.parse(["submit", "App.app", "--output", "release"]) }
        #expect(throws: (any Error).self) {
            try DevNotarizeCommand.parse(["verify", "release", "--keychain-profile", "profile"])
        }
        #expect(throws: (any Error).self) {
            try DevNotarizeCommand.parse(["status", "release", "--keychain-profile", "profile", "--submission-id", "id"])
        }
        let parsed = try DevNotarizeCommand.parse(["resume", "release", "--keychain-profile", "profile", "--timeout", "12"])
        #expect(parsed.timeout == 12)
    }

    @Test func promotedDistributionRecoversAfterReceiptWriteInterruption() async throws {
        let (root, app, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(release: release)
        try await withDependencies { stub(&$0, commands) } operation: { () async throws in
            try await MacNotarizationOperation.submit(bundle: app, directory: release, profile: "profile")
            _ = try await MacNotarizationOperation.update(directory: release, profile: "profile")
            try await MacNotarizationOperation.staple(directory: release)
            let final = try MacNotarizationOperation.load(release)
            // Model a crash after the distribution rename but before appending its final event.
            try FileManager.default.removeItem(at: release.appendingPathComponent(
                String(format: "receipt-%06d.json", final.sequence)
            ))
            try await MacNotarizationOperation.staple(directory: release)
            try await MacNotarizationOperation.verify(directory: release)
            #expect(await commands.calls.filter { $0.contains("staple") }.count == 1)
        }
    }

    @Test func advisoryLockExcludesConcurrentOperations() throws {
        let (root, _, release) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: release, withIntermediateDirectories: false)
        let first = try MacNotarizationOperation.acquireLock(release)
        #expect(throws: (any Error).self) { try MacNotarizationOperation.acquireLock(release) }
        MacNotarizationOperation.releaseLock(first)
        let next = try MacNotarizationOperation.acquireLock(release)
        MacNotarizationOperation.releaseLock(next)
    }
}
