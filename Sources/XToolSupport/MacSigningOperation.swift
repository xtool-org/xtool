import Dependencies
import Foundation
import PackLib
import XUtils

enum MacSigningOperation {
    static func run(bundle: URL, output: URL, mode: MacSigningMode, identity: String?, dryRun: Bool) async throws {
        let plan = try MacSigningPlan.make(bundle: bundle, mode: mode, identity: identity)
        try validateOutput(output, source: bundle)
        if dryRun {
            print(String(decoding: try JSONEncoder.sortedPretty().encode(plan), as: UTF8.self))
            return
        }
        @Dependency(\.macHostClient) var client
        guard client.isMacOS() else { throw StringError("Mac signing requires a macOS host") }
        let manager = FileManager.default
        let stage = output.deletingLastPathComponent().appendingPathComponent(".xtool-sign-\(UUID().uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let stagedBundle = stage.appendingPathComponent(plan.bundleName)
        try manager.copyItem(at: bundle, to: stagedBundle)
        try plan.inputInventory.verify(directory: stagedBundle)
        try checkSource(bundle, plan: plan)
        let inputs = stage.appendingPathComponent(".entitlements")
        try manager.createDirectory(at: inputs, withIntermediateDirectories: false)
        for (index, target) in plan.targets.enumerated() {
            try Task.checkCancellation()
            var arguments = ["--force", "--sign", plan.identity ?? "-"]
            if mode == .developerID {
                arguments += ["--options", "runtime", "--timestamp"]
            } else {
                arguments += ["--options", "0", "--timestamp=none"]
            }
            if let entitlements = target.entitlements {
                let file = inputs.appendingPathComponent("\(index).plist")
                try entitlements.write(to: file, options: .atomic)
                arguments += ["--entitlements", file.path, "--generate-entitlement-der"]
            }
            arguments.append(codeURL(target.path, bundle: stagedBundle).path)
            _ = try await client.capture("/usr/bin/codesign", arguments)
        }
        try manager.removeItem(at: inputs)
        var receipt = try MacSigningReceipt(plan: plan, bundle: stagedBundle)
        receipt.signatures = try await verify(bundle: stagedBundle, receipt: receipt)
        try checkSource(bundle, plan: plan)
        try receipt.write(beside: stagedBundle)
        try MacSigningReceipt.verify(bundle: stagedBundle)
        try validateOutput(output, source: bundle)
        try Task.checkCancellation()
        try manager.moveItem(at: stage, to: output)
        print("Signed app: \(output.appendingPathComponent(plan.bundleName).path)")
    }

    @discardableResult
    static func verify(bundle: URL, receipt: MacSigningReceipt,
                       verifyInventory: Bool = true) async throws -> [MacSigningReceipt.Signature] {
        @Dependency(\.macHostClient) var client
        guard client.isMacOS() else { throw StringError("Native signature verification requires macOS") }
        if verifyInventory { try receipt.inventory.verify(directory: bundle) }
        let order = try MacBundleAudit.validate(bundle: bundle, target: receipt.target)
        guard order == receipt.targets.map(\.path) else { throw StringError("Signed code inventory mismatch") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xtool-sign-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var signatures: [MacSigningReceipt.Signature] = []
        for (index, target) in receipt.targets.enumerated() {
            let code = codeURL(target.path, bundle: bundle)
            _ = try await client.capture("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", code.path])
            let display = try await client.capture("/usr/bin/codesign", ["--display", "--verbose=4", code.path])
            let metadata = String(decoding: display.error + display.output, as: UTF8.self)
            try validateMetadata(metadata, mode: receipt.mode)
            var fingerprint: String?
            if let identity = receipt.identity {
                let prefix = scratch.appendingPathComponent("\(index)-certificate").path
                _ = try await client.capture("/usr/bin/codesign", ["--display", "--extract-certificates", prefix, code.path])
                let leaf = try Data(contentsOf: URL(fileURLWithPath: prefix + "0"))
                fingerprint = MacSigningPlan.certificateFingerprint(leaf)
                guard fingerprint == identity.uppercased() else {
                    throw StringError("Signed certificate differs from requested fingerprint: \(target.path)")
                }
            }
            let effective = try await client.capture("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", code.path])
            try validateEffectiveEntitlements(effective.output, expected: target.entitlements, path: target.path)
            let lines = metadata.components(separatedBy: .newlines)
            func value(_ prefix: String) -> String? {
                lines.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
            }
            signatures.append(.init(path: target.path, certificateSHA1: fingerprint,
                                    teamIdentifier: receipt.mode == .adHoc ? nil : value("TeamIdentifier="),
                                    authority: value("Authority="),
                                    hardenedRuntime: lines.contains { $0.hasPrefix("CodeDirectory ") && $0.contains("runtime") },
                                    timestamp: value("Timestamp=")))
        }
        guard Set(signatures.compactMap(\.teamIdentifier)).count <= 1 else {
            throw StringError("Nested code has inconsistent signing teams")
        }
        if !receipt.signatures.isEmpty, !sameSignatures(receipt.signatures, signatures) {
            throw StringError("Actual signature metadata differs from signing receipt")
        }
        if verifyInventory { try receipt.inventory.verify(directory: bundle) }
        return signatures
    }

