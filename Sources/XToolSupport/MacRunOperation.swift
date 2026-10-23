import ArgumentParser
import Dependencies
import Foundation
import PackLib
import XUtils

enum MacRunOperation {
    static func requireHost() throws {
        @Dependency(\.macHostClient) var client
        guard client.isMacOS() else {
            throw Console.Error("macOS apps must run on a Mac; transfer the app and its handoff files to a Mac first")
        }
    }

    static func run(bundle: URL, arguments: [String]) async throws {
        try requireHost()
        let executable = try MacBundleAudit.executable(in: bundle)
        // Runtime validation is independent of the pre-signing byte inventory: an externally
        // signed app is expected to differ from that inventory, and is never rewritten here.
        #if arch(arm64)
        let host = "arm64"
        #else
        let host = "x86_64"
        #endif
        let target = try MacBundleAudit.runTarget(bundle: bundle, hostArchitecture: host)
        try MacBundleAudit.validate(bundle: bundle, target: target)
        print("Launching \(bundle.lastPathComponent)...")
        @Dependency(\.macHostClient) var client
        let status = try await client.launch(executable, arguments)
        if status != 0 { throw ExitCode(status) }
    }
}

struct DevVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Verify a macOS build handoff or signed artifact"
    )
    @Argument(help: "Path to the .app; its .artifact.json and signing inputs must remain beside it")
    var app: String

    @Flag(help: "Verify the adjacent signing receipt and native signatures instead of the pre-signing handoff")
    var signed = false

    func run() async throws {
        let bundle = URL(fileURLWithPath: app)
        if signed {
            let receipt = try MacSigningReceipt.verify(bundle: bundle)
            // The receipt check already verified the inventory.
            _ = try await MacSigningOperation.verify(bundle: bundle, receipt: receipt, verifyInventory: false)
            print("Verified signed artifact and signatures: \(app)")
        } else {
            try MacArtifact.verify(bundle: bundle)
            print("Verified artifact and signing inputs: \(app)")
        }
    }
}
