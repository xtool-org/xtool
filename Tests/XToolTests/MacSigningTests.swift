import ArgumentParser
import ConcurrencyExtras
import Dependencies
import Foundation
import Testing
@testable import PackLib
@testable import XToolSupport

struct MacSigningTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func handoff(_ root: URL, entitlements: [String: Any] = [:]) throws -> URL {
        let bundle = root.appendingPathComponent("App.app")
        try MacArtifactTests.fixture(at: bundle)
        let input = root.appendingPathComponent("input.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0).write(to: input)
        let target = try ResolvedTarget.resolve(cliTarget: "arm64-apple-macosx15.0")
        let app = Plan.Product(target: target, type: .application, product: "App", bundleID: "test.App",
                               infoPlist: [:], resources: [], entitlementsPath: input.path)
        let manifest = try DeferredSigningHandoff.write(plan: Plan(target: target, app: app), bundle: bundle, sourceDirectory: root)
        try MacArtifact.write(bundle: bundle, signingManifest: manifest)
        return bundle
    }

    @Test func requiresUnambiguousIdentityAndRejectsRestrictedEntitlements() throws {
        #expect(throws: (any Error).self) { try MacSigningPlan.validateIdentity(mode: .development, identity: nil) }
        #expect(throws: (any Error).self) {
            try MacSigningPlan.validateIdentity(mode: .developerID, identity: "Developer ID Application: Someone")
        }
        #expect(throws: (any Error).self) { try MacSigningPlan.validateIdentity(mode: .adHoc, identity: "-") }
        try MacSigningPlan.validateIdentity(mode: .development, identity: String(repeating: "a", count: 40))
        let restricted = ["com.apple.developer.icloud-services": ["CloudDocuments"]]
        let rejected = try root()
        defer { try? FileManager.default.removeItem(at: rejected) }
        #expect(throws: (any Error).self) { try handoff(rejected, entitlements: restricted) }
        // The signer still rejects restricted entitlements in a handoff edited after the build.
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory, entitlements: ["com.apple.security.app-sandbox": true])
        let manifestURL = MacArtifact.signingManifestURL(for: app)
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: manifestURL))
        let input = directory.appendingPathComponent(try #require(manifest.products.first?.entitlementsPath))
        try PropertyListSerialization.data(fromPropertyList: restricted, format: .xml, options: 0).write(to: input)
        try MacArtifact.write(bundle: app, signingManifest: manifestURL)
        #expect(throws: (any Error).self) { try MacSigningPlan.make(bundle: app, mode: .adHoc, identity: nil) }
    }

    @Test func dryRunDoesNotCallToolsOrCreateOutput() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory)
        let before = try ArtifactInventory(directory: directory)
        try await MacSigningOperation.run(bundle: app, output: directory.appendingPathComponent("signed"),
                                          mode: .adHoc, identity: nil, dryRun: true)
        try before.verify(directory: directory)
    }

    @Test func signsCopyAndReceiptDetectsLaterMutation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory, entitlements: ["com.apple.security.app-sandbox": true])
        let original = try ArtifactInventory(directory: app)
        let output = directory.appendingPathComponent("signed")
        let captured = LockIsolated<Data?>(nil)
        let calls = LockIsolated<[[String]]>([])
        try await withDependencies {
            $0.macHostClient = MacHostClient(isMacOS: { true }, capture: { _, arguments in
                calls.withValue { $0.append(arguments) }
                if arguments.contains("--sign") {
                    let input = try #require(arguments.firstIndex(of: "--entitlements"))
                    let entitlementData = try Data(contentsOf: URL(fileURLWithPath: arguments[input + 1]))
                    captured.setValue(entitlementData)
                    let target = URL(fileURLWithPath: try #require(arguments.last))
                    #expect(target.path != app.path)
                    try Data("signature".utf8).write(to: target.appendingPathComponent("Contents/mock-signature"))
                }
                if arguments.contains("--entitlements"), !arguments.contains("--sign") {
                    return MacToolOutput(output: captured.value ?? Data(), error: Data())
                }
                return MacToolOutput(output: Data(), error: Data("Signature=adhoc\n".utf8))
            })
        } operation: {
            try await MacSigningOperation.run(bundle: app, output: output, mode: .adHoc, identity: nil, dryRun: false)
        }
        try original.verify(directory: app)
        try MacArtifact.verify(bundle: app)
        let signed = output.appendingPathComponent("App.app")
        let receipt = try MacSigningReceipt.verify(bundle: signed)
        #expect(receipt.mode == .adHoc)
        #expect(receipt.signatures.count == 1)
        #expect(receipt.inputArtifactSHA256 == (try ArtifactInventory.hash(MacArtifact.manifestURL(for: app))))
        #expect(!calls.value.contains { $0.contains("--deep") })
        try Data("tampered".utf8).write(to: signed.appendingPathComponent("Contents/mock-signature"))
        #expect(throws: (any Error).self) { try MacSigningReceipt.verify(bundle: signed) }
    }

    @Test func signingFailureLeavesNoOutputOrStagingAndPreservesSource() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory)
        let before = try ArtifactInventory(directory: directory)
        let output = directory.appendingPathComponent("signed")
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.macHostClient = MacHostClient(isMacOS: { true }, capture: { _, _ in
                    throw CocoaError(.fileWriteUnknown)
                })
            } operation: {
                try await MacSigningOperation.run(bundle: app, output: output, mode: .adHoc, identity: nil, dryRun: false)
            }
        }
        try before.verify(directory: directory)
    }

    @Test func existingOutputAndWrongEffectiveEntitlementsFailClosed() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory, entitlements: ["com.apple.security.app-sandbox": true])
        await #expect(throws: (any Error).self) {
            try await MacSigningOperation.run(bundle: app, output: directory, mode: .adHoc, identity: nil, dryRun: true)
        }
        let output = directory.appendingPathComponent("signed")
        await #expect(throws: (any Error).self) {
            try await withDependencies {
                $0.macHostClient = MacHostClient(isMacOS: { true }, capture: { _, _ in
                    MacToolOutput(output: Data(), error: Data("Signature=adhoc\n".utf8))
                })
            } operation: {
                try await MacSigningOperation.run(bundle: app, output: output, mode: .adHoc, identity: nil, dryRun: false)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try MacArtifact.verify(bundle: app)
    }

    @Test func outputThroughSymlinkIntoSourceIsRejected() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        await #expect(throws: (any Error).self) {
            try await MacSigningOperation.run(bundle: app, output: alias.appendingPathComponent("signed"),
                                              mode: .adHoc, identity: nil, dryRun: true)
        }
        try MacArtifact.verify(bundle: app)
    }

    @Test func entitlementInputsAreFrozenAndExtraCodeHasNoInheritedEntitlements() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory, entitlements: ["com.apple.security.app-sandbox": true])
        let extra = app.appendingPathComponent("Contents/MacOS/extra")
        try MacArtifactTests.binary().write(to: extra)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extra.path)
        try MacArtifact.write(bundle: app, signingManifest: directory.appendingPathComponent("App.signing.json"))
        let plan = try MacSigningPlan.make(bundle: app, mode: .adHoc, identity: nil)
        #expect(plan.targets.map(\.path) == ["Contents/MacOS/extra", ""])
        #expect(plan.targets.first?.entitlements == nil)
        let entitlements = try #require(plan.targets.last?.entitlements)
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("App.signing.json")))
        let input = try #require(manifest.products.first?.entitlementsPath)
        try Data("changed".utf8).write(to: directory.appendingPathComponent(input))
        #expect(plan.targets.last?.entitlements == entitlements)
        #expect(throws: (any Error).self) { try MacSigningPlan.make(bundle: app, mode: .adHoc, identity: nil) }
    }

    @Test(arguments: ["success", "certificate", "runtime", "timestamp", "category"])
    func certificateEvidenceMustMatchPolicy(failure: String) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try handoff(directory)
        let certificate = Data("mock certificate from native codesign extraction".utf8)
        let identity = failure == "certificate" ? String(repeating: "A", count: 40)
            : MacSigningPlan.certificateFingerprint(certificate)
        let output = directory.appendingPathComponent("signed")
        let metadata = "Authority=\(failure == "category" ? "Apple Development:" : "Developer ID Application:") Example\n"
            + "TeamIdentifier=TEAM12345\n"
            + (failure == "runtime" ? "" : "CodeDirectory v=20500 flags=0x10000(runtime)\n")
            + (failure == "timestamp" ? "" : "Timestamp=Oct 13, 2026 at 12:00:00\n")
        let calls = LockIsolated<[[String]]>([])
        let client = MacHostClient(isMacOS: { true }, capture: { _, arguments in
            calls.withValue { $0.append(arguments) }
            if let index = arguments.firstIndex(of: "--extract-certificates") {
                try certificate.write(to: URL(fileURLWithPath: arguments[index + 1] + "0"))
            }
            return MacToolOutput(output: Data(), error: Data(metadata.utf8))
        })
        if failure == "success" {
            try await withDependencies { $0.macHostClient = client } operation: {
                try await MacSigningOperation.run(bundle: app, output: output, mode: .developerID,
                                                  identity: identity, dryRun: false)
            }
            let receipt = try MacSigningReceipt.verify(bundle: output.appendingPathComponent("App.app"))
            #expect(receipt.signatures.first?.certificateSHA1 == identity)
            #expect(receipt.signatures.first?.teamIdentifier == "TEAM12345")
            #expect(receipt.signatures.first?.hardenedRuntime == true)
            let signing = try #require(calls.value.first { $0.contains("--sign") })
            #expect(signing.contains("--timestamp"))
            #expect(signing.contains("runtime"))
        } else {
            await #expect(throws: (any Error).self) {
                try await withDependencies { $0.macHostClient = client } operation: {
                    try await MacSigningOperation.run(bundle: app, output: output, mode: .developerID,
                                                      identity: identity, dryRun: false)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        try MacArtifact.verify(bundle: app)
    }

    #if os(macOS)
    @Test func nativeAdHocSigningPreservesSourceAndRejectsTampering() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("App.app")
        try MacArtifactTests.nativeFixture(at: app)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let target = try ResolvedTarget.resolve(cliTarget: "\(architecture)-apple-macosx15.0")
        let product = Plan.Product(target: target, type: .application, product: "App", bundleID: "test.App",
                                   infoPlist: [:], resources: [])
        let manifest = try DeferredSigningHandoff.write(plan: Plan(target: target, app: product),
                                                        bundle: app, sourceDirectory: directory)
        try MacArtifact.write(bundle: app, signingManifest: manifest)
        let before = try ArtifactInventory(directory: app)
        let output = directory.appendingPathComponent("signed")
        try await withDependencies {
            $0.macHostClient = .liveValue
        } operation: {
            let arguments = [app.path, "--output", output.path, "--mode", "ad-hoc"]
            try await MacSignCommand.parse(arguments + ["--dry-run"]).run()
            #expect(!FileManager.default.fileExists(atPath: output.path))
            try await MacSignCommand.parse(arguments).run()
            let signed = output.appendingPathComponent("App.app")
            try await DevVerifyCommand.parse([signed.path, "--signed"]).run()
            await #expect(throws: ExitCode(7)) {
                try await DevRunCommand.parse(["--app", signed.path, "--", "first", "two words"]).run()
            }
            await #expect(throws: (any Error).self) { try await MacSignCommand.parse(arguments).run() }
            try Data("tampered".utf8).write(to: signed.appendingPathComponent("Contents/unexpected.txt"))
            await #expect(throws: (any Error).self) {
                try await DevVerifyCommand.parse([signed.path, "--signed"]).run()
            }
        }
        try before.verify(directory: app)
        try MacArtifact.verify(bundle: app)
    }
    #endif
}