    // codesign renders Timestamp in the host locale/timezone. Exact artifact bytes bind the
    // timestamp token; compare its presence here so receipts remain portable between Macs.
    private static func sameSignatures(_ expected: [MacSigningReceipt.Signature],
                                       _ actual: [MacSigningReceipt.Signature]) -> Bool {
        guard expected.count == actual.count else { return false }
        return zip(expected, actual).allSatisfy { left, right in
            left.path == right.path && left.certificateSHA1 == right.certificateSHA1
                && left.teamIdentifier == right.teamIdentifier && left.authority == right.authority
                && left.hardenedRuntime == right.hardenedRuntime && (left.timestamp == nil) == (right.timestamp == nil)
        }
    }

    private static func validateMetadata(_ text: String, mode: MacSigningMode) throws {
        let lines = text.components(separatedBy: .newlines)
        if mode == .adHoc {
            guard lines.contains("Signature=adhoc") else { throw StringError("Expected an ad-hoc signature") }
            return
        }
        let prefix = mode == .developerID ? "Authority=Developer ID Application:" : "Authority=Apple Development:"
        guard lines.contains(where: { $0.hasPrefix(prefix) }),
              lines.contains(where: { $0.hasPrefix("TeamIdentifier=") && $0 != "TeamIdentifier=not set" }) else {
            throw StringError("Signing certificate category does not match requested \(mode.rawValue) mode")
        }
        if mode == .developerID {
            guard lines.contains(where: { $0.hasPrefix("CodeDirectory ") && $0.contains("runtime") }),
                  lines.contains(where: { $0.hasPrefix("Timestamp=") && $0 != "Timestamp=none" }) else {
                throw StringError("Developer ID signing requires hardened runtime and a secure timestamp")
            }
        }
    }

    private static func validateEffectiveEntitlements(_ actual: Data, expected: Data?, path: String) throws {
        func dictionary(_ data: Data?) throws -> NSDictionary {
            guard let data, !data.isEmpty else { return NSDictionary() }
            guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else {
                throw StringError("Signed entitlements are not a dictionary: \(path)")
            }
            return value
        }
        guard try dictionary(actual).isEqual(dictionary(expected)) else {
            throw StringError("Effective signed entitlements differ from the handoff: \(path)")
        }
    }

    private static func checkSource(_ bundle: URL, plan: MacSigningPlan) throws {
        try MacArtifact.verify(bundle: bundle)
        guard try ArtifactInventory.hash(MacArtifact.manifestURL(for: bundle)) == plan.inputArtifactSHA256 else {
            throw StringError("Source handoff changed during signing")
        }
        try plan.inputInventory.verify(directory: bundle)
    }

    private static func validateOutput(_ output: URL, source: URL) throws {
        let resolved = output.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(output.lastPathComponent).standardizedFileURL
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path),
              !resolved.path.hasPrefix(source.path + "/"), resolved.path != source.path else {
            throw StringError("Signing output must be a new directory outside the input app")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &directory),
              directory.boolValue else { throw StringError("Signing output parent directory must already exist") }
    }

    private static func codeURL(_ path: String, bundle: URL) -> URL {
        path.isEmpty ? bundle : bundle.appendingPathComponent(path)
    }
}
