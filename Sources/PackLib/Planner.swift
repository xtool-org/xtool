import Dependencies
import Foundation
import XUtils
import Subprocess

public struct Planner: Sendable {
    public var buildSettings: BuildSettings
    public var schema: PackSchema

    @Dependency(\.packageInspection) private var inspection

    public init(buildSettings: BuildSettings, schema: PackSchema) {
        self.buildSettings = buildSettings
        self.schema = schema
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func buildGraph() async throws -> PackageGraph {
        let dependencyRoot = try Self.decoder.decode(
            PackageDependency.self, from: try await inspection.dependencies(buildSettings)
        )
        let packages = try await withThrowingTaskGroup(
            of: (String, InspectedPackage).self, returning: [String: InspectedPackage].self
        ) { group in
            var visited: Set<String> = []
            var dependencies = [dependencyRoot]
            while let node = dependencies.popLast() {
                guard visited.insert(node.identity).inserted else { continue }
                dependencies.append(contentsOf: node.dependencies)
                group.addTask {
                    let settings = buildSettings.withPackagePath(node.path)
                    async let description = inspection.describe(settings)
                    async let manifest = inspection.manifest(settings)
                    return try await (node.identity, InspectedPackage(
                        description: Self.decoder.decode(PackageDump.self, from: jsonContents(description)),
                        manifest: Self.decoder.decode(PackageManifest.self, from: jsonContents(manifest))
                    ))
                }
            }
            var packages: [String: InspectedPackage] = [:]
            for try await (identity, package) in group { packages[identity] = package }
            return packages
        }
        guard packages[dependencyRoot.identity] != nil else {
            throw StringError("Could not inspect root package '\(dependencyRoot.identity)'")
        }
        return PackageGraph(rootIdentity: dependencyRoot.identity, packages: packages)
    }

    public func createPlan() async throws -> Plan {
        let platform = try TargetTriple(buildSettings.triple).platform
        try schema.validate(for: platform)
        guard schema.target == nil else {
            throw StringError("Schema target selection is not integrated with the build command yet; use --triple")
        }
        let graph = try await buildGraph()
        let target = try ResolvedTarget.resolve(
            cliTarget: buildSettings.triple, schema: schema,
            packageDeploymentTargets: Dictionary(
                (graph.root.description.platforms ?? []).map { ($0.name, $0.version) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        let app = try await product(from: graph, target: target, request: ProductRequest(
            name: schema.product, source: schema.source, type: .application,
            plist: schema.infoPath, idSpecifier: schema.idSpecifier, iconPath: schema.iconPath,
            rootResources: schema.resources, resourceCopies: schema.resourceCopies, entitlementsPath: schema.entitlementsPath
        ))
        var extensions: [Plan.Product] = []
        for ext in schema.extensions ?? [] {
            extensions.append(try await product(from: graph, target: target, request: ProductRequest(
                name: ext.product, source: ext.source, type: .appExtension,
                plist: ext.infoPath, idSpecifier: ext.bundleID.map(PackSchema.IDSpecifier.bundleID) ?? .orgID(app.bundleID),
                rootResources: ext.resources, resourceCopies: ext.resourceCopies, entitlementsPath: ext.entitlementsPath
            )))
        }
        var nested: [Plan.Product] = []
        for item in schema.nestedProducts ?? [] {
            nested.append(try await product(from: graph, target: target, request: ProductRequest(
                name: item.product, source: item.source, type: item.kind,
                plist: item.infoPath, idSpecifier: item.bundleID.map(PackSchema.IDSpecifier.bundleID) ?? .orgID(app.bundleID),
                resourceCopies: item.resourceCopies, entitlementsPath: item.entitlementsPath
            )))
        }
        return try Plan(target: target, app: app, extensions: extensions, nestedProducts: nested)
    }

    private struct ProductRequest {
        var name: String?
        var source: ProductSource?
        var type: Plan.ProductType
        var plist: String?
        var idSpecifier: PackSchema.IDSpecifier
        var iconPath: String?
        var rootResources: [String]?
        var resourceCopies: [ResourceCopy]?
        var entitlementsPath: String?
    }

    private func product(
        from graph: PackageGraph, target: ResolvedTarget, request: ProductRequest
    ) async throws -> Plan.Product {
        let selection = try selectProduct(from: graph.root.description.products ?? [], request: request)
        let name = request.name ?? selection.name
        try validateProductName(name)
        var resources = try dependencyResources(from: graph, target: target, product: selection.product)
        resources += (request.rootResources ?? []).map { .root(source: $0) }
        resources += (request.resourceCopies ?? []).map { .copy($0) }
        var info = defaultInfo(name: name, type: request.type, target: target, idSpecifier: request.idSpecifier)
        if let plist = request.plist {
            let data = try await Data(reading: URL(fileURLWithPath: plist))
            guard let overrides = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Sendable] else {
                throw StringError("Info.plist has invalid format: expected a dictionary.")
            }
            info.merge(overrides, uniquingKeysWith: { $1 })
        }
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else {
            throw StringError("Info.plist CFBundleIdentifier must be a nonempty string")
        }
        return Plan.Product(
            target: target, source: selection.source, type: request.type, product: name, bundleID: bundleID,
            infoPlist: info, resources: resources, iconPath: request.iconPath, entitlementsPath: request.entitlementsPath
        )
    }

    private func defaultInfo(
        name: String, type: Plan.ProductType, target: ResolvedTarget, idSpecifier: PackSchema.IDSpecifier
    ) -> [String: Sendable] {
        var info: [String: Sendable] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleIdentifier": idSpecifier.formBundleID(product: name),
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": type.fourCharCode,
        ]
        let deploymentKey = target.platform == .macOS ? "LSMinimumSystemVersion" : "MinimumOSVersion"
        info[deploymentKey] = target.deploymentTarget
        if type == .appExtension { info["NSExtension"] = [:] as [String: Sendable] }
        if type == .application && target.platform != .macOS {
            info["UIDeviceFamily"] = [1, 2]
            info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
            info["UISupportedInterfaceOrientations~ipad"] = [
                "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
            ]
            info["UILaunchScreen"] = [:] as [String: Sendable]
        }
        return info
    }

    private struct Selection {
        let name: String
        let source: ProductSource
        let product: PackageDump.Product?
    }

    private func selectProduct(from products: [PackageDump.Product], request: ProductRequest) throws -> Selection {
        let selectedName: String?
        switch request.source {
        case .prebuilt(let path):
            return try selectPrebuilt(path: path, name: request.name)
        case .library(let name), .executable(let name):
            try validateProductName(name)
            selectedName = name
        case nil: selectedName = request.name
        }
        let product: PackageDump.Product
        if let selectedName {
            guard let match = products.first(where: { $0.name == selectedName }) else {
                throw StringError("No product named '\(selectedName)' was found. Found: \(products.map(\.name).sorted())")
            }
            product = match
        } else {
            // Version 1's implicit selection remains limited to automatic libraries.
            let libraries = products.filter { $0.type == .autoLibrary }
            guard libraries.count == 1 else {
                throw StringError("Expected one automatic library product; specify 'product' or 'source' explicitly. "
                                  + "Found: \(libraries.map(\.name).sorted())")
            }
            product = libraries[0]
        }
        try validateProductName(product.name)
        let source: ProductSource
        switch product.type {
        case .executable: source = .executable(product: product.name)
        case .autoLibrary, .staticLibrary, .dynamicLibrary: source = .library(product: product.name)
        case .other: throw StringError("Unsupported product type for '\(product.name)'")
        }
        if let requested = request.source, requested != source {
            throw StringError("Product '\(product.name)' does not match the requested source kind")
        }
        guard !product.targets.isEmpty else { throw StringError("Product '\(product.name)' has no targets") }
        return Selection(name: product.name, source: source, product: product)
    }

    private func selectPrebuilt(path: String, name: String?) throws -> Selection {
        try ProductSource.prebuilt(path: path).validate()
        guard !path.contains("\0"), !path.hasSuffix("/") else {
            throw StringError("Prebuilt source must identify a file")
        }
        let name = name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        try validateProductName(name)
        return Selection(name: name, source: .prebuilt(path: path), product: nil)
    }

    private func validateProductName(_ name: String) throws {
        try ResourceDestination.validateRelativePath(name)
        guard !name.contains("/") else { throw StringError("Product name must be a single path component") }
    }

    private struct TargetIdentity: Hashable {
        let package: String
        let name: String
    }

    private func dependencyResources(
        from graph: PackageGraph, target: ResolvedTarget, product: PackageDump.Product?
    ) throws -> [Plan.Resource] {
        guard let product else { return [] }
        var pending = product.targets.map { TargetIdentity(package: graph.rootIdentity, name: $0) }
        var visited: Set<TargetIdentity> = []
        var resources: [Plan.Resource] = product.type == .dynamicLibrary ? [.library(name: product.name)] : []
        var seenResources = Set(resources)
        func append(_ resource: Plan.Resource) {
            if seenResources.insert(resource).inserted { resources.append(resource) }
        }
        while let identity = pending.popLast() {
            guard visited.insert(identity).inserted else { continue }
            guard let package = graph.packages[identity.package],
                  let described = package.description.targets?.first(where: { $0.name == identity.name }),
                  let manifest = package.manifest.targets.first(where: { $0.name == identity.name }) else {
                throw StringError("Could not find target '\(identity.name)' in package '\(identity.package)'")
            }
            // Compiler plugins and their dependencies run on the host, never in the bundle.
            if described.type == "macro" || ["macro", "plugin"].contains(manifest.type) { continue }
            if described.moduleType == "BinaryTarget" { append(.binaryTarget(name: identity.name)) }
            if described.resources?.isEmpty == false {
                append(.bundle(package: package.description.name, target: identity.name))
            }
            for dependency in manifest.dependencies where dependency.matches(target.platform) {
                switch dependency.kind {
                case .target:
                    pending.append(TargetIdentity(package: identity.package, name: dependency.name))
                case .byName where package.description.targets?.contains(where: { $0.name == dependency.name }) == true:
                    pending.append(TargetIdentity(package: identity.package, name: dependency.name))
                case .byName, .product:
                    let (packageID, dependencyProduct) = try graph.product(
                        name: dependency.name, package: dependency.package, from: identity.package
                    )
                    if dependencyProduct.type == .dynamicLibrary { append(.library(name: dependencyProduct.name)) }
                    pending += dependencyProduct.targets.map { TargetIdentity(package: packageID, name: $0) }
                }
            }
        }
        return resources
    }
}

private func jsonContents(_ data: Data) -> Data {
    // SwiftPM can print status messages before its JSON output.
    Data(data.drop(while: { $0 != Character("{").asciiValue }))
}

private struct PackageDependency: Decodable {
    let identity: String
    let path: String
    let dependencies: [PackageDependency]
}

private struct PackageDump: Decodable, Sendable {
    enum ProductType: Decodable, Sendable {
        case executable, dynamicLibrary, staticLibrary, autoLibrary, other

        private enum CodingKeys: String, CodingKey { case executable, library }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.executable) {
                self = .executable
            } else if let library = try values.decodeIfPresent([String].self, forKey: .library), library.count == 1 {
                switch library[0] {
                case "dynamic": self = .dynamicLibrary
                case "static": self = .staticLibrary
                case "automatic": self = .autoLibrary
                default: self = .other
                }
            } else {
                self = .other
            }
        }
    }

