import Foundation
import XUtils

/// Paths are relative to the outer application bundle. The builder never writes here.
public struct BundleLayout: Sendable, Equatable {
    public let platform: TargetPlatform
    public let kind: Plan.ProductType
    public let name: String

    public init(platform: TargetPlatform, kind: Plan.ProductType, name: String) {
        self.platform = platform
        self.kind = kind
        self.name = name
    }

    public var bundlePath: String {
        switch kind {
        case .application: ""
        case .appExtension: "\(platform == .macOS ? "Contents/" : "")PlugIns/\(name).appex"
        case .xpcService: "Contents/XPCServices/\(name).xpc"
        case .helperExecutable: "Contents/Helpers/\(name)"
        }
    }

    public var contentsPath: String {
        if kind == .helperExecutable { return "Contents/Helpers" }
        return joined(bundlePath, platform == .macOS ? "Contents" : "")
    }

    public var executablePath: String {
        if kind == .helperExecutable { return bundlePath }
        return joined(contentsPath, platform == .macOS ? "MacOS/\(name)" : name)
    }

    public var infoPlistPath: String? {
        kind == .helperExecutable ? nil : joined(contentsPath, "Info.plist")
    }

    public var resourcesPath: String {
        joined(contentsPath, platform == .macOS ? "Resources" : "")
    }

    public var frameworksPath: String { joined(contentsPath, "Frameworks") }

    public func path(for destination: ResourceDestination) throws -> String {
        try destination.validate()
        let base = switch destination.location {
        case .resources: resourcesPath
        case .bundle: kind == .helperExecutable ? contentsPath : bundlePath
        case .contents: contentsPath
        }
        return joined(base, destination.path)
    }

    private func joined(_ base: String, _ path: String) -> String {
        [base, path].filter { !$0.isEmpty }.joined(separator: "/")
    }
}

/// Explicit destinations are relative to the selected product, never the host filesystem.
public struct ResourceDestination: Codable, Sendable, Hashable {
    public enum Location: String, Codable, Sendable {
        case resources
        case bundle
        case contents
    }

    public var location: Location
    public var path: String

    public init(location: Location = .resources, path: String) {
        self.location = location
        self.path = path
    }

    public func validate() throws {
        try Self.validateRelativePath(path)
    }

    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StringError("Bundle destination must be a safe relative path: '\(path)'")
        }
    }
}

public struct ResourceCopy: Codable, Sendable, Hashable {
    public var source: String
    public var destination: ResourceDestination

    public init(source: String, destination: ResourceDestination) {
        self.source = source
        self.destination = destination
    }
}

/// Handoff to a downstream Mac signer. This records intent, not a claim that Mach-O
/// files lack linker-generated ad-hoc signatures. No provisioning or signing occurs here.
public struct DeferredSigningManifest: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case deferred }

    public var version: Int = 1
    public var status: Status = .deferred
    public var target: ResolvedTarget
    public var products: [Product]

    public struct Product: Codable, Sendable {
        public var kind: Plan.ProductType
        public var bundleID: String
        /// Empty for the outer app; all other paths are relative to the app root.
        public var bundlePath: String
        public var executablePath: String
        /// Caller-supplied input, external to the bundle. The handoff writer must
        /// preserve this file and rebase its path relative to the manifest location.
        public var entitlementsPath: String?
    }

    public init(plan: Plan) {
        target = plan.target
        products = plan.allProducts.map { product in
            let layout = product.layout
            return Product(
                kind: product.type,
                bundleID: product.bundleID,
                bundlePath: layout.bundlePath,
                executablePath: layout.executablePath,
                entitlementsPath: product.entitlementsPath
            )
        }
    }
}
