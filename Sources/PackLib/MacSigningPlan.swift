import Crypto
import Foundation
import XUtils

public enum MacSigningMode: String, Codable, Sendable, CaseIterable {
    case adHoc = "ad-hoc"
    case development
    case developerID = "developer-id"
}

/// Frozen signing inputs. Entitlements are copied into this plan, never reread during signing.
public struct MacSigningPlan: Codable, Sendable {
    public struct Target: Codable, Sendable {
        public var path: String
        public var entitlements: Data?

        public init(path: String, entitlements: Data?) {
            self.path = path
            self.entitlements = entitlements
        }
    }

    public let bundleName: String
    public let target: ResolvedTarget
    public let mode: MacSigningMode
    public let identity: String?
    public let inputArtifactSHA256: String
    public let inputInventory: ArtifactInventory
    public let targets: [Target]

    public static func validateIdentity(mode: MacSigningMode, identity: String?) throws {
        if mode == .adHoc {
            guard identity == nil else { throw StringError("Ad-hoc signing cannot select a certificate identity") }
        } else {
            guard let identity, identity.count == 40,
                  identity.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
                throw StringError("Certificate signing requires an explicit 40-character SHA-1 certificate fingerprint")
            }
        }
    }

    public static func make(bundle: URL, mode: MacSigningMode, identity: String?) throws -> Self {
        try validateIdentity(mode: mode, identity: identity)
        try MacArtifact.verify(bundle: bundle)
        let artifactURL = MacArtifact.manifestURL(for: bundle)
        let artifactData = try Data(contentsOf: artifactURL)
        let artifact = try JSONDecoder().decode(MacArtifact.self, from: artifactData)
        let manifestURL = MacArtifact.signingManifestURL(for: bundle)
        let manifestData = try Data(contentsOf: manifestURL)
        guard ArtifactInventory.hash(data: manifestData) == artifact.signingInputs[manifestURL.lastPathComponent] else {
            throw StringError("Signing manifest changed while planning")
        }
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self, from: manifestData)
        var entitlementInputs: [String: Data] = [:]
        var products = Set<String>()
        for product in manifest.products {
            // MacArtifact.verify bound each product to its layout; a helper's bundle is its executable.
            let path = product.bundlePath
            guard artifact.signingOrder.contains(path), products.insert(path).inserted else {
                throw StringError("Signing product does not uniquely match nested code: \(path)")
            }
            if let input = product.entitlementsPath {
                let data = try Data(contentsOf: bundle.deletingLastPathComponent().appendingPathComponent(input))
                guard ArtifactInventory.hash(data: data) == artifact.signingInputs[input] else {
                    throw StringError("Entitlements changed while planning")
                }
                try validateEntitlements(data)
                if mode == .developerID {
                    let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                    guard values?["com.apple.security.get-task-allow"] as? Bool != true,
                          values?["get-task-allow"] as? Bool != true else {
                        throw StringError("Developer ID distribution cannot enable get-task-allow")
                    }
                }
                entitlementInputs[path] = data
            }
        }
        let result = Self(bundleName: bundle.lastPathComponent, target: artifact.target, mode: mode,
                          identity: identity?.uppercased(), inputArtifactSHA256: ArtifactInventory.hash(data: artifactData),
                          inputInventory: artifact.inventory,
                          targets: artifact.signingOrder.map { Target(path: $0, entitlements: entitlementInputs[$0]) })
        // Detect inputs changing while the plan was read.
        try MacArtifact.verify(bundle: bundle)
        guard try ArtifactInventory.hash(artifactURL) == result.inputArtifactSHA256 else {
            throw StringError("Artifact handoff changed while planning signing")
        }
        return result
    }

    public static func validateEntitlements(_ data: Data) throws {
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw StringError("Entitlements must be a property-list dictionary")
        }
        // These capabilities require provisioning or a separate activation contract.
        let restricted = ["application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier",
                          "keychain-access-groups", "com.apple.security.application-groups"]
        guard !values.keys.contains(where: { restricted.contains($0) || $0.hasPrefix("com.apple.developer.") }) else {
            throw StringError("Provisioning-dependent entitlements are not supported by Mac signing yet")
        }
    }

    public static func certificateFingerprint(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