    struct Product: Decodable, Sendable {
        let name: String
        let targets: [String]
        let type: ProductType
    }

    struct Target: Decodable, Sendable {
        let name: String
        let moduleType: String
        let type: String?
        let resources: [Resource]?
    }

    struct Resource: Decodable, Sendable { let path: String }
    struct Platform: Decodable, Sendable {
        let name: String
        let version: String
    }

    let name: String
    let products: [Product]?
    let targets: [Target]?
    let platforms: [Platform]?
}

/// `describe` supplies resource bundle names, but only `dump-package` preserves
/// dependency conditions and package qualifiers. Both describe the same package.
private struct PackageManifest: Decodable, Sendable {
    struct Target: Decodable, Sendable {
        let name: String
        let type: String
        let dependencies: [Dependency]
    }

    struct Dependency: Decodable, Sendable {
        enum Kind: String, CodingKey, Sendable { case target, product, byName }
        struct Condition: Decodable, Sendable { let platformNames: [String]? }
        let kind: Kind
        let name: String
        let package: String?
        let condition: Condition?

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: Kind.self)
            guard let kind = values.allKeys.first, values.allKeys.count == 1 else {
                throw StringError("Unsupported SwiftPM target dependency")
            }
            self.kind = kind
            var fields = try values.nestedUnkeyedContainer(forKey: kind)
            name = try fields.decode(String.self)
            if kind == .product {
                package = try fields.decodeIfPresent(String.self)
                // Module aliases affect Swift import names, not product/resource identity.
                _ = try fields.decodeIfPresent([String: String].self)
            } else {
                package = nil
            }
            condition = try fields.decodeIfPresent(Condition.self)
        }

        func matches(_ platform: TargetPlatform) -> Bool {
            guard let names = condition?.platformNames, !names.isEmpty else { return true }
            return names.contains(platform.packagePlatformName)
        }
    }

    struct PackageReference: Decodable, Sendable {
        struct Reference: Decodable, Sendable {
            let identity: String
            let nameForTargetDependencyResolutionOnly: String?
        }
        let reference: Reference

        private enum CodingKeys: String, CodingKey { case sourceControl, fileSystem, registry }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard let kind = values.allKeys.first,
                  let reference = try values.decode([Reference].self, forKey: kind).first else {
                throw StringError("Unsupported SwiftPM package dependency")
            }
            self.reference = reference
        }
    }

    let targets: [Target]
    let dependencies: [PackageReference]
}

