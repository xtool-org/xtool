import ArgumentParser
import Dependencies
import Foundation
import PackLib
import Subprocess
import XUtils

struct MacRunClient: DependencyKey, Sendable {
    var isMacOS: @Sendable () -> Bool
    var launch: @Sendable (URL, [String]) async throws -> Int32

    static let liveValue = Self(
        isMacOS: {
            #if os(macOS)
            true
            #else
            false
            #endif
        },
        launch: { executable, arguments in
            let result = try await Subprocess.run(
                .path(.init(executable.path)), arguments: .init(arguments),
                platformOptions: .withGracefulShutDown,
                output: .currentStandardOutput, error: .currentStandardError
            )
            switch result.terminationStatus {
            case .exited(let code): return code
            case .signaled(let signal): return 128 + signal
            }
        }
    )

    static let testValue = Self(isMacOS: { false }, launch: { _, _ in throw StringError("Unexpected Mac launch") })
}

extension DependencyValues {
    var macRunClient: MacRunClient {
        get { self[MacRunClient.self] }
        set { self[MacRunClient.self] = newValue }
    }
}

enum MacRunOperation {
    static func requireHost() throws {
        @Dependency(\.macRunClient) var client
        guard client.isMacOS() else {
            throw Console.Error("macOS apps must run on a Mac; transfer the app and its handoff files to a Mac first")
        }
    }

    static func run(bundle: URL, arguments: [String]) async throws {
        try requireHost()
        let executable = try MacBundleAudit.executable(in: bundle)
        // Runtime validation is independent of the pre-signing byte inventory: an externally
        // signed app is expected to differ from that inventory, and is never rewritten here.
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil
        ) as? [String: Any]
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let target = try ResolvedTarget.resolve(cliTarget: "\(architecture)-apple-macosx"
            + ((info?["LSMinimumSystemVersion"] as? String) ?? "15.0"))
        try MacBundleAudit.validate(bundle: bundle, target: target)
        print("Launching \(bundle.lastPathComponent)...")
        @Dependency(\.macRunClient) var client
        let status = try await client.launch(executable, arguments)
        if status != 0 { throw ExitCode(status) }
    }
}

struct DevVerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Verify a macOS app and its unchanged deferred-signing handoff"
    )
    @Argument(help: "Path to the .app; its .artifact.json and signing inputs must remain beside it")
    var app: String

    func run() throws {
        try MacArtifact.verify(bundle: URL(fileURLWithPath: app))
        print("Verified artifact and signing inputs: \(app)")
    }
}
