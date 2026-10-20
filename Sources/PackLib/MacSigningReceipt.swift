import Foundation
import XUtils

/// Exact signed bytes and their original build handoff; this is a local receipt, not an attestation.
public struct MacSigningReceipt: Codable, Sendable {
    public struct Signature: Codable, Sendable, Equatable {
        public let path: String
        public let certificateSHA1: String?
        public let teamIdentifier: String?
        public let authority: String?
        public let hardenedRuntime: Bool
        public let timestamp: String?

        public init(path: String, certificateSHA1: String?, teamIdentifier: String?, authority: String?,
                    hardenedRuntime: Bool, timestamp: String?) {
            self.path = path
            self.certificateSHA1 = certificateSHA1
            self.teamIdentifier = teamIdentifier
            self.authority = authority
            self.hardenedRuntime = hardenedRuntime
            self.timestamp = timestamp
        }
    }

    public var signatures: [Signature] = []
    public var version: Int = 1
    public let bundleName: String
    public let target: ResolvedTarget
    public let mode: MacSigningMode
    public let identity: String?
    public let inputArtifactSHA256: String
    public let inventory: ArtifactInventory
    public let targets: [MacSigningPlan.Target]

    public init(plan: MacSigningPlan, bundle: URL) throws {
        bundleName = plan.bundleName
        target = plan.target
        mode = plan.mode
        identity = plan.identity
        inputArtifactSHA256 = plan.inputArtifactSHA256
        inventory = try ArtifactInventory(directory: bundle)
        targets = plan.targets
    }

    public static func receiptURL(for bundle: URL) -> URL {
        bundle.deletingPathExtension().appendingPathExtension("signing-receipt.json")
    }

    public func write(beside bundle: URL) throws {
        try JSONEncoder.sortedPretty().encode(self).write(to: Self.receiptURL(for: bundle), options: .atomic)
    }

    @discardableResult
    public static func verify(bundle: URL) throws -> Self {
        let receipt = try JSONDecoder().decode(Self.self, from: Data(contentsOf: receiptURL(for: bundle)))
        guard receipt.version == 1, receipt.bundleName == bundle.lastPathComponent,
              receipt.inputArtifactSHA256.count == 64,
              receipt.inputArtifactSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw StringError("Invalid Mac signing receipt")
        }
        try MacSigningPlan.validateIdentity(mode: receipt.mode, identity: receipt.identity)
        try receipt.inventory.verify(directory: bundle)
        let order = try MacBundleAudit.validate(bundle: bundle, target: receipt.target)
        guard receipt.targets.map(\.path) == order else { throw StringError("Signing receipt code inventory mismatch") }
        guard receipt.signatures.map(\.path) == order else {
            throw StringError("Signing receipt lacks verified signature metadata")
        }
        for signature in receipt.signatures {
            guard signature.certificateSHA1 == receipt.identity,
                  receipt.mode == .adHoc || signature.teamIdentifier?.isEmpty == false else {
                throw StringError("Signing receipt certificate metadata mismatch")
            }
            if receipt.mode == .developerID {
                guard signature.hardenedRuntime, signature.timestamp != nil,
                      signature.authority?.hasPrefix("Developer ID Application:") == true else {
                    throw StringError("Signing receipt lacks Developer ID distribution requirements")
                }
            }
        }
        for target in receipt.targets {
            if let entitlements = target.entitlements { try MacSigningPlan.validateEntitlements(entitlements) }
        }
        return receipt
    }
}