private struct InspectedPackage: Sendable {
    let description: PackageDump
    let manifest: PackageManifest
}

private struct PackageGraph {
    let rootIdentity: String
    let packages: [String: InspectedPackage]
    var root: InspectedPackage { packages[rootIdentity]! }

    func product(name: String, package qualifier: String?, from identity: String) throws -> (String, PackageDump.Product) {
        guard let requester = packages[identity] else { throw StringError("Missing package '\(identity)'") }
        let references = requester.manifest.dependencies.map(\.reference)
        let candidates: [String]
        if let qualifier {
            candidates = references.filter {
                ($0.nameForTargetDependencyResolutionOnly ?? $0.identity).lowercased() == qualifier.lowercased()
            }.map(\.identity)
        } else {
            candidates = [identity] + references.map(\.identity)
        }
        let matches = candidates.compactMap { identity -> (String, PackageDump.Product)? in
            guard let product = packages[identity]?.description.products?.first(where: { $0.name == name }) else { return nil }
            return (identity, product)
        }
        guard matches.count == 1, let match = matches.first else {
            throw StringError("Could not uniquely resolve product '\(name)' in package '\(identity)' "
                              + "(qualifier: \(qualifier ?? "none"))")
        }
        return match
    }
}

/// Inject package inspection without bypassing decoding, graph resolution or planning.
struct PackageInspectionClient: Sendable {
    var dependencies: @Sendable (BuildSettings) async throws -> Data
    var describe: @Sendable (BuildSettings) async throws -> Data
    var manifest: @Sendable (BuildSettings) async throws -> Data

    private static func run(_ settings: BuildSettings, arguments: [String]) async throws -> Data {
        let invocation = try await settings.swiftPMInvocation(forTool: "package", arguments: arguments)
        return try await Subprocess.run(invocation, output: .data(limit: .max), error: .currentStandardError)
            .checkSuccess().standardOutput
    }
}

extension PackageInspectionClient: DependencyKey {
    static let liveValue = Self(
        dependencies: { settings in
            let directory = try TemporaryDirectory(name: "xtool-dump")
            let output = directory.url.appendingPathComponent("dump.json")
            // Unlike describe/dump-package, show-dependencies can write clean JSON directly.
            _ = try await run(settings, arguments: ["-q", "show-dependencies", "--format", "json", "-o", output.path])
            return try Data(contentsOf: output)
        },
        describe: { try await run($0, arguments: ["-q", "describe", "--type", "json"]) },
        manifest: { try await run($0, arguments: ["-q", "dump-package"]) }
    )
}

extension DependencyValues {
    var packageInspection: PackageInspectionClient {
        get { self[PackageInspectionClient.self] }
        set { self[PackageInspectionClient.self] = newValue }
    }
}
