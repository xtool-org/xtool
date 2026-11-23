import ArgumentParser
import Dependencies
import Foundation
import XCLIUtils
import XKit

struct CodesignTool: EmulatedTool {
    @Dependency(\.signer) private var signer

    var name: String { "codesign" }

    func execute(
        commandLine: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) async throws -> EmulatedToolResult {
        do {
            try await execute(commandLine: commandLine, workingDirectory: workingDirectory)
            return .result(status: .exit(0), stdout: Data(), stderr: Data())
        } catch {
            return .result(status: .exit(1), stdout: Data(), stderr: Data("codesign: \(error)\n".utf8))
        }
    }

    private func execute(commandLine: [String], workingDirectory: String?) async throws {
        // Unsupported operations, including `-r- --display`, must fail. SwiftBuild
        // probes runtime dylib signatures before/after signing and restores the old
        // file when the outputs match; successful empty output would undo signing.
        let options = try Options.parse(Array(commandLine.dropFirst()))
        guard options.requirements == nil else {
            throw Console.Error("Code requirement operations (-r/--requirements) are not supported yet")
        }
        guard !options.display, options.force, options.sign == "-", options.timestamp == nil || options.timestamp == "none" else {
            throw Console.Error("""
            Codesign emulator received unsupported arguments:
              \(commandLine.joined(separator: " "))
            Please file a bug report at https://github.com/xtool-org/xtool/issues/new/choose.
            """)
        }
        let preservedMetadata = try options.preservedMetadata()
        let directory = URL(
            fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true,
        )
        let path = URL(fileURLWithPath: options.path, relativeTo: directory).standardizedFileURL
        let entitlements: Data?
        if let entitlementsPath = options.entitlements {
            let data = try Data(contentsOf: URL(fileURLWithPath: entitlementsPath, relativeTo: directory))
            // rcodesign accepts some ill-formed plists; we should validate first
            _ = try PropertyListSerialization.propertyList(from: data, format: nil)
            entitlements = data
        } else if !preservedMetadata.contains(.entitlements) {
            entitlements = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        } else {
            entitlements = nil
        }
        // The signature's XML entitlement slot must contain XML even when the
        // supplied plist is binary. RCodesign handles this conversion and derives
        // matching DER, including when importing an older XML-only signature.
        try await signer.sign(
            app: path,
            identity: .adhoc,
            entitlementMapping: entitlements.map { [path: $0] } ?? [:],
            deep: false,
            progress: { _ in }
        )
    }

    private struct Options: ParsableArguments {
        @Flag var force = false
        @Option var sign: String?
        @Option(name: [.customShort("r", allowingJoined: true), .long]) var requirements: String?
        @Flag(name: [.customShort("d"), .long]) var display = false
        @Option var entitlements: String?
        @Option var preserveMetadata: String?
        @Option var timestamp: String?
        // Ad-hoc signing never looks up a keychain identity.
        @Option var keychain: String?
        @Flag var verbose = false
        @Flag var generateEntitlementDer = false
        // Passed by SwiftBuild when signing codeless binary frameworks (e.g. Firebase/GoogleAppMeasurement).
        @Flag var generatePreEncryptHashes = false
        @Argument var path: String

        enum PreservedMetadata: String {
            case identifier
            case entitlements
            case flags
        }

        func preservedMetadata() throws -> Set<PreservedMetadata> {
            guard let preserveMetadata else { return [] }
            let mapped = try preserveMetadata
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { field in
                    guard let value = PreservedMetadata(rawValue: String(field)) else {
                        throw Console.Error("Unsupported preserved metadata: \(field)")
                    }
                    return value
                }
            return Set(mapped)
        }
    }
}
