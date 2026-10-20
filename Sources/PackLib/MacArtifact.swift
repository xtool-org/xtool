import Foundation
import XUtils

/// Build handoff preserved beside the app. Signing changes these bytes and requires a new receipt.
public struct MacArtifact: Codable, Sendable {
    public var version: Int = 1
    public var bundleName: String
    public var target: ResolvedTarget
    public var inventory: ArtifactInventory
    public var signingInputs: [String: String]
    /// Relative code locations, deepest first, with the outer app represented by an empty path.
    public var signingOrder: [String]

    public static func manifestURL(for bundle: URL) -> URL {
        bundle.deletingPathExtension().appendingPathExtension("artifact.json")
    }

    public static func signingManifestURL(for bundle: URL) -> URL {
        bundle.deletingPathExtension().appendingPathExtension("signing.json")
    }

    public static func write(bundle: URL, signingManifest: URL) throws {
        let manifest = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: signingManifest))
        try validateProducts(manifest, bundle: bundle)
        let inventory = try ArtifactInventory(directory: bundle)
        let order = try MacBundleAudit.validate(bundle: bundle, target: manifest.target)
        var inputs = [signingManifest.lastPathComponent: try ArtifactInventory.hash(signingManifest)]
        for product in manifest.products {
            guard let path = product.entitlementsPath else { continue }
            let input = try safeInput(path, beside: bundle)
            inputs[path] = try ArtifactInventory.hash(input)
        }
        let artifact = Self(bundleName: bundle.lastPathComponent, target: manifest.target,
                            inventory: inventory, signingInputs: inputs, signingOrder: order)
        try JSONEncoder.sortedPretty().encode(artifact).write(to: manifestURL(for: bundle), options: .atomic)
    }

    public static func verify(bundle: URL) throws {
        let artifact = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifestURL(for: bundle)))
        guard artifact.version == 1, artifact.bundleName == bundle.lastPathComponent else {
            throw StringError("Artifact manifest version or bundle name mismatch")
        }
        try artifact.inventory.verify(directory: bundle)
        let signingName = signingManifestURL(for: bundle).lastPathComponent
        guard artifact.signingInputs[signingName] != nil else { throw StringError("Missing signing manifest hash") }
        for (path, expected) in artifact.signingInputs {
            guard try ArtifactInventory.hash(safeInput(path, beside: bundle)) == expected else {
                throw StringError("Signing input changed: \(path)")
            }
        }
        let signingURL = try safeInput(signingName, beside: bundle)
        let signing = try JSONDecoder().decode(DeferredSigningManifest.self, from: Data(contentsOf: signingURL))
        guard signing.target == artifact.target else { throw StringError("Signing and artifact targets differ") }
        try validateProducts(signing, bundle: bundle)
        for product in signing.products {
            if let path = product.entitlementsPath, artifact.signingInputs[path] == nil {
                throw StringError("Missing entitlement input hash: \(path)")
            }
        }
        let order = try MacBundleAudit.validate(bundle: bundle, target: artifact.target)
        guard order == artifact.signingOrder else { throw StringError("Nested code inventory changed") }
    }

    private static func safeInput(_ path: String, beside bundle: URL) throws -> URL {
        try ResourceDestination.validateRelativePath(path)
        let parent = bundle.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = parent.appendingPathComponent(path).resolvingSymlinksInPath()
        guard url.path.hasPrefix(parent.path + "/") else { throw StringError("Signing input escapes artifact: \(path)") }
        return url
    }

    private static func validateProducts(_ manifest: DeferredSigningManifest, bundle: URL) throws {
        guard manifest.version == 1, manifest.target.platform == .macOS,
              manifest.products.filter({ $0.kind == .application && $0.bundlePath.isEmpty }).count == 1,
              Set(manifest.products.map(\.executablePath)).count == manifest.products.count else {
            throw StringError("Invalid deferred signing product inventory")
        }
        let root = bundle.resolvingSymlinksInPath()
        var nodes: Set<String> = []
        for product in manifest.products {
            try ResourceDestination.validateRelativePath(product.executablePath)
            if !product.bundlePath.isEmpty { try ResourceDestination.validateRelativePath(product.bundlePath) }
            let executable = root.appendingPathComponent(product.executablePath).resolvingSymlinksInPath()
            guard executable.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw StringError("Missing signing product executable: \(product.executablePath)")
            }
            let canonicalPath = String(executable.path.dropFirst(root.path.count + 1))
            guard canonicalPath == product.executablePath else {
                throw StringError("Signing product executable must use its canonical path")
            }
            let node = try MacBundleAudit.signingPath(for: canonicalPath, in: root)
            guard nodes.insert(node).inserted, node == product.bundlePath else {
                throw StringError("Signing products must identify unique signing nodes")
            }
            let name = executable.lastPathComponent
            let layout = BundleLayout(platform: .macOS, kind: product.kind, name: name)
            guard product.bundlePath == layout.bundlePath, product.executablePath == layout.executablePath else {
                throw StringError("Signing product kind does not match its bundle location")
            }
            if product.kind != .helperExecutable {
                let plist = root.appendingPathComponent(product.bundlePath).appendingPathComponent("Contents/Info.plist")
                let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
                guard info?["CFBundleIdentifier"] as? String == product.bundleID,
                      info?["CFBundleExecutable"] as? String == name,
                      info?["CFBundlePackageType"] as? String == product.kind.fourCharCode else {
                    throw StringError("Signing product identity differs from Info.plist: \(product.bundleID)")
                }
            }
        }
    }
}
